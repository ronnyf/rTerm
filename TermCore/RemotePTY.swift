//
//  RemotePTY.swift
//  TermCore
//
//  Created by Ronny Falk on 6/25/24.
//

internal import AsyncAlgorithms
import Foundation
import OSLog
import System
import XPCOverlay

public enum RemoteErrors: Error {
    case notConnected
    case response(String)
}

@available(macOS 14, *)
public class RemotePTY {
    
    private let outputDataChannel = AsyncChannel<any DataProtocol>()
    public var outputData: some AsyncSequence<any DataProtocol, Never> {
        outputDataChannel
    }
    
    private static let xpcIdentifier = "com.ronnyf.rTermSupport"
    private var xpcSession: XPCSession?
    private var processingTask: Task<Void, Error>?
    
    public init(xpcSession: XPCSession? = nil) {
        self.xpcSession = xpcSession
    }
    
    deinit {
        xpcSession?.cancel(reason: "deinit")
    }
    
    public func connect(
        xpcIdentifier: String = "com.ronnyf.rTermSupport",
        targetQueue: DispatchQueue = DispatchQueue.global(qos: .userInteractive)
    ) throws {
        guard xpcSession == nil else {
            Logger.TermCore.remotePTY.info("already connected")
            return
        }
        
        let xpcSession = try XPCSession(xpcService: xpcIdentifier, targetQueue: targetQueue, options: .inactive)
        processIncomingMessages(xpcSession: xpcSession)
        update(xpcSession: xpcSession)
        Logger.TermCore.remotePTY.info("activating session: \(xpcSession.debugDescription)")
        try xpcSession.activate()
    }
    
    private func update(xpcSession: XPCSession) {
        self.xpcSession?.cancel(reason: "Replaced")
        self.xpcSession = xpcSession
    }
    
    public func processIncomingMessages(xpcSession: XPCSession) {
        processingTask?.cancel()
        
        let incomingMessages = xpcSession.incomingMessages { (response: RemoteResponse) -> Data? in
            switch response {
                case .failure(let message):
                    Logger.TermCore.remotePTY.error("\(message)")
                    return nil
                    
                case .stdout(let data):
                    return data
                    
                case .stderr(let data):
                    return data
                    
                default:
                    return nil
            }
        }
        processingTask = Task {
            for await message in incomingMessages {
                Logger.TermCore.remotePTY.debug("Received XPC message: \(message.count) bytes")
                await outputDataChannel.send(message)
                Logger.TermCore.remotePTY.debug("Forwarded to outputDataChannel")
            }
        }
        
        xpcSession.setCancellationHandler { [processingTask] xpcError in
            Logger.TermCore.remotePTY.error("incoming error: \(String(describing: xpcError))")
            processingTask?.cancel()
        }
    }
    
    public func sendSync(_ command: some Encodable) throws -> RemoteResponse {
        guard let xpcSession else { throw RemoteErrors.notConnected }
        return try xpcSession.sendSync(command)
    }
    
    public func send(command: some Encodable) throws {
        guard let xpcSession else { throw RemoteErrors.notConnected }
        try xpcSession.send(command)
    }
    
    public func send(command message: RemoteCommand, reply: @escaping ((Result<RemoteResponse, Error>) -> Void)) throws {
        guard let xpcSession else { throw RemoteErrors.notConnected }
        try xpcSession.send(message, replyHandler: reply)
    }
    
    public func send(command: some Encodable) async throws -> RemoteResponse {
        guard let xpcSession else { throw RemoteErrors.notConnected }
//        return try await withCheckedThrowingContinuation { continuation in
//            do {
//                try xpcSession.send(command) { (reply: Result<RemoteResponse, Error>) in
//                    switch reply {
//                        case .success(let response):
//                            continuation.resume(returning: response)
//                        case .failure(let error):
//                            continuation.resume(throwing: error)
//                    }
//                }
//            } catch {
//                continuation.resume(throwing: error)
//            }
//        }
        throw RemoteErrors.notConnected
    }
}

extension RemotePTY {
    public static func darwinFailureDescription() -> String {
        // -1 is returned and errno is set to indicate the error.
        if let errorPtr = strerror(errno) {
            return String(cString: errorPtr)
        } else {
            return "Unknown error: \(errno)"
        }
    }
}

extension XPCSession {

    func incomingMessages<Message: Decodable, Result>(transform: @escaping (Message) -> Result?) -> some AsyncSequence<Result, Never> {
        AsyncStream(Result.self) { continuation in
            setIncomingMessageHandler { (message: Message) in
                if let value = transform(message) {
                    continuation.yield(value)
                }
                return nil
            }
        }
    }
}
