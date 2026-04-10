//
//  DaemonClient.swift
//  TermCore
//
//  Created by Ronny Falk on 4/9/26.
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
import XPCOverlay

// MARK: - ConnectionError

/// Errors specific to the daemon client connection lifecycle.
public enum ConnectionError: Error, Sendable {
    /// No XPC session is active. Call ``DaemonClient/connect()`` first.
    case notConnected
    /// The connection attempt failed with the given underlying description.
    case connectionFailed(String)
    /// All retry attempts exhausted without establishing a connection.
    case timeout
}

// MARK: - DaemonClient

/// XPC client for communicating with the rtermd daemon.
///
/// `DaemonClient` manages a single `XPCSession` to the daemon's Mach
/// service. It provides:
/// - Connection with exponential-backoff retry (1s, 2s, 4s).
/// - A push-based response handler for daemon-initiated messages
///   (e.g. `.output`, `.sessionEnded`).
/// - Fire-and-forget ``send(_:)`` for latency-sensitive paths like
///   keyboard input.
/// - Synchronous ``sendSync(_:)`` for request-reply interactions like
///   session creation.
///
/// The class is `Sendable`; all mutable state lives behind an
/// `OSAllocatedUnfairLock`.
///
/// ## Usage
///
/// ```swift
/// let client = DaemonClient()
/// client.setResponseHandler { response in
///     // Handle push messages from daemon
/// }
/// try await client.connect()
/// let response = try client.sendSync(.createSession(shell: .zsh, rows: 24, cols: 80))
/// ```
public final class DaemonClient: Sendable {

    /// Mutable state protected by an unfair lock for `Sendable` conformance.
    private struct ClientState: Sendable {
        var xpcSession: XPCSession?
        var responseHandler: (@Sendable (DaemonResponse) -> Void)?
    }

    private let serviceName: String
    private let log = Logger.TermCore.daemonClient
    private let state: OSAllocatedUnfairLock<ClientState>

    /// Create a client targeting the specified Mach service.
    ///
    /// - Parameter serviceName: The Mach service name registered by the
    ///   daemon's `XPCListener`. Defaults to the standard rtermd service.
    public init(serviceName: String = "group.com.ronnyf.rterm.rtermd") {
        self.serviceName = serviceName
        self.state = OSAllocatedUnfairLock(initialState: ClientState())
    }

    deinit {
        state.withLock { state in
            state.xpcSession?.cancel(reason: "deinit")
        }
    }

    // MARK: - Connection

    /// Connect to the daemon with exponential-backoff retry.
    ///
    /// Attempts up to four times with delays of 1s, 2s, and 4s between
    /// the first three failures. If all attempts fail, throws
    /// ``ConnectionError/timeout``.
    ///
    /// This method is safe to call when already connected; the existing
    /// session is replaced.
    public func connect() async throws {
        let backoffNanoseconds: [UInt64] = [
            1_000_000_000,  // 1s
            2_000_000_000,  // 2s
            4_000_000_000,  // 4s
        ]

        for (attempt, delay) in backoffNanoseconds.enumerated() {
            do {
                try connectOnce()
                log.info("Connected to \(self.serviceName)")
                return
            } catch {
                log.warning(
                    "Connection attempt \(attempt + 1) failed: \(error), retrying in \(delay / 1_000_000_000)s"
                )
                try await Task.sleep(nanoseconds: delay)
            }
        }

        // Final attempt — propagate the real error on failure.
        do {
            try connectOnce()
            log.info("Connected to \(self.serviceName)")
        } catch {
            log.error("All connection attempts exhausted for \(self.serviceName)")
            throw ConnectionError.timeout
        }
    }

    /// Single connection attempt. Creates the XPC session, installs the
    /// incoming message handler and cancellation handler, then stores
    /// the session under the lock.
    private func connectOnce() throws {
        let session = try XPCSession(
            machService: serviceName,
            targetQueue: .global(qos: .userInteractive)
        )

        // Incoming push messages from the daemon (output, sessionEnded, etc.)
        session.setIncomingMessageHandler { [weak self] (response: DaemonResponse) in
            guard let self else { return }
            let handler = self.state.withLock { $0.responseHandler }
            handler?(response)
        }

        // Handle XPC disconnection / cancellation.
        session.setCancellationHandler { [weak self] error in
            guard let self else { return }
            self.log.warning("XPC session cancelled: \(String(describing: error))")
            self.state.withLock { $0.xpcSession = nil }
        }

        // Replace any existing session.
        state.withLock { state in
            state.xpcSession?.cancel(reason: "Replaced by new connection")
            state.xpcSession = session
        }
    }

    // MARK: - Response handler

    /// Register a handler for push-based responses from the daemon.
    ///
    /// The handler is called on the XPC target queue whenever the daemon
    /// sends a message that is not a reply to a specific request (e.g.
    /// `.output`, `.sessionEnded`).
    ///
    /// Setting a new handler replaces the previous one.
    public func setResponseHandler(_ handler: @escaping @Sendable (DaemonResponse) -> Void) {
        state.withLock { $0.responseHandler = handler }
    }

    // MARK: - Sending

    /// Send a fire-and-forget request to the daemon.
    ///
    /// Use this for latency-sensitive, non-reply paths such as
    /// `.input` and `.resize`.
    ///
    /// - Throws: ``ConnectionError/notConnected`` if no session is active.
    public func send(_ request: DaemonRequest) throws {
        guard let session = state.withLock({ $0.xpcSession }) else {
            throw ConnectionError.notConnected
        }
        try session.send(request)
    }

    /// Send a request and wait synchronously for the daemon's reply.
    ///
    /// Use this for request-reply interactions such as `.createSession`,
    /// `.listSessions`, and `.attach`. The calling thread blocks until
    /// the daemon responds.
    ///
    /// - Returns: The daemon's ``DaemonResponse``.
    /// - Throws: ``ConnectionError/notConnected`` if no session is active,
    ///   or an XPC error if the send/receive fails.
    public func sendSync(_ request: DaemonRequest) throws -> DaemonResponse {
        guard let session = state.withLock({ $0.xpcSession }) else {
            throw ConnectionError.notConnected
        }
        return try session.sendSync(request)
    }

    // MARK: - Disconnection

    /// Disconnect from the daemon, cancelling the underlying XPC session.
    ///
    /// After calling this, ``send(_:)`` and ``sendSync(_:)`` will throw
    /// ``ConnectionError/notConnected`` until ``connect()`` is called again.
    public func disconnect() {
        state.withLock { state in
            state.xpcSession?.cancel(reason: "Client disconnect")
            state.xpcSession = nil
        }
    }

    /// Whether the client currently has an active XPC session.
    public var isConnected: Bool {
        state.withLock { $0.xpcSession != nil }
    }
}
