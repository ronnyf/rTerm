//
//  PTYResponder.swift
//  rTermSupport
//
//  Created by Ronny Falk on 6/22/24.
//

import AsyncAlgorithms
import Darwin
import Foundation
import OSLog
import System
import TermCore
import XPCOverlay

class PTYResponder {
    
    enum Errors: Error {
        case shellTaskIsRunning
        case noTTY
        case wrongPipe
        case brokenPipe
        case dupStd(Int32, Int32, Int32)
    }
    
    let log = Logger(subsystem: "rTermSupport", category: "PTYResponder")
    
    var primaryFD: FileDescriptor?
    var shellTask: Task<Void, Error>? // maybe process and task both need to be unified in one structure?
    
    deinit {
        shellTask?.cancel()
        print("DEBUG: deinit \(self)")
    }
    
    func spawn(session: XPCSession) throws -> RemoteResponse {
        
        guard shellTask == nil else { throw Errors.shellTaskIsRunning }
       
        let pseudoTerminal = try PseudoTerminal()
        primaryFD = pseudoTerminal.pty.primary
        let fd = pseudoTerminal.pty.secondary
        guard let ttyName = fd.name else { throw Errors.noTTY}
        try fd.tiosctty()
        
        // We should look at this at some point, whether this is useful for redirecting stdin/out/err
//        let (fdRead, fdWrite) = FileDescriptor.pipe()
        
        let (rcIn, rcOut, rcErr) = (dup2(fd.rawValue, STDIN_FILENO), dup2(fd.rawValue, STDOUT_FILENO),  dup2(fd.rawValue, STDERR_FILENO))
        guard rcIn >= 0, rcOut >= 0, rcErr >= 0 else {
            throw Errors.dupStd(rcIn, rcOut, rcErr)
        }
        
        // TODO: validate this
        try fd.close() // ChatGPT says this can be (should be?) closed...
        
        // let's hope/assume that the shell process inherits our current
        let shellProcess = try Shell.bash.process()
        
        shellProcess.terminationHandler = { @Sendable process in
            print("DEBUG: TODO: termination handler for \(process) called")
            try? session.send(RemoteResponse.failure("Shell process terminated"))
        }

        shellTask = Task {
            do {
                // first task throwing, cancels the group...
                try await withThrowingDiscardingTaskGroup { taskGroup in
                    
                    guard let outputPipe = shellProcess.outputPipe, let errorPipe = shellProcess.errorPipe else { throw Errors.wrongPipe }
                    taskGroup.addTask {
                        let outputData = outputPipe.fileHandleForReading.dataStream()
                        let errorData = errorPipe.fileHandleForReading.dataStream()

                        for try await chunk in merge(outputData, errorData) {
                            try Task.checkCancellation()
                            try session.send(RemoteResponse.stdout(chunk))
                        }
                    }
                    
                    taskGroup.addTask { [log] in
                        try shellProcess.run()
                        log.info("shell process did run")
                    }
                    
                    log.info("Waiting for discarding task group to finish it's work...")
                }
                log.info("...waited for discarding task group to finish it's work")
            } catch {
                log.error("shell task error: \(error.localizedDescription)")
                try? session.send(RemoteResponse.failure("Broken Pipe"))
            }
        }
        
        return .spawned(URL(filePath: ttyName))
    }
}

extension PTYResponder: XPCSyncResponder {
    
    func respond(_ request: RemoteCommand, session: XPCSession) throws -> RemoteResponse? {
        switch request {
            case .spawn:
                return try spawn(session: session)

            case .input(let data):
                guard let fd = primaryFD else { return .failure("no PTY") }
                data.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    _ = Darwin.write(fd.rawValue, baseAddress, buffer.count)
                }
                return nil

            case .failure(let message):
                return .failure(message)
                
            @unknown default:
                log.error("unknown request: \(String(describing: request))")
                return nil
        }
    }
}

extension PTYResponder {
    static func darwinFailureDescription() -> String {
        // -1 is returned and errno is set to indicate the error.
        if let errorPtr = strerror(errno) {
            return String(cString: errorPtr)
        } else {
            return "Unknown error: \(errno)"
        }
    }
}

extension FileHandle {
    func dataStream() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            self.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            continuation.onTermination = { @Sendable _ in
                self.readabilityHandler = nil
            }
        }
    }
}
