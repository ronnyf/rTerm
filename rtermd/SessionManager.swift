//
//  SessionManager.swift
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

import Darwin
import Foundation
import os
import TermCore
import XPC

// MARK: - SessionManager

/// Central coordinator for all terminal sessions running inside the daemon.
///
/// `SessionManager` is a plain class — not an actor, not Sendable. All access
/// is serialized by the daemon's serial dispatch queue, so no locks or
/// async/await are needed. Every method is synchronous.
///
/// ## Why not an actor?
///
/// The original implementation used an actor, which required a semaphore-based
/// GCD-to-async bridge in `DaemonPeerHandler`. That bridge was the root cause
/// of a deadlock: blocking a GCD thread with a semaphore while a Task on the
/// cooperative pool tried to send on the same blocked queue. Making
/// `SessionManager` a plain class eliminates the bridge entirely —
/// `DaemonPeerHandler` calls methods directly on the daemon queue.
///
/// ## Lifecycle
///
/// 1. The daemon's `main.swift` creates a single `SessionManager` and passes
///    it to each ``DaemonPeerHandler`` spawned for incoming XPC connections.
/// 2. Clients send ``DaemonRequest`` messages, which the peer handler
///    translates into direct synchronous calls on this class.
/// 3. When a shell process exits, the daemon's `SIGCHLD` handler calls
///    ``reapChildren()`` to collect the exit status and clean up.
/// 4. When the last session is removed, the ``onEmpty`` callback fires so
///    the daemon can exit gracefully if configured to do so.
final class SessionManager {

    // MARK: - State

    /// The authoritative session registry. Keyed by ``SessionID``.
    private var sessions: [SessionID: Session] = [:]

    /// Monotonically increasing counter for session IDs.
    private var nextID: SessionID = 0

    /// The daemon's serial dispatch queue. All access to this class is
    /// serialized on this queue; it is also used as the target queue for
    /// per-session dispatch sources.
    private let queue: DispatchQueue

    /// Called when the last session is removed. The daemon uses this to
    /// schedule a graceful exit when no sessions remain.
    var onEmpty: (() -> Void)?

    private static let log = Logger(subsystem: "com.ronnyf.rtermd", category: "SessionManager")

    // MARK: - Init

    /// Create a new session manager.
    ///
    /// - Parameter queue: The daemon's serial dispatch queue. Passed through
    ///   to each ``Session`` for dispatch source targeting.
    init(queue: DispatchQueue) {
        self.queue = queue
    }

    // MARK: - Session count

    /// The number of active sessions.
    var sessionCount: Int {
        sessions.count
    }

    // MARK: - Create / Destroy

    /// Spawn a new terminal session with the given shell and initial size.
    ///
    /// Allocates a unique ``SessionID``, creates a ``Session`` on the daemon
    /// queue, wires the `onEnded` callback for PTY EOF handling, stores the
    /// session in the registry, and starts the output read source.
    ///
    /// - Parameters:
    ///   - shell: Which shell to launch.
    ///   - rows: Initial terminal row count.
    ///   - cols: Initial terminal column count.
    /// - Returns: Metadata about the newly created session.
    /// - Throws: ``DaemonError/spawnFailed(_:)`` if the shell cannot be spawned.
    func createSession(shell: Shell, rows: UInt16, cols: UInt16) throws -> SessionInfo {
        let id = nextID
        nextID += 1

        let session: Session
        do {
            session = try Session(id: id, shell: shell, rows: rows, cols: cols, queue: queue)
        } catch let spawnError as SpawnError {
            switch spawnError {
            case .forkFailed(let errNo):
                throw DaemonError.spawnFailed(errNo)
            }
        } catch {
            throw DaemonError.internalError(error.localizedDescription)
        }

        session.onEnded = { [weak self] sessionID in
            self?.handleSessionEnded(sessionID)
        }

        sessions[id] = session
        session.startOutputHandler()
        Self.log.info("Created session \(id): shell=\(shell.executable), pid=\(session.pid)")
        return session.info
    }

    /// Terminate a session and remove it from the registry.
    ///
    /// The session's shell is sent `SIGTERM`, its PTY is closed, and it is
    /// removed from the sessions dictionary. If this was the last session,
    /// the ``onEmpty`` callback fires.
    ///
    /// - Parameter sessionID: The session to destroy.
    /// - Throws: ``DaemonError/sessionNotFound(_:)`` if no such session exists.
    func destroySession(sessionID: SessionID) throws {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            throw DaemonError.sessionNotFound(sessionID)
        }
        session.stop()
        Self.log.info("Destroyed session \(sessionID)")
        checkEmpty()
    }

    // MARK: - Attach / Detach

    /// Attach an XPC client to a session, returning the current screen state.
    ///
    /// The client is added to the session's fan-out list and will receive
    /// raw PTY output going forward. The returned ``ScreenSnapshot`` allows
    /// the client to render the terminal immediately.
    ///
    /// - Parameters:
    ///   - sessionID: The session to attach to.
    ///   - client: The XPC session representing the attaching client.
    /// - Returns: A snapshot of the current terminal screen.
    /// - Throws: ``DaemonError/sessionNotFound(_:)`` if no such session exists.
    func attach(sessionID: SessionID, client: XPCSession) throws -> ScreenSnapshot {
        guard let session = sessions[sessionID] else {
            throw DaemonError.sessionNotFound(sessionID)
        }
        return session.attach(client: client)
    }

    /// Detach an XPC client from a session.
    ///
    /// The client is removed from the session's fan-out list. The session
    /// continues running — detach does not terminate the shell.
    ///
    /// - Parameters:
    ///   - sessionID: The session to detach from.
    ///   - client: The XPC session to remove.
    func detach(sessionID: SessionID, client: XPCSession) {
        sessions[sessionID]?.detach(client: client)
    }

    // MARK: - Input / Resize

    /// Write input data to a session's PTY.
    ///
    /// - Parameters:
    ///   - sessionID: The target session.
    ///   - data: Raw bytes to write (typically keyboard input).
    /// - Throws: ``DaemonError/sessionNotFound(_:)`` if no such session exists.
    func handleInput(sessionID: SessionID, data: Data) throws {
        guard let session = sessions[sessionID] else {
            throw DaemonError.sessionNotFound(sessionID)
        }
        session.write(data)
    }

    /// Resize a session's terminal window.
    ///
    /// Sends `TIOCSWINSZ` to the PTY so the shell and its children receive
    /// `SIGWINCH` and can reflow their output.
    ///
    /// - Parameters:
    ///   - sessionID: The target session.
    ///   - rows: New terminal row count.
    ///   - cols: New terminal column count.
    /// - Throws: ``DaemonError/sessionNotFound(_:)`` if no such session exists.
    func resize(sessionID: SessionID, rows: UInt16, cols: UInt16) throws {
        guard let session = sessions[sessionID] else {
            throw DaemonError.sessionNotFound(sessionID)
        }
        session.resize(rows: rows, cols: cols)
    }

    // MARK: - Listing

    /// Return metadata for all active sessions.
    func listSessions() -> [SessionInfo] {
        sessions.values.map(\.info)
    }

    // MARK: - Child reaping

    /// Reap exited child processes via `waitpid`.
    ///
    /// Called from the daemon's `SIGCHLD` signal handler (which targets the
    /// daemon queue). Loops with `WNOHANG` to collect all children that have
    /// exited since the last call, matches each PID to a session, notifies
    /// attached clients, and removes the session from the registry.
    ///
    /// Uses inline bit arithmetic for WIFEXITED/WEXITSTATUS because Swift
    /// cannot call the C function-like macros directly:
    /// - `(status & 0x7F) == 0` for WIFEXITED
    /// - `(status >> 8) & 0xFF` for WEXITSTATUS
    ///
    /// When the last session is reaped, the ``onEmpty`` callback fires.
    func reapChildren() {
        var status: Int32 = 0
        while true {
            let pid = waitpid(-1, &status, WNOHANG)
            if pid <= 0 { break }

            let exited = (status & 0x7F) == 0
            let exitCode: Int32 = exited ? (status >> 8) & 0xFF : -1

            guard let (id, session) = sessions.first(where: { $0.value.pid == pid }) else {
                Self.log.warning("Reaped unknown child pid=\(pid), exit=\(exitCode)")
                continue
            }

            Self.log.info("Session \(id): shell exited with code \(exitCode)")
            session.markExited(exitCode: exitCode)
            session.notifyClientsEnded(exitCode: exitCode)
            sessions.removeValue(forKey: id)
            checkEmpty()
        }
    }

    // MARK: - Session EOF

    /// Handle PTY EOF for a session.
    ///
    /// Called via the session's `onEnded` callback when the read source
    /// detects EOF or an unrecoverable read error. This is the PTY-driven
    /// counterpart to ``reapChildren()`` (which is SIGCHLD-driven). Whichever
    /// fires first removes the session; the other is a no-op because the
    /// session is already gone.
    ///
    /// - Parameter sessionID: The session that ended.
    private func handleSessionEnded(_ sessionID: SessionID) {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return  // Already reaped by SIGCHLD — nothing to do.
        }
        session.stop()
        Self.log.info("Session \(sessionID): ended via PTY EOF")
        checkEmpty()
    }

    // MARK: - Client disconnect

    /// Detach a client from every session it may be attached to.
    ///
    /// Called when an XPC peer handler detects cancellation (client crash or
    /// disconnect). This ensures the client does not remain in any session's
    /// fan-out list and receive send errors on subsequent output.
    ///
    /// - Parameter client: The disconnected XPC session.
    func clientDisconnected(_ client: XPCSession) {
        for session in sessions.values {
            session.detach(client: client)
        }
    }

    // MARK: - Shutdown

    /// Stop all sessions immediately.
    ///
    /// Sends `SIGTERM` to every shell, closes all PTYs, and clears the
    /// session registry. Called during daemon shutdown.
    func shutdownAll() {
        Self.log.info("Shutting down all \(self.sessions.count) sessions")
        let allSessions = Array(sessions.values)
        sessions.removeAll()
        for session in allSessions {
            session.onEnded = nil  // prevent callback into empty dictionary
            session.stop()
        }
    }

    // MARK: - Private

    /// Fire the ``onEmpty`` callback if no sessions remain.
    private func checkEmpty() {
        if sessions.isEmpty {
            Self.log.info("No sessions remaining")
            onEmpty?()
        }
    }
}
