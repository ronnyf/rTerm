//
//  ScreenModelTests.swift
//  TermCoreTests
//
//  Created by Ronny Falk on 4/6/26.
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
@testable import TermCore

struct ScreenModelTests {

    // MARK: - Print characters

    @Test func printCharacters() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .printable("B")])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 1].character == "B")
        #expect(snap.cursor == Cursor(row: 0, col: 2))
    }

    // MARK: - Newline

    @Test func newline() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .c0(.lineFeed), .printable("B")])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[1, 0].character == "B")
        #expect(snap.cursor == Cursor(row: 1, col: 1))
    }

    // MARK: - Carriage return

    @Test func carriageReturn() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([
            .printable("A"), .printable("B"),
            .c0(.carriageReturn),
            .printable("X"),
        ])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "X", "CR moved cursor to col 0, X overwrites A")
        #expect(snap[0, 1].character == "B", "B remains untouched")
        #expect(snap.cursor == Cursor(row: 0, col: 1))
    }

    // MARK: - Backspace

    @Test func backspace() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([
            .printable("A"), .printable("B"),
            .c0(.backspace),
            .printable("X"),
        ])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 1].character == "X", "Backspace moved cursor back, X overwrites B")
        #expect(snap.cursor == Cursor(row: 0, col: 2))
    }

    // MARK: - Backspace at column 0

    @Test func backspaceAtColumnZero() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.c0(.backspace)])
        let snap = await model.snapshot()

        #expect(snap.cursor == Cursor(row: 0, col: 0), "Backspace at col 0 stays at col 0")
    }

    // MARK: - Tab

    @Test func tab() async {
        let model = ScreenModel(cols: 4, rows: 3)
        // col 0: print "A" -> cursor at col 1
        // tab from col 1: next multiple of 8 is 8, clamped to cols-1 = 3 -> cursor at col 3
        // print "B" at col 3 -> cursor advances to col 4 -> wraps to (1, 0)
        await model.apply([.printable("A"), .c0(.horizontalTab), .printable("B")])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 3].character == "B", "Tab moved to col 3, B written there")
        #expect(snap.cursor == Cursor(row: 1, col: 0), "After writing at last col, cursor wraps")
    }

    // MARK: - Line wrap

    @Test func lineWrap() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([
            .printable("A"), .printable("B"), .printable("C"), .printable("D"),
            .printable("E"),
        ])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 1].character == "B")
        #expect(snap[0, 2].character == "C")
        #expect(snap[0, 3].character == "D")
        #expect(snap[1, 0].character == "E")
        #expect(snap.cursor == Cursor(row: 1, col: 1))
    }

    // MARK: - Scroll up

    @Test func scrollUp() async {
        let model = ScreenModel(cols: 4, rows: 3)

        // Fill all 3 rows: row0="AAAA", row1="BBBB", row2="CCCC"
        await model.apply(
            Array(repeating: TerminalEvent.printable("A"), count: 4)
            + [.c0(.lineFeed)]
            + Array(repeating: TerminalEvent.printable("B"), count: 4)
            + [.c0(.lineFeed)]
            + Array(repeating: TerminalEvent.printable("C"), count: 4)
        )

        // Now newline from the last row triggers scroll, then print on new last row
        await model.apply([.c0(.lineFeed), .printable("Z")])

        let snap = await model.snapshot()

        // After scroll: row0 was "AAAA" (gone), row0 is now old row1 "BBBB"
        #expect(snap[0, 0].character == "B", "Old row 1 scrolled to row 0")
        #expect(snap[1, 0].character == "C", "Old row 2 scrolled to row 1")
        #expect(snap[2, 0].character == "Z", "New content on last row")
        #expect(snap[2, 1].character == " ", "Rest of last row is empty")
    }

    // MARK: - Unrecognized events ignored

    @Test func unrecognizedEventsIgnored() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .unrecognized(0x01), .printable("B")])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 1].character == "B")
        #expect(snap.cursor == Cursor(row: 0, col: 2))
    }

    // MARK: - Bell is no-op

    @Test func bellIsNoOp() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .c0(.bell), .printable("B")])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 1].character == "B")
        #expect(snap.cursor == Cursor(row: 0, col: 2))
    }

    // MARK: - Snapshot is a value-type copy

    @Test func snapshotIsValueCopy() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A")])
        let first = await model.snapshot()

        await model.apply([.printable("Z")])
        let second = await model.snapshot()

        #expect(first[0, 0].character == "A", "First snapshot unchanged after further events")
        #expect(first.cursor == Cursor(row: 0, col: 1))
        #expect(second[0, 0].character == "A")
        #expect(second[0, 1].character == "Z")
        #expect(second.cursor == Cursor(row: 0, col: 2))
    }

    // MARK: - latestSnapshot matches actor-isolated snapshot

    @Test func latestSnapshotMatchesActorSnapshot() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .printable("B"), .c0(.lineFeed), .printable("C")])

        let actorSnap = await model.snapshot()
        let lockSnap = model.latestSnapshot()

        #expect(lockSnap == actorSnap, "Lock-based latestSnapshot must equal actor-isolated snapshot after apply")
    }

    // MARK: - Restore from snapshot

    @Test func restoreFromSnapshot() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .printable("B"), .c0(.lineFeed), .printable("C")])
        let saved = await model.snapshot()

        // Mutate the model further so state diverges from the saved snapshot.
        await model.apply([.printable("Z"), .printable("Z")])

        // Restore should reset the model to the saved state.
        await model.restore(from: saved)
        let restored = await model.snapshot()

        #expect(restored == saved, "Restored snapshot must equal the saved snapshot")
        #expect(restored.cursor == Cursor(row: 1, col: 1))
        #expect(restored[0, 0].character == "A")
        #expect(restored[0, 1].character == "B")
        #expect(restored[1, 0].character == "C")
    }

    @Test func restoreUpdatesLatestSnapshot() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("X")])

        // Build a snapshot to restore from.
        let target = ScreenSnapshot(
            activeCells: ContiguousArray(repeating: Cell(character: "Q"), count: 12),
            cols: 4,
            rows: 3,
            cursor: Cursor(row: 2, col: 3),
            version: 0
        )

        await model.restore(from: target)

        // The lock-based latestSnapshot must also reflect the restore.
        let lockSnap = model.latestSnapshot()
        #expect(lockSnap == target, "latestSnapshot() must match after restore")
    }

    @Test func restoreAllowsFurtherApply() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .printable("B")])
        let saved = await model.snapshot()

        // Restore and then apply more events on top.
        await model.restore(from: saved)
        await model.apply([.printable("C")])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 1].character == "B")
        #expect(snap[0, 2].character == "C", "Apply after restore writes at the restored cursor")
        #expect(snap.cursor == Cursor(row: 0, col: 3))
    }

    // MARK: - Deferred wrap then newline moves one row

    @Test func deferredWrapThenNewline() async {
        let model = ScreenModel(cols: 4, rows: 3)
        // Print exactly 4 characters to fill the row, then a newline.
        // Deferred wrap means cursor sits at col 4 (past the edge).
        // The newline should move to row 1, col 0 — NOT row 2.
        await model.apply([
            .printable("A"), .printable("B"), .printable("C"), .printable("D"),
            .c0(.lineFeed),
        ])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 3].character == "D")
        #expect(snap.cursor == Cursor(row: 1, col: 0),
                "Newline after filling last column should land at row 1, col 0")
    }

    @Test func verticalTab_behaves_as_lineFeed() async {
        let model = ScreenModel(cols: 10, rows: 3)
        await model.apply([.printable("A"), .c0(.verticalTab), .printable("B")])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 1)
        #expect(snap.cursor.col == 1)
    }

    @Test func formFeed_behaves_as_lineFeed() async {
        let model = ScreenModel(cols: 10, rows: 3)
        await model.apply([.printable("A"), .c0(.formFeed), .printable("B")])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 1)
        #expect(snap.cursor.col == 1)
    }

    @Test func nul_is_noop() async {
        let model = ScreenModel(cols: 10, rows: 3)
        await model.apply([.printable("A"), .c0(.nul), .printable("B")])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.col == 2)
    }
}

// MARK: - CSI cursor motion + erase handling

struct ScreenModelCSITests {

    @Test func cursor_position_sets_cursor() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.cursorPosition(row: 5, col: 10))])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 5)
        #expect(snap.cursor.col == 10)
    }

    @Test func cursor_position_clamps() async {
        let model = ScreenModel(cols: 10, rows: 5)
        await model.apply([.csi(.cursorPosition(row: 999, col: 999))])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 4)
        #expect(snap.cursor.col == 9)
    }

    @Test func cursor_up_clamps_at_top() async {
        let model = ScreenModel(cols: 10, rows: 5)
        await model.apply([.csi(.cursorUp(100))])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 0)
    }

    @Test func save_and_restore_cursor() async {
        let model = ScreenModel(cols: 10, rows: 5)
        await model.apply([
            .csi(.cursorPosition(row: 2, col: 3)),
            .csi(.saveCursor),
            .csi(.cursorPosition(row: 4, col: 9)),
            .csi(.restoreCursor)
        ])
        let snap = model.latestSnapshot()
        #expect(snap.cursor.row == 2)
        #expect(snap.cursor.col == 3)
    }

    @Test func erase_in_line_to_end() async {
        let model = ScreenModel(cols: 5, rows: 2)
        await model.apply([
            .printable("A"), .printable("B"), .printable("C"), .printable("D"), .printable("E"),
            .csi(.cursorPosition(row: 0, col: 2)),
            .csi(.eraseInLine(.toEnd))
        ])
        let snap = model.latestSnapshot()
        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 1].character == "B")
        #expect(snap[0, 2].character == " ")
        #expect(snap[0, 4].character == " ")
    }

    @Test func erase_in_display_all_clears_grid() async {
        let model = ScreenModel(cols: 3, rows: 2)
        await model.apply([
            .printable("A"), .printable("B"), .printable("C"),
            .csi(.eraseInDisplay(.all))
        ])
        let snap = model.latestSnapshot()
        for r in 0..<2 { for c in 0..<3 { #expect(snap[r, c].character == " ") } }
    }
}

// MARK: - SGR pen behavior

struct ScreenModelPenTests {

    @Test func bold_stamps_onto_subsequent_writes() async {
        let model = ScreenModel(cols: 5, rows: 1)
        await model.apply([
            .csi(.sgr([.bold])),
            .printable("A"), .printable("B")
        ])
        let snap = model.latestSnapshot()
        #expect(snap[0, 0].style.attributes.contains(.bold))
        #expect(snap[0, 1].style.attributes.contains(.bold))
    }

    @Test func reset_clears_pen() async {
        let model = ScreenModel(cols: 5, rows: 1)
        await model.apply([
            .csi(.sgr([.bold, .foreground(.ansi16(1))])),
            .printable("A"),
            .csi(.sgr([.reset])),
            .printable("B")
        ])
        let snap = model.latestSnapshot()
        #expect(snap[0, 0].style.foreground == .ansi16(1))
        #expect(snap[0, 0].style.attributes.contains(.bold))
        #expect(snap[0, 1].style == .default)
    }

    @Test func resetIntensity_clears_both_bold_and_dim() async {
        let model = ScreenModel(cols: 5, rows: 1)
        await model.apply([
            .csi(.sgr([.bold, .dim])),
            .csi(.sgr([.resetIntensity])),
            .printable("A")
        ])
        let snap = model.latestSnapshot()
        #expect(!snap[0, 0].style.attributes.contains(.bold))
        #expect(!snap[0, 0].style.attributes.contains(.dim))
    }

    @Test func truecolor_stored_at_full_fidelity() async {
        let model = ScreenModel(cols: 5, rows: 1)
        await model.apply([
            .csi(.sgr([.foreground(.rgb(10, 20, 30))])),
            .printable("A")
        ])
        let snap = model.latestSnapshot()
        #expect(snap[0, 0].style.foreground == .rgb(10, 20, 30))
    }

    @Test func foreground_default_resets_only_foreground() async {
        let model = ScreenModel(cols: 5, rows: 1)
        await model.apply([
            .csi(.sgr([.foreground(.ansi16(1)), .background(.ansi16(4))])),
            .csi(.sgr([.foreground(.default)])),
            .printable("A")
        ])
        let snap = model.latestSnapshot()
        #expect(snap[0, 0].style.foreground == .default)
        #expect(snap[0, 0].style.background == .ansi16(4))
    }
}

// MARK: - OSC window title / icon name handling

struct ScreenModelOSCTests {

    @Test func osc_sets_window_title() async {
        let model = ScreenModel(cols: 10, rows: 3)
        await model.apply([.osc(.setWindowTitle("hello"))])
        let title = await model.currentWindowTitle()
        #expect(title == "hello")
    }

    @Test func later_osc_replaces_earlier() async {
        let model = ScreenModel(cols: 10, rows: 3)
        await model.apply([
            .osc(.setWindowTitle("first")),
            .osc(.setWindowTitle("second"))
        ])
        let title = await model.currentWindowTitle()
        #expect(title == "second")
    }

    @Test func set_icon_name_does_not_change_window_title() async {
        let model = ScreenModel(cols: 10, rows: 3)
        await model.apply([
            .osc(.setWindowTitle("T")),
            .osc(.setIconName("I"))
        ])
        let title = await model.currentWindowTitle()
        let icon = await model.currentIconName()
        #expect(title == "T")
        #expect(icon == "I")
    }

    @Test func apply_and_current_title_returns_post_apply_value() async {
        let model = ScreenModel(cols: 10, rows: 3)
        let title = await model.applyAndCurrentTitle([
            .osc(.setWindowTitle("combined"))
        ])
        #expect(title == "combined")
    }
}

// MARK: - Version counter

struct ScreenModelVersionTests {

    @Test func version_bumps_on_state_change() async {
        let model = ScreenModel(cols: 5, rows: 1)
        let v0 = model.latestSnapshot().version
        await model.apply([.printable("A")])
        let v1 = model.latestSnapshot().version
        #expect(v1 == v0 + 1)
    }

    @Test func version_does_not_bump_on_noop() async {
        let model = ScreenModel(cols: 5, rows: 1)
        await model.apply([.printable("A")])
        let v1 = model.latestSnapshot().version
        await model.apply([.c0(.nul), .unrecognized(0x99)])
        let v2 = model.latestSnapshot().version
        #expect(v1 == v2)
    }
}
