//
//  PseudoTerminal.swift
//  TermCore
//
//  Created by Ronny Falk on 6/22/24.
//

internal import AsyncAlgorithms
import Foundation
import OSLog
import System

public class PseudoTerminal {
    
    public enum Errors: Swift.Error {
        case noProcess
        case posix(Int32)
    }
    
    public let shell: Shell
    public var winsize: Darwin.winsize
    public let pty: AltPTY
    
    let outputChannel = AsyncChannel<Data>()
    public var outputData: some AsyncSequence<Data, Never> {
        outputChannel
    }
    
    let log = Logger(subsystem: "TermCore", category: "PseudoTerminal")
    public init(shell: Shell = .zsh, rows: UInt16 = 24, cols: UInt16 = 80) throws {
        self.shell = shell
        self.winsize = Darwin.winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        self.pty = try AltPTY()
    }
    
    // TODO:
    private func update(winsize: Darwin.winsize) {
    }
    
    public func connect() async throws {
        let fh = FileHandle(fileDescriptor: STDIN_FILENO)
        
        let archive = NSKeyedArchiver(requiringSecureCoding: true)
        archive.encode(fh, forKey: "fh")
        let data = archive.encodedData
    }
    
    //    public func teardownPTY(_ pty: _PTY) throws {
    //    }
    
//    public func stream(fd: FileDescriptor) -> some AsyncSequence<Data, Never> {
//        stream(fd: fd.rawValue)
//    }
//    
//    public func stream(fd: Int32) -> some AsyncSequence<Data, Never> {
//        AsyncStream(Data.self) { continuation in
//            
//            // shall we dup this one?
//            let fileHandle = FileHandle(fileDescriptor: dup(fd), closeOnDealloc: true)
//            
//            fileHandle.readabilityHandler = { handle in
//                let data = handle.availableData
//                if data.count > 0 {
//                    continuation.yield(data)
//                }
//            }
//            
//            continuation.onTermination = { @Sendable _ in
//                try? fileHandle.close()
//            }
//        }
//    }
    
    public func primaryIOChannel() throws -> DispatchIO {
        let primaryDup = try pty.primary.duplicate()
        return try primaryDup.dispatchIO(closeWhenDone: true)
    }
    
    public func secondaryIOChannel() throws -> DispatchIO {
        let secondaryDup = try pty.secondary.duplicate()
        return try secondaryDup.dispatchIO(closeWhenDone: true)
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
