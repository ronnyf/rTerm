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
import Synchronization
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
    private let parser = Mutex(TerminalParser())

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
                if case .attachPayload(_, let payload) = attachReply {
                    await screenModel.restore(from: payload)
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

    // MARK: - Bracketed paste (Phase 2 T8)

    /// Wrap pasted text with the bracketed-paste envelope when enabled.
    ///
    /// Shells that have set DEC private mode 2004 expect the envelope so they
    /// can distinguish pasted bytes from typed bytes (vim, fish, zsh-with-syntax-
    /// highlighting all use this to suppress autoindent and key-binding triggers
    /// during paste). When 2004 is off, the raw UTF-8 bytes are sent verbatim.
    nonisolated public static func bracketedPasteWrap(_ text: String, enabled: Bool) -> Data {
        let payload = Data(text.utf8)
        guard enabled else { return payload }
        var data = Data()
        data.reserveCapacity(payload.count + 12)
        data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])  // ESC [ 2 0 0 ~
        data.append(payload)
        data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])  // ESC [ 2 0 1 ~
        return data
    }

    /// Send pasted text to the active session, wrapping if the shell has
    /// enabled bracketed paste (mode 2004).
    func paste(_ text: String) {
        let enabled = screenModel.latestSnapshot().bracketedPaste
        let data = Self.bracketedPasteWrap(text, enabled: enabled)
        sendInput(data)
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
        let log = self.log

        // `Mutex` is `~Copyable` so the parser can't be stashed in a local;
        // the closure captures `self` and reaches `self.parser` through it.
        client.setResponseHandler { [self] response in
            switch response {
            // .output uses ScreenModel.applyAndCurrentTitle to collapse the apply
            // and title read into one actor hop — this narrows the race where
            // two rapid chunks' MainActor continuations could reorder the title
            // reads. Task 7's snapshot reshape eliminates the MainActor race
            // entirely by publishing windowTitle through the nonisolated snapshot.
            case .output(_, let data):
                log.debug("Received output: \(data.count) bytes")
                let events = self.parser.withLock { $0.parse(data) }
                Task { @MainActor in
                    self.windowTitle = await screenModel.applyAndCurrentTitle(events)
                }

            case .attachPayload(_, let payload):
                log.info("Received attach payload")
                Task { @MainActor in
                    await screenModel.restore(from: payload)
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
    @State private var settings = AppSettings()

    var body: some View {
        TermView(
            screenModel: session.screenModel,
            settings: settings,
            onInput: { data in session.sendInput(data) },
            onPaste: { text in session.paste(text) }
        )
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
