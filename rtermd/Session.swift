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
/// - A `FileHandle` reading PTY output into an `AsyncStream<Data>`
/// - A `TerminalParser` that converts raw bytes into `TerminalEvent` values
/// - A `ScreenModel` actor that maintains the current terminal grid
/// - A list of attached XPC clients that receive raw output
///
/// The class is `@unchecked Sendable` because mutable state (the attached
/// client list, exit status, and the parser) is protected by an
/// `OSAllocatedUnfairLock`. The parser is only mutated on the output
/// consumer task, which is serial by construction.
///
/// ## Lifecycle
///
/// 1. `init` spawns the shell and wires up PTY reading.
/// 2. `startOutputConsumer()` begins the async task that parses output and
///    fans it out to attached clients.
/// 3. Clients call `attach`/`detach` over the session's lifetime.
/// 4. When the shell exits, `markExited` records the status and
///    `notifyClientsEnded` informs all attached clients.
/// 5. `stop()` tears down the PTY and kills the shell.
final class Session: @unchecked Sendable {

    // MARK: - Immutable properties (safe to read from any isolation)

    let id: SessionID
    let shell: Shell
    let tty: String
    let pid: pid_t
    let primaryFD: Int32
    let createdAt: Date
    let screenModel: ScreenModel

    // MARK: - Private state

    /// Parser is only mutated by the output consumer task (serial).
    private var parser: TerminalParser

    /// FileHandle wrapping the primary side of the PTY pair.
    private let primaryHandle: FileHandle

    /// Stream carrying raw PTY output from the readability handler to the
    /// output consumer task.
    private let outputStream: AsyncStream<Data>
    private let outputContinuation: AsyncStream<Data>.Continuation

    /// The task consuming `outputStream` (parse, apply, fan-out).
    private var outputTask: Task<Void, Never>?

    /// Lock-protected mutable state shared across isolation boundaries.
    private let lock: OSAllocatedUnfairLock<SessionState>

    private let log = Logger(subsystem: "com.ronnyf.rtermd", category: "Session")

    // MARK: - Lock-protected state

    struct SessionState: Sendable {
        var attachedClients: [XPCSession] = []
        var exitStatus: Int32?
        var rows: UInt16
        var cols: UInt16
        var isStopped = false
    }

    // MARK: - Initialization

    /// Spawn a shell and wire up PTY output reading.
    ///
    /// - Parameters:
    ///   - id: Unique session identifier assigned by ``SessionManager``.
    ///   - shell: Which shell to launch.
    ///   - rows: Initial terminal row count.
    ///   - cols: Initial terminal column count.
    /// - Throws: ``SpawnError`` if `forkpty` fails.
    init(id: SessionID, shell: Shell, rows: UInt16, cols: UInt16) throws {
        let result = try ShellSpawner.spawn(shell: shell, rows: rows, cols: cols)

        self.id = id
        self.shell = shell
        self.tty = result.ttyName
        self.pid = result.pid
        self.primaryFD = result.primaryFD
        self.createdAt = Date()
        self.screenModel = ScreenModel(cols: Int(cols), rows: Int(rows))
        self.parser = TerminalParser()
        self.primaryHandle = FileHandle(fileDescriptor: result.primaryFD, closeOnDealloc: false)
        self.lock = OSAllocatedUnfairLock(initialState: SessionState(rows: rows, cols: cols))

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.outputStream = stream
        self.outputContinuation = continuation

        // FileHandle.readabilityHandler runs on a Foundation-managed background
        // dispatch queue. When the PTY yields data, feed it into the AsyncStream.
        // An empty read signals EOF.
        primaryHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.outputContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                self?.outputContinuation.yield(data)
            }
        }

        log.info("Session \(id) created: shell=\(shell.executable), pid=\(result.pid), tty=\(result.ttyName)")
    }

    deinit {
        let alreadyStopped = lock.withLock { $0.isStopped }
        guard !alreadyStopped else { return }
        primaryHandle.readabilityHandler = nil
        outputContinuation.finish()
        outputTask?.cancel()
        kill(pid, SIGTERM)
        close(primaryFD)
        kill(pid, SIGTERM)
    }

    // MARK: - Output consumer

    /// Start the async task that reads PTY output, parses it through
    /// `TerminalParser`, applies events to `ScreenModel`, and fans out
    /// raw bytes to all attached XPC clients.
    ///
    /// Call this once after `init`. The task runs until the output stream
    /// ends (shell exits / PTY EOF) or is cancelled via `stop()`.
    func startOutputConsumer() {
        precondition(outputTask == nil, "startOutputConsumer() called twice")
        // The Task retains self for the duration of the stream. This is
        // intentional — the Session must stay alive while output is flowing.
        // Cleanup is driven by stop() or deinit, not by Task cancellation.
        outputTask = Task {
            for await data in self.outputStream {
                // 1. Fan out raw bytes to clients first — they parse locally,
                //    so don't make them wait for the daemon's actor hop.
                self.fanOutToClients(data)

                // 2. Parse and apply to the daemon's screen model (for reattach).
                let events = self.parser.parse(data)
                await self.screenModel.apply(events)
            }
            self.log.info("Session \(self.id): output stream ended")
        }
    }

    /// Send raw output data to all currently attached XPC clients.
    ///
    /// Runs under the lock to get a consistent snapshot of the client list.
    /// Send failures are logged but do not remove the client — the client's
    /// cancellation handler (set up by the peer handler) handles cleanup.
    private func fanOutToClients(_ data: Data) {
        let clients = lock.withLock { $0.attachedClients }
        let response = DaemonResponse.output(sessionID: id, data: data)
        for client in clients {
            do {
                try client.send(response)
            } catch {
                log.error("Session \(self.id): failed to send output to client: \(error)")
            }
        }
    }

    // MARK: - Client management

    /// Attach an XPC client to this session.
    ///
    /// The client is added to the fan-out list and receives a snapshot of
    /// the current screen state so it can render the terminal immediately
    /// without waiting for new output.
    ///
    /// - Parameter client: The XPC session representing the attaching client.
    /// - Returns: The current screen snapshot for initial rendering.
    func attach(client: XPCSession) async -> ScreenSnapshot {
        // Add client to fan-out list FIRST so any output arriving during
        // the snapshot await is also delivered to this client.
        lock.withLock { state in
            state.attachedClients.append(client)
        }
        let snapshot = await screenModel.snapshot()
        log.info("Session \(self.id): client attached")
        return snapshot
    }

    /// Detach an XPC client from this session.
    ///
    /// The client is removed from the fan-out list. The session continues
    /// running — it is not terminated by detach.
    ///
    /// - Parameter client: The XPC session to detach.
    func detach(client: XPCSession) {
        lock.withLock { state in
            state.attachedClients.removeAll { $0 === client }
        }
        log.info("Session \(self.id): client detached")
    }

    /// Whether any clients are currently attached.
    var hasClients: Bool {
        lock.withLock { !$0.attachedClients.isEmpty }
    }

    // MARK: - PTY I/O

    /// Write input data to the shell's PTY.
    ///
    /// Performs a full-write loop that handles `EINTR` and partial writes,
    /// matching the pattern used in ``PseudoTerminal``.
    ///
    /// - Parameter data: Raw bytes to write (typically keyboard input from
    ///   the client, encoded by `KeyEncoder`).
    func write(_ data: Data) {
        data.withUnsafeBytes { buffer in
            guard var ptr = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(primaryFD, ptr, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    log.error("Session \(self.id): PTY write failed: errno=\(errno)")
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
            log.error("Session \(self.id): TIOCSWINSZ failed: errno=\(errno)")
        }
        lock.withLock { state in
            state.rows = rows
            state.cols = cols
        }
    }

    // MARK: - Exit handling

    /// Record that the shell process has exited.
    ///
    /// Called by ``SessionManager`` when `waitpid` reaps the child. This
    /// updates the lock-protected state but does not notify clients — call
    /// ``notifyClientsEnded(exitCode:)`` separately after any bookkeeping.
    ///
    /// - Parameter exitCode: The shell's exit status.
    func markExited(exitCode: Int32) {
        lock.withLock { state in
            state.exitStatus = exitCode
        }
        log.info("Session \(self.id): shell exited with code \(exitCode)")
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
        let clients = lock.withLock { state -> [XPCSession] in
            let snapshot = state.attachedClients
            state.attachedClients.removeAll()
            return snapshot
        }
        for client in clients {
            do {
                try client.send(response)
            } catch {
                log.error("Session \(self.id): failed to notify client of exit: \(error)")
            }
        }
    }

    // MARK: - Session info

    /// Metadata snapshot for this session, suitable for sending to clients
    /// in response to `.listSessions`.
    var info: SessionInfo {
        let (clientCount, currentRows, currentCols) = lock.withLock {
            ($0.attachedClients.count, $0.rows, $0.cols)
        }
        return SessionInfo(
            id: id,
            shell: shell,
            tty: tty,
            pid: pid,
            createdAt: createdAt,
            title: nil,
            rows: currentRows,
            cols: currentCols,
            hasClient: clientCount > 0
        )
    }

    // MARK: - Teardown

    /// Stop the session: tear down PTY reading, cancel the output consumer,
    /// close the primary FD, and send SIGTERM to the shell.
    ///
    /// After `stop()`, the session is inert and should be removed from
    /// ``SessionManager``.
    func stop() {
        let alreadyStopped = lock.withLock { state in
            let was = state.isStopped
            state.isStopped = true
            return was
        }
        guard !alreadyStopped else { return }
        primaryHandle.readabilityHandler = nil
        outputContinuation.finish()
        outputTask?.cancel()
        kill(pid, SIGTERM)
        close(primaryFD)
        log.info("Session \(self.id): stopped")
    }
}
