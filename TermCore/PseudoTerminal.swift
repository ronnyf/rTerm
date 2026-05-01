//
//  PseudoTerminal.swift
//  TermCore
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import OSLog
import System

// FIXME: @unchecked Sendable is unsound — var winsize + var shellProcess have no synchronization. Narrowed to internal so only PseudoTerminalTests sees it. Proper fix is to convert to an actor or refactor the tests to not capture `pt` in TaskGroup child closures.
final class PseudoTerminal: @unchecked Sendable {

    enum Errors: Swift.Error {
        case noProcess
        case posix(Int32)
        case noPtsName
    }

    let shell: Shell
    private(set) var winsize: Darwin.winsize
    let pty: AltPTY

    /// Output bytes from the shell, backed by FileHandle.readabilityHandler on the primary FD.
    let outputStream: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    /// FileHandle for reading from the primary FD.
    private let primaryHandle: FileHandle

    /// The running shell process.
    private var shellProcess: Process?

    let log = Logger.TermCore.pseudoTerminal

    init(shell: Shell = .sh, rows: UInt16 = 24, cols: UInt16 = 80) throws {
        self.shell = shell
        self.winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        self.pty = try AltPTY()
        self.primaryHandle = FileHandle(fileDescriptor: pty.primary.rawValue, closeOnDealloc: false)

        (self.outputStream, self.outputContinuation) = AsyncStream<Data>.makeStream()
    }

    deinit {
        primaryHandle.readabilityHandler = nil
        outputContinuation.finish()
        if let shellProcess, shellProcess.isRunning {
            shellProcess.terminate()
        }
    }

    /// Writes input bytes to the PTY primary FD.
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard var ptr = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(pty.primary.rawValue, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    log.error("write failed: \(errno)")
                    return
                }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
        }
    }

    /// Updates window size via TIOCSWINSZ ioctl.
    func resize(rows: UInt16, cols: UInt16) {
        winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var ws = winsize
        let rc = ioctl(pty.primary.rawValue, TIOCSWINSZ, &ws)
        if rc < 0 {
            log.error("TIOCSWINSZ failed: \(errno)")
        }
    }

    /// Spawns the shell process, begins reading output. Returns the tty name.
    func start() throws -> String {
        guard let ptsName = ptsname(pty.primary.rawValue) else {
            throw Errors.noPtsName
        }
        let ttyName = String(cString: ptsName)

        // Create the shell process
        let process = try shell.process()
        let secondaryHandle = FileHandle(fileDescriptor: pty.secondary.rawValue, closeOnDealloc: false)
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle

        // Hook up output reading before starting the shell.
        // Capture only the Sendable properties the closures need — `PseudoTerminal`
        // itself isn't Sendable because of `var winsize` / `var shellProcess`, but
        // `log` (Logger), `outputContinuation` (AsyncStream.Continuation), and
        // `primaryHandle` (FileHandle) all are. Avoiding `[weak self]` also avoids
        // the self → process → closure retain-cycle concerns.
        let log = self.log
        let outputContinuation = self.outputContinuation
        primaryHandle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                log.debug("PTY output: EOF (0 bytes)")
                outputContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                log.debug("PTY output: \(data.count) bytes")
                outputContinuation.yield(data)
            }
        }

        // Shell termination cleanup
        let primaryHandle = self.primaryHandle
        process.terminationHandler = { proc in
            log.info("Shell exited: status=\(proc.terminationStatus), reason=\(proc.terminationReason.rawValue)")
            primaryHandle.readabilityHandler = nil
            outputContinuation.finish()
        }

        try process.run()
        self.shellProcess = process
        log.info("Shell started: pid=\(process.processIdentifier), isRunning=\(process.isRunning)")

        // Set the shell's process group as the terminal's foreground group.
        // Without this, bash/sh sends itself SIGTSTP because it's not the
        // foreground group and can't read from the terminal.
        let pgrc = tcsetpgrp(pty.primary.rawValue, process.processIdentifier)
        if pgrc < 0 {
            log.warning("tcsetpgrp failed: \(errno)")
        }

        // Close the secondary FD — the shell process has inherited it
        try pty.secondary.close()

        return ttyName
    }
}
