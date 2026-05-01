//
//  DaemonClient.swift
//  TermCore
//
//  Created by Ronny Falk on 4/10/26.
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
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Terminal App. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import OSLog
import Synchronization
import XPC

// MARK: - ConnectionError

/// Errors that can occur when establishing or using a daemon connection.
public enum ConnectionError: Error, Sendable {
    /// No XPC session is established. Call ``DaemonClient/connect()`` first.
    case notConnected
    /// The XPC connection attempt failed with the given reason.
    case connectionFailed(String)
    /// All retry attempts exhausted without a successful connection.
    case timeout
}

// MARK: - DaemonClient

/// XPC client for communicating with the rtermd daemon.
///
/// `DaemonClient` is `Sendable` because all mutable state (the XPC session
/// reference and the response handler closure) is protected by a `Mutex`
/// (Swift Synchronization, SE-0410).
///
/// The client uses the XPC constructor pattern that accepts
/// `incomingMessageHandler` and `cancellationHandler` directly -- the session
/// is auto-activated upon creation and is immediately ready to send/receive.
///
/// Push messages from the daemon (``DaemonResponse``) are delivered to a
/// caller-supplied response handler via ``setResponseHandler(_:)``. The handler
/// is invoked on the XPC queue -- callers must dispatch to `MainActor`
/// themselves if they need UI-safe access.
public final class DaemonClient: Sendable {

    // MARK: - Private state

    /// Protected mutable state. The lock is never held across XPC calls or
    /// the response handler callback to avoid priority inversion.
    private struct ClientState: Sendable {
        var xpcSession: XPCSession?
        var responseHandler: (@Sendable (DaemonResponse) -> Void)?
    }

    private let state: Mutex<ClientState>
    private let serviceName: String
    private let log = Logger.TermCore.daemonClient

    // MARK: - Init / deinit

    /// Creates a daemon client targeting the given Mach service name.
    ///
    /// - Parameter serviceName: The Mach service name registered by the daemon
    ///   launch agent. Defaults to ``DaemonService/machServiceName``.
    public init(serviceName: String = DaemonService.machServiceName) {
        self.serviceName = serviceName
        self.state = Mutex(ClientState())
    }

    deinit {
        let session = state.withLock { $0.xpcSession }
        session?.cancel(reason: "DaemonClient deinit")
    }

    // MARK: - Connection

    /// Whether an active XPC session is currently held.
    public var isConnected: Bool {
        state.withLock { $0.xpcSession != nil }
    }

    /// Connect to the daemon Mach service with exponential backoff retry.
    ///
    /// Retry schedule: 1s, 2s, 4s, then a final attempt. If all four attempts
    /// fail, ``ConnectionError/timeout`` is thrown.
    ///
    /// The XPC session is created using the constructor pattern -- handlers are
    /// passed directly and the session auto-activates.
    public func connect() async throws {
        let delays: [UInt64] = [
            1_000_000_000,  // 1s
            2_000_000_000,  // 2s
            4_000_000_000,  // 4s
        ]

        for delay in delays {
            do {
                try connectOnce()
                return
            } catch {
                log.warning("Connection attempt failed: \(error.localizedDescription), retrying...")
                try await Task.sleep(nanoseconds: delay)
            }
        }

        // Final attempt -- throw on failure.
        do {
            try connectOnce()
        } catch {
            log.error("All connection attempts exhausted")
            throw ConnectionError.timeout
        }
    }

    // MARK: - Response handler

    /// Install a push-based handler for daemon responses.
    ///
    /// The handler is called on the XPC queue whenever the daemon sends
    /// a push message. The `incomingMessageHandler` closure that was captured
    /// at session creation time reads the current handler from the lock each
    /// time it is invoked, so calling this method updates the behavior
    /// without recreating the session.
    public func setResponseHandler(_ handler: @escaping @Sendable (DaemonResponse) -> Void) {
        state.withLock { $0.responseHandler = handler }
    }

    // MARK: - Sending

    /// Send a fire-and-forget request to the daemon.
    ///
    /// - Throws: ``ConnectionError/notConnected`` if no session is active.
    public func send(_ request: DaemonRequest) throws {
        guard let session = state.withLock({ $0.xpcSession }) else {
            throw ConnectionError.notConnected
        }
        try session.send(request)
    }

    /// Send a request and synchronously wait for the daemon's reply.
    ///
    /// - Throws: ``ConnectionError/notConnected`` if no session is active.
    /// - Returns: The daemon's response.
    public func sendSync(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let session = state.withLock({ $0.xpcSession }) else {
            throw ConnectionError.notConnected
        }
        return try session.sendSync(request)
    }

    /// Disconnect from the daemon, cancelling the XPC session.
    public func disconnect() {
        let session = state.withLock { state -> XPCSession? in
            let s = state.xpcSession
            state.xpcSession = nil
            return s
        }
        session?.cancel(reason: "DaemonClient disconnect")
        log.info("Disconnected")
    }

    // MARK: - Private

    /// Establish a single XPC session using the constructor pattern.
    ///
    /// The `incomingMessageHandler` closure captures `self` weakly and reads
    /// the current response handler from the lock each time it is called.
    /// This allows `setResponseHandler(_:)` to update behavior without
    /// recreating the session.
    private func connectOnce() throws {
        // Cancel any existing session before creating a new one.
        let previous = state.withLock { state -> XPCSession? in
            let s = state.xpcSession
            state.xpcSession = nil
            return s
        }
        previous?.cancel(reason: "Replaced")

        let logRef = self.log

        // `Mutex` is `~Copyable`, so we can't stash a lock reference in a local
        // the way the prior `OSAllocatedUnfairLock` pattern did. The push
        // handler therefore captures `self` weakly and reaches `self.state`
        // through that — if the client is deallocated while a push is in
        // flight, the handler is silently skipped (no handler to invoke
        // anyway).
        let session = try XPCSession(
            machService: serviceName,
            targetQueue: nil,
            incomingMessageHandler: { [weak self] (response: DaemonResponse) -> (any Encodable)? in
                logRef.debug("Received push: \(String(describing: response))")
                let handler = self?.state.withLock { $0.responseHandler }
                handler?(response)
                return nil
            },
            cancellationHandler: { [weak self] error in
                logRef.error("XPC session cancelled: \(String(describing: error))")
                self?.state.withLock { $0.xpcSession = nil }
            }
        )

        state.withLock { $0.xpcSession = session }
        log.info("Connected to \(self.serviceName)")
    }
}
