//
//  ContentView.swift
//  rTerm
//
//  Created by Ronny F on 6/19/24.
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

import OSLog
import SwiftUI
import TermCore

@Observable @MainActor
class TerminalSession {
    let screenModel: ScreenModel

    /// Mirror of `ScreenModel.currentWindowTitle()` kept in sync from the
    /// response handler. Drives SwiftUI `.navigationTitle`; `nil` until the
    /// shell issues OSC 0 / OSC 2.
    var windowTitle: String? = nil

    @ObservationIgnored
    private let client: DaemonClient
    @ObservationIgnored
    private let log = Logger(subsystem: "rTerm", category: "TerminalSession")
    @ObservationIgnored
    private let rows: UInt16
    @ObservationIgnored
    private let cols: UInt16

    /// The parser is protected by a lock because the response handler runs
    /// on the XPC queue (a `@Sendable` closure), and `TerminalParser.parse`
    /// is a mutating method. The XPC queue serializes calls, but the lock
    /// satisfies the `Sendable` capture requirement.
    @ObservationIgnored
    private let parser = OSAllocatedUnfairLock(initialState: TerminalParser())

    private var sessionID: SessionID?

    init(rows: UInt16 = 24, cols: UInt16 = 80) {
        self.rows = rows
        self.cols = cols
        screenModel = ScreenModel(cols: Int(cols), rows: Int(rows))
        client = DaemonClient()
    }

    // No deinit needed — the daemon detaches the client automatically
    // when the XPC connection drops (DaemonPeerHandler.handleCancellation).

    /// Connect to the daemon, create a session, and begin receiving output.
    ///
    /// Called from a `.task` modifier. The method installs a push-based
    /// response handler for daemon messages and then returns (it does not
    /// loop). The handler dispatches UI-affecting work to `MainActor`.
    func connect() async {
        do {
            try await client.connect()

            installResponseHandler()

            let reply = try client.sendSync(
                .createSession(shell: .zsh, rows: rows, cols: cols)
            )
            log.info("createSession reply: \(String(describing: reply))")

            if case .sessionCreated(let info) = reply {
                sessionID = info.id

                // Attach to receive output. The snapshot covers any output
                // produced between session creation and attach.
                let attachReply = try client.sendSync(.attach(sessionID: info.id))
                if case .screenSnapshot(_, let snapshot) = attachReply {
                    await screenModel.restore(from: snapshot)
                }
            }
        } catch {
            log.error("connect error: \(error.localizedDescription)")
        }
    }

    /// Sends keyboard input to the daemon for the active session.
    func sendInput(_ data: Data) {
        guard let sessionID else {
            log.warning("sendInput called with no active session")
            return
        }
        log.debug("sendInput: \(data.count) bytes")
        do {
            try client.send(.input(sessionID: sessionID, data: data))
        } catch {
            log.error("sendInput error: \(error.localizedDescription)")
        }
    }

    /// Notify the daemon that the terminal size has changed.
    func resize(rows: UInt16, cols: UInt16) {
        guard let sessionID else { return }
        do {
            try client.send(.resize(sessionID: sessionID, rows: rows, cols: cols))
        } catch {
            log.error("resize error: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    /// Install the push-based response handler on the daemon client.
    ///
    /// The handler runs on the XPC queue. It parses output data under the
    /// parser lock, then hands events to `ScreenModel` via its own executor.
    /// `windowTitle` is refreshed on the MainActor after every apply / restore
    /// so SwiftUI `.navigationTitle` stays in sync with OSC 0 / OSC 2.
    private func installResponseHandler() {
        let screenModel = self.screenModel
        let parser = self.parser
        let log = self.log

        client.setResponseHandler { [self] response in
            switch response {
            case .output(_, let data):
                log.debug("Received output: \(data.count) bytes")
                let events = parser.withLock { $0.parse(data) }
                Task { @MainActor in
                    await screenModel.apply(events)
                    self.windowTitle = await screenModel.currentWindowTitle()
                }

            case .screenSnapshot(_, let snapshot):
                log.info("Received screen snapshot")
                Task { @MainActor in
                    await screenModel.restore(from: snapshot)
                    self.windowTitle = await screenModel.currentWindowTitle()
                }

            case .sessionEnded(let sid, let exitCode):
                log.info("Session \(sid) ended with exit code \(exitCode)")

            case .error(let error):
                log.error("Daemon error: \(String(describing: error))")

            default:
                break
            }
        }
    }
}

struct ContentView: View {
    @State private var session = TerminalSession()

    var body: some View {
        TermView(screenModel: session.screenModel, onInput: { data in
            session.sendInput(data)
        })
        .navigationTitle(session.windowTitle ?? "rTerm")
        .task {
            do {
                try Agent().register()
            } catch {
                print("ERROR: \(error)")
            }
            await session.connect()
        }
    }
}

#Preview {
    ContentView()
}
