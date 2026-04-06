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

import AsyncAlgorithms
import CoreImage.CIFilterBuiltins
import OSLog
import SwiftUI
import System
import TermCore

@Observable
@MainActor
class Term {
    var rows: UInt16 = 24
    var cols: UInt16 = 80
    var text: String = ""
    
    var prompt: String = ""
        
    @ObservationIgnored
    var screenBuffer: ScreenBuffer<Line> = ScreenBuffer(capacity: 24)
    
    @ObservationIgnored
    var ttyPath: URL?
    @ObservationIgnored
    let inputChannel = AsyncChannel<Data>()
    @ObservationIgnored
    let remotePty: RemotePTY
    @ObservationIgnored
    let log = Logger(subsystem: "TermUI", category: "rTermApp")
    
    init(rows: UInt16 = 24, cols: UInt16 = 80, text: String = "", remotePty: RemotePTY = RemotePTY()) {
        self.rows = rows
        self.cols = cols
        self.text = text
        self.remotePty = remotePty
        try! remotePty.connect()
    }
    
    func update(text value: String) {
        self.text.append(value)
    }
    
    func update(ttyPath: URL) throws {
        self.ttyPath = ttyPath
    }
    
    // So here's the theory about something about compute performance, that I recently saw.
    // The enumeration of a Contiguous Array is much more performant because we don't need to jump all over
    // the address space to. I wish I had saved the youtube video of this to take a second look. Maybe I'll find it again.
    // For now let's go with efficient rather than quick. The ScreenBuffer should be implemented in a way that we can switch
    // from a Deque<Line> to ContiguousBytes maybe?
    
    typealias Line = Array<CChar?>
    
    func makeScreenBuffer() {
        // a line could be ['H','e','l','l','o']
        // or if we backspace from the end ['H','e',nil, nil, nil]
        // or when stuff gets deleted in the middle ['H','e',nil ,nil ,'o']
        // or when stuff gets inserted in the middle ['H','a','l','l','i','H','a','l','l','o']
        
        screenBuffer = ScreenBuffer<Line>(capacity: 24*10) // 10 pages of 80x24
    }
    
    nonisolated
    func connect() async throws {
        await makeScreenBuffer()
        
        let spawnReply = try await remotePty.send(command: RemoteCommand.spawn)
        print("spawn reply: \(spawnReply)")
        
        if case .spawned(_) = spawnReply {
            for await output in await remotePty.outputData {
                await screenBuffer.append(data: output)
            }
        }
    }
}

struct ScreenBufferView: View {
    
    @Binding var text: String
    private let textImageGenerator = CIFilter.textImageGenerator()
    
    var body: some View {
        EmptyView()
//        Canvas { context, size in
//            
//                        
////            context.draw(image, at: .zero)
//        }
    }
}

struct ContentView: View {
    
    @State var term = Term()
    @State private var requestID: UUID?
    @State private var command: String = ""
    
    var body: some View {
        VStack {
            ScreenBufferView(text: $command)
                .border(.red)
            TextEditor(text: $term.text)
            TextField("Prompt", text: $command)
                .onSubmit {
                    print("Submit \(command)")
                    term.prompt = command
                    command = ""
                }
                .task(id: term.prompt) {
                    guard term.prompt.isEmpty == false, let data = term.prompt.data(using: .utf8) else { return }
                    print("sending \(data)")
                    await term.inputChannel.send(data)
                }
        }
        .padding()
        .task {
            do {
                print("DEBUG: connecting...")
                try await term.connect()
                print("DEBUG: ...disconnected")
            } catch {
                print("ERROR: \(error)")
            }
        }
    }
}

#Preview {
    ContentView()
}
