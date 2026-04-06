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

    @ObservationIgnored
    private let remotePTY: RemotePTY
    @ObservationIgnored
    private let log = Logger(subsystem: "rTerm", category: "TerminalSession")

    init(rows: Int = 24, cols: Int = 80) {
        screenModel = ScreenModel(cols: cols, rows: rows)
        remotePTY = RemotePTY()
    }

    /// Runs the output processing loop. Called from a `.task` modifier.
    ///
    /// The parser is created as a local variable because it is only used
    /// within this loop. A local `var` naturally provides the `mutating`
    /// semantics that `TerminalParser.parse(_:)` requires.
    func connect() async {
        do {
            try remotePTY.connect()
            let spawnReply = try remotePTY.sendSync(RemoteCommand.spawn)
            log.info("spawn reply: \(String(describing: spawnReply))")

            if case .spawned = spawnReply {
                var parser = TerminalParser()

                for await output in await remotePTY.outputData {
                    let events = parser.parse(Data(output))
                    await screenModel.apply(events)
                }
            }
        } catch {
            log.error("connect error: \(error.localizedDescription)")
        }
    }

    /// Sends keyboard input to the remote PTY.
    func sendInput(_ data: Data) {
        do {
            try remotePTY.send(command: RemoteCommand.input(data))
        } catch {
            log.error("sendInput error: \(error.localizedDescription)")
        }
    }
}

struct ContentView: View {
    @State private var session = TerminalSession()

    var body: some View {
        TermView(screenModel: session.screenModel, onInput: { data in
            session.sendInput(data)
        })
        .task {
            await session.connect()
        }
    }
}

#Preview {
    ContentView()
}
