//
//  ShellSpawner.swift
//  rtermd
//
//  Created by Ronny Falk on 4/9/26.
//  Copyright (C) 2026 RFx Software Inc. All rights reserved.
//
//  This file is part of rTerm.
//
//  Terminal App is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Terminal App is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Terminal App.  If not, see <https://www.gnu.org/licenses/>.
//

import Darwin
import TermCore

// MARK: - SpawnResult

/// The result of a successful `forkpty` + `execve` spawn.
struct SpawnResult: Sendable {
    /// PID of the child shell process.
    let pid: pid_t
    /// File descriptor for the primary (controller) side of the PTY pair.
    let primaryFD: Int32
    /// Device name of the secondary (child) side, e.g. "/dev/ttys003".
    let ttyName: String
}

// MARK: - SpawnError

enum SpawnError: Error {
    /// `forkpty` returned -1.
    case forkFailed(Int32)
}

// MARK: - Shell + Spawn

extension Shell {

    /// Spawn a shell process inside a new PTY with the given window dimensions.
    ///
    /// Pure-Swift `forkpty` wrapper with proper job control, file descriptor
    /// hygiene, and pre-fork environment construction.
    ///
    /// Design constraints enforced here:
    /// - All `argv` and `envp` C strings are allocated **before** `fork` so the
    ///   child never touches the Swift runtime (no String bridging, no allocation).
    /// - File descriptors above stderr are closed in the child.
    /// - SIGTTIN / SIGTTOU / SIGTSTP are blocked around `tcsetpgrp` in the child.
    /// - `FD_CLOEXEC` is set on the primary FD in the parent.
    /// - `execve` (not `execvp`) is used for explicit path control.
    ///
    /// - Parameters:
    ///   - rows: Initial terminal row count.
    ///   - cols: Initial terminal column count.
    /// - Returns: A ``SpawnResult`` containing the child PID, primary FD, and TTY device name.
    /// - Throws: ``SpawnError/forkFailed(_:)`` if `forkpty` fails.
    func spawn(rows: UInt16, cols: UInt16) throws -> SpawnResult {

        // ---------------------------------------------------------------
        // 1. Build argv and envp BEFORE fork.
        //    After fork the child must not call into the Swift runtime.
        // ---------------------------------------------------------------

        let executablePath = self.executable
        let args = [executablePath] + self.defaultArguments

        // strdup each argument so we hold C-heap pointers the child can use directly.
        let cArgs = args.map { strdup($0)! }
        defer { cArgs.forEach { free($0) } }

        // execve wants a NULL-terminated array of char*.
        var argv: [UnsafeMutablePointer<CChar>?] = cArgs.map { $0 }
        argv.append(nil)

        let envPairs = self.buildEnvironment()
        let cEnv = envPairs.map { strdup($0)! }
        defer { cEnv.forEach { free($0) } }

        var envp: [UnsafeMutablePointer<CChar>?] = cEnv.map { $0 }
        envp.append(nil)

        // ---------------------------------------------------------------
        // 2. Prepare winsize for forkpty.
        // ---------------------------------------------------------------

        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        // ---------------------------------------------------------------
        // 3. forkpty -- creates the PTY pair, forks, and in the child sets
        //    up setsid + login_tty (opens secondary on stdin/stdout/stderr).
        // ---------------------------------------------------------------

        var primaryFD: Int32 = -1
        var ttyNameBuf = [CChar](repeating: 0, count: 128)

        let pid = forkpty(&primaryFD, &ttyNameBuf, nil, &ws)

        if pid == 0 {
            // =============================================================
            // CHILD -- async-signal-safe only from here on.
            // No Swift String, no ARC, no allocation.
            // =============================================================

            Self.closeFDsAboveStderr()
            Self.blockSignalsAndSetForeground()

            // execve replaces the process image.  Use cArgs[0] (a C pointer),
            // never executablePath (a Swift String -- bridging would allocate).
            execve(cArgs[0], &argv, &envp)

            // If execve returns, the exec failed. _exit avoids running Swift
            // atexit handlers or flushing stdio buffers in the child.
            _exit(127)
        }

        // =================================================================
        // PARENT
        // =================================================================

        guard pid > 0 else {
            throw SpawnError.forkFailed(errno)
        }

        // Set close-on-exec so the primary FD does not leak into future children.
        let currentFlags = fcntl(primaryFD, F_GETFD)
        if currentFlags >= 0 {
            _ = fcntl(primaryFD, F_SETFD, currentFlags | FD_CLOEXEC)
        }

        let ttyName = String(cString: ttyNameBuf)
        return SpawnResult(pid: pid, primaryFD: primaryFD, ttyName: ttyName)
    }

    // MARK: - Environment

    /// Construct the environment variable array as `["KEY=VALUE", ...]` strings.
    ///
    /// This runs in the parent before fork, so Swift String operations are safe.
    private func buildEnvironment() -> [String] {
        var env: [String] = []

        env.append("TERM=xterm-256color")
        env.append("SHELL=\(self.executable)")

        // HOME from the password database (more reliable than NSHomeDirectory
        // which depends on Foundation and may behave differently under launchd).
        if let pw = getpwuid(getuid()), let homeDir = pw.pointee.pw_dir {
            env.append("HOME=\(String(cString: homeDir))")
            if let name = pw.pointee.pw_name {
                env.append("USER=\(String(cString: name))")
            }
        }

        env.append("PATH=/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin:/opt/homebrew/bin")

        // Propagate LANG if set in the daemon's own environment so the shell
        // inherits the user's locale preference.
        if let lang = getenv("LANG") {
            env.append("LANG=\(String(cString: lang))")
        }

        return env
    }

    // MARK: - Child-side helpers (async-signal-safe only)

    /// Close every file descriptor above stderr.
    ///
    /// After `forkpty`, the child has stdin/stdout/stderr wired to the PTY
    /// secondary. Any other open FDs (e.g. the primary side, or FDs inherited
    /// from the parent) must be closed so the shell does not inherit them.
    ///
    /// We enumerate `/dev/fd` instead of brute-forcing `3..<getdtablesize()`
    /// because the latter is O(max-fd) and the table limit can be large.
    ///
    /// Note: `opendir`/`readdir` are not POSIX-listed async-signal-safe, but on
    /// Darwin they are thin wrappers over `getdirentries` and do not allocate or
    /// take locks. Every major macOS terminal emulator uses this pattern.
    private static func closeFDsAboveStderr() {
        guard let dir = opendir("/dev/fd") else { return }
        // Note: do NOT defer closedir here because that FD is in the range
        // we are closing. We track its FD and skip it, then close the dir
        // after the loop.
        let dirFD = dirfd(dir)

        while let entry = readdir(dir) {
            // entry.pointee.d_name is a fixed-size C tuple on Darwin.
            // Use withUnsafePointer to read it as a C string without allocation.
            let fd: Int32? = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen)) {
                    // atoi is async-signal-safe; strtol would also work.
                    let value = atoi($0)
                    // atoi returns 0 for non-numeric names like "." and ".."
                    // but FD 0 (stdin) is <= STDERR_FILENO so we skip it anyway.
                    return value > STDERR_FILENO ? value : nil
                }
            }

            if let fd, fd != dirFD {
                Darwin.close(fd)
            }
        }

        closedir(dir)
    }

    /// Block job-control signals around `tcsetpgrp` in the child.
    ///
    /// After `forkpty`, the child is in a new session (`setsid`) with the PTY
    /// secondary as the controlling terminal. We need to make the child the
    /// foreground process group of its controlling terminal so shells that
    /// check for this (bash, zsh) do not immediately stop themselves.
    ///
    /// The signal block prevents the kernel from delivering SIGTTIN/SIGTTOU/
    /// SIGTSTP between the moment we become foreground and the moment the
    /// shell's own signal setup runs.
    private static func blockSignalsAndSetForeground() {
        var blockSet = sigset_t()
        var savedSet = sigset_t()

        sigemptyset(&blockSet)
        sigaddset(&blockSet, SIGTTIN)
        sigaddset(&blockSet, SIGTTOU)
        sigaddset(&blockSet, SIGTSTP)

        sigprocmask(SIG_BLOCK, &blockSet, &savedSet)
        tcsetpgrp(STDIN_FILENO, getpid())
        sigprocmask(SIG_SETMASK, &savedSet, nil)
    }
}
