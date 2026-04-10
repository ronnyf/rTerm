//
//  SessionHandler.swift
//  rTermLauncher
//
//  Created by Ronny Falk on 6/22/24.
//

import Foundation
import XPC
import OSLog

public protocol XPCResponder {
    associatedtype Request: Decodable
    associatedtype Response: Encodable
    func respond(_ request: Request) async throws -> Response?
}

public protocol XPCSyncResponder {
    associatedtype Request: Decodable
    associatedtype Response: Encodable
    func respond(_ request: Request, session: XPCSession) throws -> Response?
}

@available(macOS 14.0, *)
public class SessionHandler<Responder: XPCSyncResponder>: XPCPeerHandler {

    let session: XPCSession
    let queue: DispatchQueue
    let responder: Responder
    
    public init(session: XPCSession, queue: DispatchQueue? = nil, responder: Responder) {
        self.session = session
        self.queue = queue ?? DispatchQueue.global(qos: .userInitiated)
        self.responder = responder
    }

    public func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        Logger.TermCore.sessionHandler.info("got message: \(String(describing: message))")
        return message.response(responder: responder, session: session) //TODO: fix naming - move away from under XPCRequest
    }
    
    public func handleCancellation(error: XPCRichError) {
        
    }
    
    func dispatch(error: some Error, message: XPCReceivedMessage) {
        print("ERROR: \(error), message: \(message)")
    }
}

extension XPCReceivedMessage {
    
    public func _response<Message: Decodable, Result: Encodable>(message: Message, session: XPCSession) -> Result? {
        nil
    }
    
    public func response<Responder: XPCSyncResponder>(responder: Responder, session: XPCSession) -> (any Encodable)? {
       do {
           let request = try decode(as: Responder.Request.self) // TODO: this needs to turn around or something
           Logger.TermCore.sessionHandler.info("got incomming request: \(String(describing: request))")
           
           let response = try responder.respond(request, session: session)
           Logger.TermCore.sessionHandler.info("request: \(String(describing: request)) -> response: \(String(describing: response))")
           
           guard expectsReply == true else {
               Logger.TermCore.sessionHandler.info("message is not expecting a reply")
               return nil
           }
           
           return response
           
       } catch {
           Logger.TermCore.sessionHandler.error("XPCReceivedMessage: response: \(error.localizedDescription)")
           return RemoteResponse.failure(error.localizedDescription)
       }
   }
}
