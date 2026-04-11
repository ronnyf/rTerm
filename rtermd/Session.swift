//
//  Session.swift
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

// MARK: - Session

/// Per-session state for a terminal managed by the daemon.
///
/// Each `Session` owns:
/// - A shell process spawned via `forkpty` (through ``ShellSpawner``)
/// - The primary file descriptor of the PTY pair
/// - A `TerminalParser` that converts raw bytes into `TerminalEvent` values
/// - A `ScreenModel` actor that maintains the current terminal grid
/// - A list of attached XPC clients that receive raw output
///
/// ## Concurrency model
///
/// Session is a plain class — not Sendable, not an actor. All access is
/// serialized by the daemon queue. No locks, no async streams, no tasks
/// for output consumption. The PTY read source targets the daemon queue
/// directly, so output handling runs inline with all other state mutations.
///
/// ## Lifecycle
///
/// 1. `init` spawns the shell and creates the PTY.
/// 2. `startOutputHandler()` installs the read source on the daemon queue.
/// 3. Clients call `attach`/`detach` over the session's lifetime.
/// 4. When the shell exits, `markExited` records the status and
///    `notifyClientsEnded` informs all attached clients.
/// 5. `stop()` tears down the read source, kills the shell, and closes the FD.
final class Session {

    // MARK: - Immutable identity

    let id: SessionID
    let shell: Shell
    let tty: String
    let pid: pid_t
    let primaryFD: Int32
    let createdAt: Date
    let screenModel: ScreenModel

    // MARK: - Mutable state (daemon queue only)

    /// Parser converts raw PTY bytes into terminal events.
    private var parser: TerminalParser

    /// XPC clients currently receiving output from this session.
    private var attachedClients: [XPCSession] = []

    /// Terminal dimensions, updated on resize.
    private var rows: UInt16
    private var cols: UInt16

    /// Exit status recorded by `markExited`, nil while the shell is running.
    private var exitStatus: Int32?

    /// Guards against double teardown in `stop()` / `deinit`.
    private var isStopped = false

    /// Callback invoked on EOF to notify SessionManager.
    var onEnded: ((SessionID) -> Void)?

    // MARK: - PTY reading

    /// Dispatch source monitoring the primary FD for readability.
    /// Targets the daemon queue so the handler runs inline with all other
    /// daemon state access.
    private var readSource: DispatchSourceRead?

    /// The daemon's serial queue — stored for read source targeting.
    private let queue: DispatchQueue

    // MARK: - Logging

    private static let log = Logger(subsystem: "com.ronnyf.rtermd", category: "Session")

    // MARK: - Initialization

    /// Spawn a shell and create the PTY.
    ///
    /// - Parameters:
    ///   - id: Unique session identifier assigned by ``SessionManager``.
    ///   - shell: Which shell to launch.
    ///   - rows: Initial terminal row count.
    ///   - cols: Initial terminal column count.
    ///   - queue: The daemon's serial dispatch queue for read source targeting.
    /// - Throws: ``SpawnError`` if `forkpty` fails.
    init(id: SessionID, shell: Shell, rows: UInt16, cols: UInt16, queue: DispatchQueue) throws {
        let result = try ShellSpawner.spawn(shell: shell, rows: rows, cols: cols)

        self.id = id
        self.shell = shell
        self.tty = result.ttyName
        self.pid = result.pid
        self.primaryFD = result.primaryFD
        self.createdAt = Date()
        self.rows = rows
        self.cols = cols
        self.queue = queue
        self.screenModel = ScreenModel(cols: Int(cols), rows: Int(rows))
        self.parser = TerminalParser()

        Self.log.info("Session \(id) created: shell=\(shell.executable), pid=\(result.pid), tty=\(result.ttyName)")
    }

    deinit {
        guard !isStopped else { return }
        teardown()
    }

    // MARK: - Output handler

    /// Install the PTY read source on the daemon queue.
    ///
    /// When the primary FD becomes readable, the handler:
    /// 1. Reads available data via POSIX `read`
    /// 2. On EOF: cancels the source and invokes `onEnded`
    /// 3. Parses bytes through `TerminalParser` into `[TerminalEvent]`
    /// 4. Fire-and-forget applies events to `ScreenModel` for reattach snapshots
    /// 5. Fans out `DaemonResponse.output` to all attached XPC clients
    ///
    /// Call once after `init`. Preconditions that no source is already installed.
    func startOutputHandler() {
        precondition(readSource == nil, "startOutputHandler() called twice")

        let source = DispatchSource.makeReadSource(fileDescriptor: primaryFD, queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.handleReadEvent()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            Self.log.debug("Session \(self.id): read source cancelled")
        }

        self.readSource = source
        source.resume()
    }

    /// Process a readability event from the dispatch source.
    private func handleReadEvent() {
        // Read into a stack buffer. 16 KiB matches typical PTY chunk sizes
        // and avoids heap allocation for the common case.
        let bufferSize = 16_384
        let data: Data = withUnsafeTemporaryAllocation(
            byteCount: bufferSize, alignment: MemoryLayout<UInt8>.alignment
        ) { buffer in
            let bytesRead = Darwin.read(primaryFD, buffer.baseAddress!, bufferSize)
            if bytesRead <= 0 {
                return Data()
            }
            return Data(bytes: buffer.baseAddress!, count: bytesRead)
        }

        if data.isEmpty {
            // EOF or error — shell closed the PTY secondary.
            readSource?.cancel()
            readSource = nil
            Self.log.info("Session \(self.id): PTY EOF")
            onEnded?(id)
            return
        }

        // 1. Parse raw bytes into terminal events.
        let events = parser.parse(data)

        // 2. Apply events to the screen model for reattach snapshots.
        //    ScreenModel is an actor; this fire-and-forget Task updates the
        //    daemon's cached screen state asynchronously. The latestSnapshot()
        //    nonisolated accessor remains available synchronously.
        let model = screenModel
        Task { await model.apply(events) }

        // 3. Fan out raw output to all attached clients.
        fanOutToClients(data)
    }

    /// Send raw output data to all currently attached XPC clients.
    ///
    /// Send failures are logged but do not remove the client — the client's
    /// XPC cancellation handler drives cleanup via `detach`.
    private func fanOutToClients(_ data: Data) {
        guard !attachedClients.isEmpty else { return }
        let response = DaemonResponse.output(sessionID: id, data: data)
        for client in attachedClients {
            do {
                try client.send(response)
            } catch {
                Self.log.error("Session \(self.id): failed to send output to client: \(error)")
            }
        }
    }

    // MARK: - Client management

    /// Attach an XPC client to this session.
    ///
    /// The client is added to the fan-out list **first**, then a screen
    /// snapshot is taken. This ordering ensures that output arriving between
    /// the add and the snapshot is delivered to the client (it may receive
    /// some data twice — once via fan-out, once baked into the snapshot —
    /// but `restore(from:)` on the client side overwrites with the
    /// authoritative snapshot, so this is harmless). The alternative
    /// (snapshot-then-add) risks losing output in the gap.
    ///
    /// - Parameter client: The XPC session representing the attaching client.
    /// - Returns: The current screen snapshot for initial rendering.
    func attach(client: XPCSession) -> ScreenSnapshot {
        attachedClients.append(client)
        let snapshot = screenModel.latestSnapshot()
        Self.log.info("Session \(self.id): client attached (count=\(self.attachedClients.count))")
        return snapshot
    }

    /// Detach an XPC client from this session.
    ///
    /// The client is removed by identity. The session continues running —
    /// detach does not terminate the shell.
    ///
    /// - Parameter client: The XPC session to detach.
    func detach(client: XPCSession) {
        attachedClients.removeAll { $0 === client }
        Self.log.info("Session \(self.id): client detached (count=\(self.attachedClients.count))")
    }

    /// Whether any clients are currently attached.
    var hasClients: Bool {
        !attachedClients.isEmpty
    }

    // MARK: - PTY I/O

    /// Write input data to the shell's PTY.
    ///
    /// Performs a full-write loop handling `EINTR` and partial writes,
    /// matching the pattern in ``PseudoTerminal``.
    ///
    /// - Parameter data: Raw bytes to write (typically keyboard input
    ///   encoded by `KeyEncoder`).
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard var ptr = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(primaryFD, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    Self.log.error("Session \(self.id): PTY write failed: errno=\(errno)")
                    return
                }
                ptr = ptr.advanced(by: written)
                remaining -= written
            }
        }
    }

    /// Resize the terminal window.
    ///
    /// Sends `TIOCSWINSZ` to the PTY so the shell and its children receive
    /// `SIGWINCH` and can reflow their output.
    ///
    /// - Parameters:
    ///   - rows: New terminal row count.
    ///   - cols: New terminal column count.
    func resize(rows: UInt16, cols: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let rc = ioctl(primaryFD, TIOCSWINSZ, &ws)
        if rc < 0 {
            Self.log.error("Session \(self.id): TIOCSWINSZ failed: errno=\(errno)")
        }
        self.rows = rows
        self.cols = cols
    }

    // MARK: - Exit handling

    /// Record that the shell process has exited.
    ///
    /// Called by ``SessionManager`` when `waitpid` reaps the child. This
    /// updates internal state but does not notify clients — call
    /// ``notifyClientsEnded(exitCode:)`` separately after bookkeeping.
    ///
    /// - Parameter exitCode: The shell's exit status.
    func markExited(exitCode: Int32) {
        self.exitStatus = exitCode
        Self.log.info("Session \(self.id): shell exited with code \(exitCode)")
    }

    /// Notify all attached clients that the session has ended, then clear
    /// the client list.
    ///
    /// Each client receives a `.sessionEnded` response. Send failures are
    /// logged but do not prevent other clients from being notified.
    ///
    /// - Parameter exitCode: The shell's exit status to report.
    func notifyClientsEnded(exitCode: Int32) {
        let response = DaemonResponse.sessionEnded(sessionID: id, exitCode: exitCode)
        for client in attachedClients {
            do {
                try client.send(response)
            } catch {
                Self.log.error("Session \(self.id): failed to notify client of exit: \(error)")
            }
        }
        attachedClients.removeAll()
    }

    // MARK: - Session info

    /// Metadata snapshot for this session, suitable for sending to clients
    /// in response to `.listSessions`.
    var info: SessionInfo {
        SessionInfo(
            id: id,
            shell: shell,
            tty: tty,
            pid: pid,
            createdAt: createdAt,
            title: nil,
            rows: rows,
            cols: cols,
            hasClient: !attachedClients.isEmpty
        )
    }

    // MARK: - Teardown

    /// Stop the session: cancel the read source, send SIGTERM to the shell,
    /// and close the primary FD.
    ///
    /// After `stop()`, the session is inert and should be removed from
    /// ``SessionManager``.
    func stop() {
        guard !isStopped else { return }
        teardown()
        Self.log.info("Session \(self.id): stopped")
    }

    /// Shared teardown logic for `stop()` and `deinit`.
    private func teardown() {
        isStopped = true
        readSource?.cancel()
        readSource = nil
        kill(pid, SIGTERM)
        close(primaryFD)
    }
}
