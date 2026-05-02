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

    // MARK: - Bell does not affect cursor or grid

    @Test func bell_does_not_move_cursor_or_affect_grid() async {
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

    @Test func version_does_not_bump_on_sgr_only() async {
        let model = ScreenModel(cols: 5, rows: 1)
        let v0 = model.latestSnapshot().version
        await model.apply([.csi(.sgr([.bold]))])
        #expect(model.latestSnapshot().version == v0)
    }

    @Test func version_does_not_bump_on_save_cursor_only() async {
        let model = ScreenModel(cols: 5, rows: 1)
        let v0 = model.latestSnapshot().version
        await model.apply([.csi(.saveCursor)])
        #expect(model.latestSnapshot().version == v0)
    }

    @Test func version_does_not_bump_on_backspace_at_col_zero() async {
        let model = ScreenModel(cols: 5, rows: 1)
        let v0 = model.latestSnapshot().version
        await model.apply([.c0(.backspace)])
        #expect(model.latestSnapshot().version == v0)
    }

    @Test func version_does_not_bump_on_unchanged_window_title() async {
        let model = ScreenModel(cols: 5, rows: 1)
        await model.apply([.osc(.setWindowTitle("same"))])
        let v1 = model.latestSnapshot().version
        await model.apply([.osc(.setWindowTitle("same"))])
        #expect(model.latestSnapshot().version == v1)
    }

    @Test func version_does_not_bump_on_set_icon_name() async {
        let model = ScreenModel(cols: 5, rows: 1)
        let v0 = model.latestSnapshot().version
        await model.apply([.osc(.setIconName("anything"))])
        #expect(model.latestSnapshot().version == v0,
                "Phase 1: icon name is not surfaced in snapshot, so it must not bump version")
    }

    @Test func version_bumps_on_csi_cursor_position() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let v0 = model.latestSnapshot().version
        await model.apply([.csi(.cursorPosition(row: 5, col: 5))])
        #expect(model.latestSnapshot().version == v0 + 1)
    }
}

// MARK: - DEC private modes (Phase 2 T3)

struct ScreenModelModeTests {

    @Test("DECAWM disable: writing past last column overwrites the last cell")
    func test_decawm_off_overwrites_last_column() async {
        let model = ScreenModel(cols: 5, rows: 3)
        // Disable autoWrap.
        await model.apply([.csi(.setMode(.autoWrap, enabled: false))])
        // Fill the row past its end.
        let chars: [TerminalEvent] = "abcdefg".map { .printable($0) }
        await model.apply(chars)
        let snap = model.latestSnapshot()
        // Row 0: "abcdg" — the first 4 cells hold abcd; the last cell holds the
        // most-recently-written byte (g) because each subsequent write overwrites.
        let row0: String = (0..<5).map { String(snap[0, $0].character) }.joined()
        #expect(row0 == "abcdg")
        // Cursor stayed on row 0; no wrap occurred.
        #expect(snap.cursor.row == 0)
    }

    @Test("DECAWM re-enable: wrapping resumes after being turned back on")
    func test_decawm_reenable_wraps() async {
        let model = ScreenModel(cols: 3, rows: 2)
        await model.apply([.csi(.setMode(.autoWrap, enabled: false))])
        // Fill past the end with autoWrap off — cursor stays on row 0.
        await model.apply("abcde".map { .printable($0) })
        #expect(model.latestSnapshot().cursor.row == 0)
        // Re-enable DECAWM, then write one more — should wrap to row 1.
        await model.apply([
            .csi(.setMode(.autoWrap, enabled: true)),
            .printable("f"),
        ])
        #expect(model.latestSnapshot().cursor.row == 1)
    }

    @Test("DECTCEM disable: snapshot.cursorVisible reflects the change")
    func test_dectcem_off() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.setMode(.cursorVisible, enabled: false))])
        let snap = model.latestSnapshot()
        #expect(snap.cursorVisible == false)
    }

    @Test("DECCKM enable: snapshot.cursorKeyApplication = true")
    func test_decckm_on() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.setMode(.cursorKeyApplication, enabled: true))])
        #expect(model.latestSnapshot().cursorKeyApplication == true)
    }

    @Test("Bracketed paste enable: snapshot.bracketedPaste = true")
    func test_bracketed_paste_on() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.setMode(.bracketedPaste, enabled: true))])
        #expect(model.latestSnapshot().bracketedPaste == true)
    }

    @Test("Mode toggle to same value does not bump version")
    func test_mode_toggle_idempotent() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.csi(.setMode(.cursorKeyApplication, enabled: true))])
        let v1 = model.latestSnapshot().version
        await model.apply([.csi(.setMode(.cursorKeyApplication, enabled: true))])
        let v2 = model.latestSnapshot().version
        #expect(v1 == v2, "Idempotent mode set should not bump version")
    }

    // MARK: - Bell (Phase 2 T3)

    @Test("BEL increments bellCount and bumps version")
    func test_bell_increments_count() async {
        let model = ScreenModel(cols: 80, rows: 24)
        let v0 = model.latestSnapshot().version
        let b0 = model.latestSnapshot().bellCount
        await model.apply([.c0(.bell)])
        let snap = model.latestSnapshot()
        #expect(snap.bellCount == b0 + 1)
        #expect(snap.version == v0 + 1)
    }

    @Test("Three BELs in one batch increment bellCount by 3")
    func test_bell_batch_count() async {
        let model = ScreenModel(cols: 80, rows: 24)
        await model.apply([.c0(.bell), .c0(.bell), .c0(.bell)])
        #expect(model.latestSnapshot().bellCount == 3)
    }

    // MARK: - Restore preserves modes + bellCount

    @Test("restore(from:) re-seeds autoWrap, cursorKeyApplication, bracketedPaste, bellCount")
    func test_restore_preserves_modes_and_bell() async {
        let original = ScreenModel(cols: 80, rows: 24)
        await original.apply([
            .csi(.setMode(.autoWrap, enabled: false)),
            .csi(.setMode(.cursorKeyApplication, enabled: true)),
            .csi(.setMode(.bracketedPaste, enabled: true)),
            .c0(.bell), .c0(.bell)
        ])
        let snap = original.latestSnapshot()
        let restored = ScreenModel(cols: 80, rows: 24)
        await restored.restore(from: snap)
        let restoredSnap = restored.latestSnapshot()
        #expect(restoredSnap.autoWrap == false,
                "autoWrap=false must survive restore — otherwise client/daemon diverge on writes-past-margin")
        #expect(restoredSnap.cursorKeyApplication == true)
        #expect(restoredSnap.bracketedPaste == true)
        #expect(restoredSnap.bellCount == 2)
    }
}

// MARK: - Alt-screen modes (Phase 2 T4)

struct ScreenModelAltScreenTests {

    @Test("Mode 1049 enter saves main cursor, switches to alt (cleared), pen persists")
    func test_alt_screen_1049_enter() async {
        let model = ScreenModel(cols: 5, rows: 3)
        // Write some main-buffer content; move cursor to (1, 2).
        let main: [TerminalEvent] = [
            .printable("a"), .printable("b"), .printable("c"),
            .c0(.lineFeed),
            .printable("d"), .printable("e"),
        ]
        await model.apply(main)
        // Set a non-default pen so we can verify it persists across swap.
        await model.apply([.csi(.sgr([.bold]))])
        // Enter alt screen.
        await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
        let snap = model.latestSnapshot()
        #expect(snap.activeBuffer == .alt)
        #expect(snap.cursor == Cursor(row: 0, col: 0))
        // Alt grid is cleared.
        for r in 0..<3 {
            for c in 0..<5 {
                #expect(snap[r, c].character == " ")
            }
        }
        // Pen persistence — write a char and verify it has bold.
        await model.apply([.printable("x")])
        let after = model.latestSnapshot()
        #expect(after[0, 0].character == "x")
        #expect(after[0, 0].style.attributes.contains(.bold))
    }

    @Test("Mode 1049 exit returns to main with cursor restored, alt cleared")
    func test_alt_screen_1049_exit_restores_main() async {
        let model = ScreenModel(cols: 5, rows: 3)
        await model.apply([
            .printable("a"), .printable("b"),
            .c0(.lineFeed),
        ])
        // Cursor is now at (1, 0). Enter alt.
        await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
        // Write to alt.
        await model.apply([.printable("z")])
        // Exit alt.
        await model.apply([.csi(.setMode(.alternateScreen1049, enabled: false))])
        let snap = model.latestSnapshot()
        #expect(snap.activeBuffer == .main)
        // Main content is intact.
        #expect(snap[0, 0].character == "a")
        #expect(snap[0, 1].character == "b")
        // Cursor restored to where main was when 1049-enter happened.
        #expect(snap.cursor == Cursor(row: 1, col: 0))
        // Re-enter alt and verify it's cleared (1049 enter clears every time).
        await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
        let after = model.latestSnapshot()
        for r in 0..<3 {
            for c in 0..<5 {
                #expect(after[r, c].character == " ")
            }
        }
    }

    @Test("Mode 1047 enter switches + clears alt; exit clears alt + switches back; alt cursor persists across re-entry")
    func test_alt_screen_1047_cursor_persists_across_re_entry() async {
        let model = ScreenModel(cols: 4, rows: 2)
        await model.apply([
            .printable("a"), .printable("b"),
            .c0(.lineFeed),
            .printable("c"),
        ])
        // Cursor at (1, 1) on main.
        await model.apply([.csi(.setMode(.alternateScreen1047, enabled: true))])
        let snap = model.latestSnapshot()
        #expect(snap.activeBuffer == .alt)
        // Move alt cursor away from origin so we can verify it persists.
        // Land at col 2 + write 'Z' so the post-write cursor is (1, 3) — still
        // in-bounds (cols=4) so snapshotCursor doesn't deferred-wrap.
        await model.apply([
            .csi(.cursorPosition(row: 1, col: 2)),
            .printable("Z"),
        ])
        // Cursor on alt is now (1, 3) just past 'Z' (in-bounds).
        await model.apply([.csi(.setMode(.alternateScreen1047, enabled: false))])
        let exited = model.latestSnapshot()
        #expect(exited.activeBuffer == .main)
        // Main cursor was wherever it was when we entered alt — 1047 doesn't save/restore.
        // Re-enter alt: grid is cleared, but cursor persisted from last visit.
        await model.apply([.csi(.setMode(.alternateScreen1047, enabled: true))])
        let reentered = model.latestSnapshot()
        #expect(reentered.activeBuffer == .alt)
        // Grid is cleared (xterm 1047 clears on enter).
        for r in 0..<2 {
            for c in 0..<4 {
                #expect(reentered[r, c].character == " ", "Alt grid is cleared on re-entry")
            }
        }
        // Cursor persisted from last alt visit — distinguishes "1047 leaves alt
        // cursor alone" from "alt was freshly allocated at origin". The previous
        // alt visit left cursor at (1, 3) just past 'Z'.
        #expect(reentered.cursor.row == 1)
        #expect(reentered.cursor.col == 3)
    }

    @Test("Mode 47 toggles buffer without clear or cursor save (legacy)")
    func test_alt_screen_47_legacy() async {
        let model = ScreenModel(cols: 3, rows: 2)
        await model.apply([.printable("x")])
        await model.apply([.csi(.setMode(.alternateScreen47, enabled: true))])
        let snap = model.latestSnapshot()
        #expect(snap.activeBuffer == .alt)
        // Mode 47 does NOT clear alt — but our alt was empty anyway.
        // Write to alt, swap out, verify alt persists across swap.
        await model.apply([.printable("y")])
        await model.apply([.csi(.setMode(.alternateScreen47, enabled: false))])
        #expect(model.latestSnapshot().activeBuffer == .main)
        // Re-enter alt — y should still be there.
        await model.apply([.csi(.setMode(.alternateScreen47, enabled: true))])
        #expect(model.latestSnapshot()[0, 0].character == "y")
    }

    @Test("Mode 1048 saves cursor without buffer switch")
    func test_save_cursor_1048() async {
        let model = ScreenModel(cols: 5, rows: 3)
        await model.apply([
            .printable("a"), .printable("b"), .printable("c"),
        ])
        // Cursor at (0, 3). Save it via 1048.
        await model.apply([.csi(.setMode(.saveCursor1048, enabled: true))])
        // Move cursor; verify still on main.
        await model.apply([.csi(.cursorPosition(row: 2, col: 4))])
        let preRestore = model.latestSnapshot()
        #expect(preRestore.activeBuffer == .main)
        #expect(preRestore.cursor == Cursor(row: 2, col: 4))
        // Restore via 1048 disable.
        await model.apply([.csi(.setMode(.saveCursor1048, enabled: false))])
        #expect(model.latestSnapshot().cursor == Cursor(row: 0, col: 3))
    }

    @Test("Mode 1048 save/restore is per-buffer (alt and main keep independent slots)")
    func test_save_cursor_1048_per_buffer() async {
        let model = ScreenModel(cols: 5, rows: 3)
        // On main: move to (0, 2) and 1048-save.
        await model.apply([
            .csi(.cursorPosition(row: 0, col: 2)),
            .csi(.setMode(.saveCursor1048, enabled: true)),
        ])
        // Switch to alt (mode 1049 takes us to alt at origin).
        await model.apply([.csi(.setMode(.alternateScreen1049, enabled: true))])
        // On alt: move to (2, 4) and 1048-save.
        await model.apply([
            .csi(.cursorPosition(row: 2, col: 4)),
            .csi(.setMode(.saveCursor1048, enabled: true)),
        ])
        // Move cursor on alt elsewhere, then 1048-restore — must land at (2, 4),
        // alt's saved slot, NOT main's (0, 2).
        await model.apply([
            .csi(.cursorPosition(row: 1, col: 0)),
            .csi(.setMode(.saveCursor1048, enabled: false)),
        ])
        let altRestored = model.latestSnapshot()
        #expect(altRestored.activeBuffer == .alt)
        #expect(altRestored.cursor == Cursor(row: 2, col: 4),
                "1048 restore on alt uses alt.savedCursor, not main's")
        // Exit alt back to main; main's 1048 save is still in main.savedCursor.
        await model.apply([.csi(.setMode(.alternateScreen1049, enabled: false))])
        // Move main cursor elsewhere, then 1048-restore — must land at (0, 2),
        // main's saved slot.
        await model.apply([
            .csi(.cursorPosition(row: 1, col: 4)),
            .csi(.setMode(.saveCursor1048, enabled: false)),
        ])
        let mainRestored = model.latestSnapshot()
        #expect(mainRestored.activeBuffer == .main)
        #expect(mainRestored.cursor == Cursor(row: 0, col: 2),
                "1048 restore on main uses main.savedCursor, not alt's")
    }

    @Test("CSI s + writes + CSI u restores cursor (per active buffer)")
    func test_save_restore_cursor_csi_s_u() async {
        let model = ScreenModel(cols: 5, rows: 3)
        await model.apply([.printable("a"), .printable("b")])
        // Cursor (0, 2). Save.
        await model.apply([.csi(.saveCursor)])
        await model.apply([
            .csi(.cursorPosition(row: 2, col: 4)),
            .printable("z"),                           // grid mutation → version bump
            .csi(.restoreCursor),
        ])
        let snap = model.latestSnapshot()
        #expect(snap.cursor == Cursor(row: 0, col: 2))
    }

    @Test("ESC 7 / ESC 8 (DECSC / DECRC) behave the same as CSI s / CSI u")
    func test_esc_7_8_save_restore() async {
        let model = ScreenModel(cols: 5, rows: 3)
        var parser = TerminalParser()
        // Write 'a', save via ESC 7, move, write, restore via ESC 8.
        let bytes: [UInt8] = [
            0x61,                               // 'a'
            0x1B, 0x37,                          // ESC 7 — save
            0x1B, 0x5B, 0x33, 0x3B, 0x35, 0x48,  // CSI 3;5 H — move (1-indexed)
            0x7A,                                // 'z'
            0x1B, 0x38                           // ESC 8 — restore
        ]
        await model.apply(parser.parse(Data(bytes)))
        let snap = model.latestSnapshot()
        #expect(snap.cursor == Cursor(row: 0, col: 1))   // back to (0, col-after-'a')
    }

    @Test("Save/restore is per-buffer: alt and main keep separate saved cursors")
    func test_save_restore_per_buffer() async {
        let model = ScreenModel(cols: 5, rows: 3)
        // Save main cursor at (0, 0) (origin).
        await model.apply([.csi(.saveCursor)])
        // Move main cursor.
        await model.apply([.csi(.cursorPosition(row: 1, col: 2))])
        // Enter alt — writes go to alt. Save alt cursor (origin).
        await model.apply([
            .csi(.setMode(.alternateScreen1049, enabled: true)),
            .csi(.saveCursor),
        ])
        // Move alt cursor.
        await model.apply([.csi(.cursorPosition(row: 2, col: 3))])
        // Restore alt cursor → back to (0, 0) on alt.
        await model.apply([.csi(.restoreCursor)])
        let altRestored = model.latestSnapshot()
        #expect(altRestored.cursor == Cursor(row: 0, col: 0))
        #expect(altRestored.activeBuffer == .alt)
        // Exit alt back to main — main cursor restored from the 1049 save
        // (which was (1, 2) at the moment of 1049 enter; this overwrote the
        // earlier CSI s save at origin since both share main.savedCursor).
        await model.apply([.csi(.setMode(.alternateScreen1049, enabled: false))])
        #expect(model.latestSnapshot().cursor == Cursor(row: 1, col: 2))
        // CSI u restores from the same single main.savedCursor slot — still (1,2)
        // because 1049 enter clobbered the original origin save (xterm semantics:
        // DECSC and 1049 share one slot per buffer).
        await model.apply([.csi(.restoreCursor)])
        #expect(model.latestSnapshot().cursor == Cursor(row: 1, col: 2))
    }
}
