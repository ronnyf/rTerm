//
//  TerminalIntegrationTests.swift
//  TermCoreTests
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

import Testing
import Foundation
@testable import TermCore

@Suite struct TerminalIntegrationTests {

    // MARK: - Inline fixtures

    /// `CSI 2 J` (erase entire display) + `CSI H` (cursor home).
    private static let clearSequence: [UInt8] = [
        0x1B, 0x5B, 0x32, 0x4A,   // ESC [ 2 J
        0x1B, 0x5B, 0x48,          // ESC [ H
    ]

    /// Minimal `ls --color` excerpt:
    /// `ESC[34m` → fg blue
    /// `drwx` → literal text
    /// `ESC[0m` → reset
    /// ` foo\n` → literal
    private static let lsColorSequence: [UInt8] = [
        0x1B, 0x5B, 0x33, 0x34, 0x6D,                    // ESC [ 34 m
        0x64, 0x72, 0x77, 0x78,                          // drwx
        0x1B, 0x5B, 0x30, 0x6D,                          // ESC [ 0 m
        0x20, 0x66, 0x6F, 0x6F, 0x0A,                    // _foo\n
    ]

    /// Vim startup prefix — alt screen enter (mode 1049, T4), followed by
    /// CSI 2 J (erase display) and CSI H (cursor home). After T4 the parser
    /// emits `.csi(.setMode(.alternateScreen1049, enabled: true))` and
    /// ScreenModel switches to alt + clears + homes cursor.
    private static let vimStartupSequence: [UInt8] = [
        0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68,  // ESC [ ? 1049 h
        0x1B, 0x5B, 0x32, 0x4A,                          // ESC [ 2 J
        0x1B, 0x5B, 0x48,                                // ESC [ H
    ]

    // MARK: - Tests

    @Test func clear_resets_screen_and_cursor() async {
        let model = ScreenModel(cols: 10, rows: 3)
        await model.apply([.printable("X")])  // seed some junk
        var parser = TerminalParser()
        await model.apply(parser.parse(Data(Self.clearSequence)))
        let snap = model.latestSnapshot()
        #expect(snap.cursor == Cursor(row: 0, col: 0))
        for r in 0..<snap.rows { for c in 0..<snap.cols {
            #expect(snap[r, c].character == " ")
        }}
    }

    @Test func ls_color_produces_styled_cells() async {
        let model = ScreenModel(cols: 80, rows: 24)
        var parser = TerminalParser()
        await model.apply(parser.parse(Data(Self.lsColorSequence)))
        let snap = model.latestSnapshot()
        // The first 'd' should have blue fg.
        #expect(snap[0, 0].character == "d")
        #expect(snap[0, 0].style.foreground == .ansi16(4))  // ANSI blue
        // After the reset, " foo" should be default-styled.
        #expect(snap[0, 4].style.foreground == .default)
    }

    @Test func split_chunks_reach_same_final_state() async {
        let data = Data(Self.lsColorSequence)
        // Parse all at once:
        var parserA = TerminalParser()
        let modelA = ScreenModel(cols: 80, rows: 24)
        await modelA.apply(parserA.parse(data))
        // Parse one byte at a time:
        var parserB = TerminalParser()
        let modelB = ScreenModel(cols: 80, rows: 24)
        for i in 0..<data.count {
            await modelB.apply(parserB.parse(data.subdata(in: i..<i+1)))
        }
        let snapA = modelA.latestSnapshot()
        let snapB = modelB.latestSnapshot()
        #expect(snapA.activeCells == snapB.activeCells)
        #expect(snapA.cursor == snapB.cursor)
        #expect(snapA.cursorVisible == snapB.cursorVisible)
        #expect(snapA.windowTitle == snapB.windowTitle)
        #expect(snapA.activeBuffer == snapB.activeBuffer)
    }

    @Test func vim_startup_lands_in_alt_buffer_with_homed_cursor() async {
        // CSI ? 1049 h enters alt screen (saving main cursor + clearing alt);
        // CSI 2 J erases the (now active) alt grid; CSI H homes the cursor.
        // The combined sequence is what vim/htop/less emit on launch.
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.printable("X")])  // seed so erase has something to clear
        var parser = TerminalParser()
        await model.apply(parser.parse(Data(Self.vimStartupSequence)))
        let snap = model.latestSnapshot()
        #expect(snap.cursor == Cursor(row: 0, col: 0))
        #expect(snap.activeBuffer == .alt, "vim startup should land in alt buffer (mode 1049)")
    }
}
