//
//  PseudoTerminal.swift
//  TermCore
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import OSLog
import System

public class PseudoTerminal {

    public enum Errors: Swift.Error {
        case noProcess
        case posix(Int32)
        case noPtsName
    }

    public let shell: Shell
    public private(set) var winsize: Darwin.winsize
    public let pty: AltPTY

    /// Output bytes from the shell, backed by FileHandle.readabilityHandler on the primary FD.
    public let outputStream: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    /// FileHandle for reading from the primary FD.
    private let primaryHandle: FileHandle

    /// The running shell process.
    private var shellProcess: Process?

    let log = Logger(subsystem: "TermCore", category: "PseudoTerminal")

    public init(shell: Shell = .zsh, rows: UInt16 = 24, cols: UInt16 = 80) throws {
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
    public func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            let result = Darwin.write(pty.primary.rawValue, baseAddress, buffer.count)
            if result < 0 {
                log.error("write failed: \(errno)")
            }
        }
    }

    /// Updates window size via TIOCSWINSZ ioctl.
    public func resize(rows: UInt16, cols: UInt16) {
        winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        var ws = winsize
        let rc = ioctl(pty.primary.rawValue, TIOCSWINSZ, &ws)
        if rc < 0 {
            log.error("TIOCSWINSZ failed: \(errno)")
        }
    }

    /// Spawns the shell process, begins reading output. Returns the tty name.
    public func start() throws -> String {
        guard let ptsName = ptsname(pty.secondary.rawValue) else {
            throw Errors.noPtsName
        }
        let ttyName = String(cString: ptsName)

        // Set controlling terminal on parent — child inherits via fork
        let tioResult = ioctl(pty.secondary.rawValue, TIOCSCTTY, 0)
        if tioResult < 0 {
            log.warning("TIOCSCTTY failed: \(errno)")
        }

        // Create the shell process
        let process = try shell.process()
        let secondaryHandle = FileHandle(fileDescriptor: pty.secondary.rawValue, closeOnDealloc: false)
        process.standardInput = secondaryHandle
        process.standardOutput = secondaryHandle
        process.standardError = secondaryHandle

        // Hook up output reading before starting the shell
        primaryHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.outputContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                self?.outputContinuation.yield(data)
            }
        }

        // Shell termination cleanup
        process.terminationHandler = { [weak self] _ in
            self?.primaryHandle.readabilityHandler = nil
            self?.outputContinuation.finish()
        }

        try process.run()
        self.shellProcess = process

        // Close the secondary FD — the shell process has inherited it
        try pty.secondary.close()

        return ttyName
    }
}
