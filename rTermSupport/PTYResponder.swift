//
//  PTYResponder.swift
//  rTermSupport
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import OSLog
import TermCore
import XPCOverlay

class PTYResponder {

    let log = Logger(subsystem: "rTermSupport", category: "PTYResponder")

    var pseudoTerminal: PseudoTerminal?
    var outputTask: Task<Void, Never>?

    deinit {
        outputTask?.cancel()
    }

    func spawn(session: XPCSession) throws -> RemoteResponse {
        let pt = try PseudoTerminal()
        let ttyName = try pt.start()
        self.pseudoTerminal = pt

        outputTask = Task { [log] in
            for await data in pt.outputStream {
                if Task.isCancelled {
                    log.info("output task cancelled")
                    break
                }
                do {
                    log.debug("XPC sending stdout: \(data.count) bytes")
                    try session.send(RemoteResponse.stdout(data))
                } catch {
                    log.error("XPC send failed: \(error.localizedDescription)")
                }
            }
            log.info("output stream finished")
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
            log.debug("PTY write: \(data.count) bytes")
            pseudoTerminal?.write(data)
            return nil

        case .failure(let message):
            return .failure(message)

        @unknown default:
            log.error("unknown request: \(String(describing: request))")
            return nil
        }
    }
}
