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

// MARK: - DaemonPeerHandler

/// XPC peer handler for the daemon side of a client connection.
///
/// Each incoming XPC connection gets its own `DaemonPeerHandler` instance,
/// created by the `XPCListener` accept closure in `main.swift`. The handler
/// receives auto-decoded ``DaemonRequest`` messages and routes them to the
/// shared ``SessionManager``.
///
/// ## Custom executor
///
/// This actor uses a custom `SerialExecutor` backed by the daemon's serial
/// dispatch queue. This means the actor's isolation context IS the XPC
/// callback context — the `XPCListener`'s target queue is the same serial
/// queue. Because `XPCPeerHandler` methods are called synchronously on that
/// queue, `assumeIsolated` safely enters actor context without suspension.
actor DaemonPeerHandler: XPCPeerHandler {
    typealias Input = DaemonRequest
    typealias Output = any Encodable

    /// Per-client XPC session, used for identity and push messages.
    private let session: XPCSession

    /// Shared session manager — all methods are synchronous.
    private let manager: SessionManager

    /// The daemon's serial dispatch queue, backing this actor's executor.
    private let queue: DispatchSerialQueue

    private static let log = Logger(subsystem: "com.ronnyf.rtermd", category: "DaemonPeerHandler")

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    init(session: XPCSession, manager: SessionManager, queue: DispatchQueue) {
        self.session = session
        self.manager = manager
        // A serial DispatchQueue IS a DispatchSerialQueue at runtime.
        // DispatchSerialQueue conforms to SerialExecutor.
        self.queue = queue as! DispatchSerialQueue
        Self.log.info("Client connected")
    }

    // MARK: - XPCPeerHandler

    // These methods are nonisolated because XPCPeerHandler protocol methods
    // are called synchronously from XPC's dispatch queue. Since the actor's
    // custom executor IS that same queue, we use assumeIsolated to enter
    // actor context without suspension.

    nonisolated func handleIncomingRequest(_ request: DaemonRequest) -> (any Encodable)? {
        self.assumeIsolated { handler in
            handler.processRequest(request)
        }
    }

    nonisolated func handleCancellation(error: XPCRichError) {
        self.assumeIsolated { handler in
            handler.processCancel(error: error)
        }
    }

    // MARK: - Private (actor-isolated)

    /// Route a decoded request to the appropriate SessionManager method.
    ///
    /// Returns a ``DaemonResponse`` for request-reply messages, or `nil` for
    /// fire-and-forget messages where no reply is needed.
    private func processRequest(_ request: DaemonRequest) -> (any Encodable)? {
        switch request {
        case .listSessions:
            return DaemonResponse.sessions(manager.listSessions())

        case .createSession(let shell, let rows, let cols):
            do {
                let info = try manager.createSession(shell: shell, rows: rows, cols: cols)
                return DaemonResponse.sessionCreated(info)
            } catch {
                return DaemonResponse.error(error.asDaemonError)
            }

        case .attach(let sessionID):
            do {
                let snapshot = try manager.attach(sessionID: sessionID, client: session)
                return DaemonResponse.screenSnapshot(sessionID: sessionID, snapshot: snapshot)
            } catch {
                return DaemonResponse.error(error.asDaemonError)
            }

        case .detach(let sessionID):
            manager.detach(sessionID: sessionID, client: session)
            return nil

        case .input(let sessionID, let data):
            do {
                try manager.handleInput(sessionID: sessionID, data: data)
            } catch {
                Self.log.error("Input failed for session \(sessionID): \(error)")
            }
            return nil

        case .resize(let sessionID, let rows, let cols):
            do {
                try manager.resize(sessionID: sessionID, rows: rows, cols: cols)
            } catch {
                Self.log.error("Resize failed for session \(sessionID): \(error)")
            }
            return nil

        case .destroySession(let sessionID):
            do {
                try manager.destroySession(sessionID: sessionID)
            } catch {
                Self.log.error("Destroy failed for session \(sessionID): \(error)")
            }
            return nil
        }
    }

    /// Handle XPC peer disconnection by detaching from all sessions.
    private func processCancel(error: XPCRichError) {
        Self.log.info("Client disconnected: \(String(describing: error))")
        manager.clientDisconnected(session)
    }
}

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
