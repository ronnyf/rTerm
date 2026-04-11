//
//  DaemonPeerHandler.swift
//  rtermd
//
//  Created by Ronny Falk on 4/9/26.
//  Copyright (C) 2026 RFx Software Inc. All rights reserved.
//
//  This file is part of rTerm.
//
//  Terminal App is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Terminal App is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Terminal App.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import os
import TermCore
import XPC

// MARK: - Error conversion

private extension Error {
    /// Convert any error to a ``DaemonError`` for sending back to the client.
    ///
    /// If the error is already a `DaemonError`, return it directly.
    /// Otherwise wrap the description in `.internalError`.
    var asDaemonError: DaemonError {
        (self as? DaemonError) ?? .internalError(localizedDescription)
    }
}

// MARK: - DaemonPeerHandler

/// XPC peer handler for the daemon side of a client connection.
///
/// Each incoming XPC connection gets its own `DaemonPeerHandler` instance,
/// created by the `XPCListener` accept closure in `main.swift`. The handler
/// decodes ``DaemonRequest`` messages and routes them to the shared
/// ``SessionManager`` actor.
///
/// ## Threading model
///
/// `XPCPeerHandler.handleIncomingRequest` is called on a GCD queue managed
/// by the XPC subsystem, not on the cooperative thread pool. Requests that
/// need a reply (list, create, attach) must block the GCD thread to await
/// the actor result. Fire-and-forget requests (detach, input, resize,
/// destroy) dispatch a `Task` and return `nil` immediately.
///
/// The `blockingAwait` helper bridges from GCD to async. This is safe here
/// because the XPC dispatch queue has unbounded concurrency -- blocking one
/// thread does not starve the system.
final class DaemonPeerHandler: XPCPeerHandler {

    private let session: XPCSession
    private let manager: SessionManager
    private let log = Logger(subsystem: "com.ronnyf.rtermd", category: "DaemonPeerHandler")

    init(session: XPCSession, manager: SessionManager) {
        self.session = session
        self.manager = manager
        log.info("Client connected")
    }

    // MARK: - XPCPeerHandler

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        let request: DaemonRequest
        do {
            request = try message.decode(as: DaemonRequest.self)
        } catch {
            log.error("Failed to decode DaemonRequest: \(error)")
            return DaemonResponse.error(.internalError("Failed to decode request"))
        }

        log.info("Received request: \(String(describing: request))")

        switch request {
        // -- Request-reply: block the GCD thread and return a DaemonResponse --

        case .listSessions:
            let sessions = blockingAwait { await self.manager.listSessions() }
            return DaemonResponse.sessions(sessions)

        case .createSession(let shell, let rows, let cols):
            switch blockingAwaitResult({
                try await self.manager.createSession(shell: shell, rows: rows, cols: cols)
            }) {
            case .success(let info):
                // Attach in a separate Task — don't block the XPC reply.
                // The client will send .attach after receiving sessionCreated.
                return DaemonResponse.sessionCreated(info)
            case .failure(let error):
                return DaemonResponse.error(error)
            }

        case .attach(let sessionID):
            switch blockingAwaitResult({
                try await self.manager.attach(sessionID: sessionID, client: self.session)
            }) {
            case .success(let snapshot):
                return DaemonResponse.screenSnapshot(sessionID: sessionID, snapshot: snapshot)
            case .failure(let error):
                return DaemonResponse.error(error)
            }

        // -- Fire-and-forget: dispatch a Task and return nil --

        case .detach(let sessionID):
            Task { await self.manager.detach(sessionID: sessionID, client: self.session) }
            return nil

        case .input(let sessionID, let data):
            Task {
                do {
                    try await self.manager.handleInput(sessionID: sessionID, data: data)
                } catch {
                    self.log.error("Input failed for session \(sessionID): \(error)")
                }
            }
            return nil

        case .resize(let sessionID, let rows, let cols):
            Task {
                do {
                    try await self.manager.resize(sessionID: sessionID, rows: rows, cols: cols)
                } catch {
                    self.log.error("Resize failed for session \(sessionID): \(error)")
                }
            }
            return nil

        case .destroySession(let sessionID):
            Task {
                do {
                    try await self.manager.destroySession(sessionID: sessionID)
                } catch {
                    self.log.error("Destroy failed for session \(sessionID): \(error)")
                }
            }
            return nil
        }
    }

    func handleCancellation(error: XPCRichError) {
        log.info("Client disconnected: \(String(describing: error))")
        Task {
            await self.manager.clientDisconnected(self.session)
        }
    }

    // MARK: - Async bridging

    /// Block the current (GCD) thread to await an async closure that cannot
    /// throw.
    ///
    /// Uses `OSAllocatedUnfairLock` to transfer the result across isolation
    /// boundaries safely. This is intentionally used only on XPC dispatch
    /// queues, which have unbounded concurrency. Never call this from the
    /// cooperative thread pool or `@MainActor`.
    private func blockingAwait<T: Sendable>(
        _ work: @escaping @Sendable () async -> T
    ) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<T?>(initialState: nil)
        Task {
            let value = await work()
            box.withLock { $0 = value }
            semaphore.signal()
        }
        semaphore.wait()
        return box.withLock { $0! }
    }

    /// Block the current (GCD) thread to await an async throwing closure,
    /// returning the result or a ``DaemonError``.
    ///
    /// The thrown error is immediately converted to `DaemonError` so the
    /// result type is fully `Sendable` and can be stored in a lock.
    private func blockingAwaitResult<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) -> Result<T, DaemonError> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<Result<T, DaemonError>?>(initialState: nil)
        Task {
            do {
                let value = try await work()
                box.withLock { $0 = .success(value) }
            } catch {
                box.withLock { $0 = .failure(error.asDaemonError) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return box.withLock { $0! }
    }
}
