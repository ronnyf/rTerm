//
//  SessionHandler.swift
//  rTermLauncher
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import XPCOverlay
import OSLog
import TermCore

protocol XPCResponder {
    associatedtype Request: Decodable
    associatedtype Response: Encodable
    func respond(_ request: Request) async throws -> Response
}

protocol XPCSyncResponder {
    associatedtype Request: Decodable
    associatedtype Response: Encodable
    func respond(_ request: Request) throws -> Response
}

@available(macOS 14.0, *)
class SessionHandler<Responder: XPCSyncResponder>: XPCPeerHandler {

    let session: XPCSession
    let queue: DispatchQueue
    let responder: Responder
    
    let log = Logger(subsystem: "rTermLauncher", category: "SessionHandler")
    
    init(session: XPCSession, queue: DispatchQueue? = nil, responder: Responder) {
        self.session = session
        self.queue = queue ?? DispatchQueue.global(qos: .userInitiated)
        self.responder = responder
    }

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        log.info("got message: \(String(describing: message))")
        
        do {
            let request = try message.decode(as: Responder.Request.self)
            log.info("got incomming request: \(String(describing: request))")
            
            let response = try self.responder.respond(request)
            log.info("produced response: \(String(describing: request))")
            
            guard message.expectsReply == true else {
                log.info("message is not expecting a reply")
                return response
            }
            
            log.info("sending reply to message")
            message.reply(response)
            
            return response
            
        } catch {
            log.error("handleIncomingRequest: \(error.localizedDescription)")
            return nil
        }
    }
    
    func handleCancellation(error: XPCRichError) {
        
    }
    
    func dispatch(error: some Error, message: XPCReceivedMessage) {
        print("ERROR: \(error), message: \(message)")
    }
}
