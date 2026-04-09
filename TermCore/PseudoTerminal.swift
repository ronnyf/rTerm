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
}

extension FileDescriptor {
    public func copy(accessMode: AccessMode = .readWrite) throws -> Self {
        guard let name = ttyname(rawValue) else { throw FileDescriptorError.noPtsName }
        return try FileDescriptor.open(name, accessMode)
    }
    
    /// The function attempts to set the current file descriptor as the controlling terminal
    /// for the calling process. If the operation fails, an error is thrown.
    ///
    /// TIOCSCTTY is an ioctl (input/output control) request used in Unix-like operating systems for terminal management.
    /// Specifically, it is used to set the controlling terminal of a process.
    ///
    /// - Throws: `FileDescriptorError.ioctl` if the ioctl operation fails.
    ///
    ///  Example usage:
    ///  ```swift
    ///  do {
    ///      try tiosctty()
    ///  } catch {
    ///      print("Failed to set controlling terminal: \(error)")
    ///  }
    ///
    public func tiosctty() throws {
        let rc = Darwin.ioctl(rawValue, TIOCSCTTY, 0)
        if rc < 0 {
            throw FileDescriptorError.ioctl(rc)
        }
    }
}

extension FileHandle {
//    public func values() -> some AsyncSequence<Data, Error> {
//        AsyncThrowingStream { continuation in
//            readabilityHandler = { @Sendable handle in
//                let data = handle.availableData
//                guard data.isEmpty == false else { return }
//                continuation.yield(data)
//            }
//            
//            continuation.onTermination = { @Sendable _ in
//                self.readabilityHandler = nil
//            }
//        }
//    }
}
