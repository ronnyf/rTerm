//
//  DaemonProtocol.swift
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

// MARK: - DaemonService

/// Shared identifiers for the rtermd XPC service, used by both the client
/// (`DaemonClient`) and the daemon's `XPCListener`.
public enum DaemonService {
    /// Mach service name advertised by rtermd's LaunchAgent plist.
    public static let machServiceName = "com.ronnyf.rterm.rtermd"
}

// MARK: - SessionID

/// Unique identifier for a terminal session managed by the daemon.
public typealias SessionID = Int

// MARK: - DaemonRequest

/// Messages sent from the rTerm app to the rtermd daemon over XPC.
public enum DaemonRequest: Codable, Sendable, Equatable {
    /// List all active sessions.
    case listSessions
    /// Create a new terminal session with the specified shell and initial size.
    case createSession(shell: Shell, rows: UInt16, cols: UInt16)
    /// Attach to an existing session to begin receiving output.
    case attach(sessionID: SessionID)
    /// Detach from a session without terminating it.
    case detach(sessionID: SessionID)
    /// Send input data to a session's PTY.
    case input(sessionID: SessionID, data: Data)
    /// Resize a session's terminal window.
    case resize(sessionID: SessionID, rows: UInt16, cols: UInt16)
    /// Terminate a session and its shell process.
    case destroySession(sessionID: SessionID)
}

// MARK: - DaemonResponse

/// Messages sent from the rtermd daemon back to the rTerm app over XPC.
public enum DaemonResponse: Codable, Sendable, Equatable {
    /// The list of currently active sessions.
    case sessions([SessionInfo])
    /// A new session was created successfully.
    case sessionCreated(SessionInfo)
    /// Attach payload for a session: the current snapshot plus bounded
    /// scrollback history (empty in Phase 1; Phase 2 fills it).
    case attachPayload(sessionID: SessionID, payload: AttachPayload)
    /// A session has ended with the given exit code.
    case sessionEnded(sessionID: SessionID, exitCode: Int32)
    /// Raw output data from a session's PTY.
    case output(sessionID: SessionID, data: Data)
    /// An error occurred processing a request.
    case error(DaemonError)
}

// MARK: - DaemonError

/// Errors reported by the daemon to the client.
public enum DaemonError: Error, Codable, Sendable, Equatable {
    /// The requested session does not exist.
    case sessionNotFound(SessionID)
    /// Shell process spawn failed with the given errno.
    case spawnFailed(Int32)
    /// The session already has a client attached.
    case alreadyAttached(SessionID)
    /// An internal error with a human-readable description.
    case internalError(String)
}

// MARK: - SessionInfo

/// Metadata about a terminal session managed by the daemon.
///
/// Sent in response to `.listSessions` and `.createSession` requests.
public struct SessionInfo: Codable, Sendable, Equatable {
    /// Unique session identifier.
    public let id: SessionID
    /// The shell running in this session.
    public let shell: Shell
    /// Path to the TTY device (e.g. `/dev/ttys003`).
    public let tty: String
    /// PID of the shell process.
    public let pid: Int32
    /// When the session was created.
    public let createdAt: Date
    /// User-visible title (derived from the running command or shell name).
    public let title: String?
    /// Current terminal height.
    public let rows: UInt16
    /// Current terminal width.
    public let cols: UInt16
    /// Whether a client is currently attached to this session.
    public let hasClient: Bool

    public init(
        id: SessionID,
        shell: Shell,
        tty: String,
        pid: Int32,
        createdAt: Date,
        title: String?,
        rows: UInt16,
        cols: UInt16,
        hasClient: Bool
    ) {
        self.id = id
        self.shell = shell
        self.tty = tty
        self.pid = pid
        self.createdAt = createdAt
        self.title = title
        self.rows = rows
        self.cols = cols
        self.hasClient = hasClient
    }
}
