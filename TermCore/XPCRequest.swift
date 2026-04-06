//
//  XPCRequest.swift
//  TermCore
//
//  Created by Ronny Falk on 6/25/24.
//

import Foundation
import System
import XPCOverlay

public struct XPCRequest {
    
    public enum Errors: Error, Codable {
        case wrongRequestType
        case noServiceIdentifier
        case wrongResponseType
        case serivceFailure
    }
    
    public let request: any Codable
    public let session: XPCSession
    
    public init(_ request: some Codable, session: XPCSession) {
        self.request = request
        self.session = session
    }
    
    public func sendSync<Response: Decodable>() throws -> Response {
        try session.sendSync(request)
    }
    
    public func send<Response: Decodable>(replyHandler: @escaping (Result<Response, Error>) -> Void) throws {
        try session.send(request, replyHandler: replyHandler)
    }
    
    public func send<Response: Decodable>() async throws -> Response {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, any Error>) in
            do {
                try session.send(request) { reply in
                    switch reply {
                        case .failure(let error):
                            continuation.resume(throwing: error)
                            
                        case .success(let result):
                            do {
                                let response: Response = try result.decode()
                                continuation.resume(returning: response)
                            } catch {
                                continuation.resume(throwing: error)
                            }
                    }
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Remote Messages get sent to the XPC Service.
public enum RemoteCommand: Codable {
    case spawn
    case failure(String)
}

public enum RemoteResponse: Codable {
    case spawned(URL)
    case failure(String)
    case stdout(Data)
    case stderr(Data)
}
