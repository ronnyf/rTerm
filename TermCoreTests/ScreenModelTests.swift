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
        await model.apply([.printable("A"), .newline, .printable("B")])
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
            .carriageReturn,
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
            .backspace,
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
        await model.apply([.backspace])
        let snap = await model.snapshot()

        #expect(snap.cursor == Cursor(row: 0, col: 0), "Backspace at col 0 stays at col 0")
    }

    // MARK: - Tab

    @Test func tab() async {
        let model = ScreenModel(cols: 4, rows: 3)
        // col 0: print "A" -> cursor at col 1
        // tab from col 1: next multiple of 8 is 8, clamped to cols-1 = 3 -> cursor at col 3
        // print "B" at col 3 -> cursor advances to col 4 -> wraps to (1, 0)
        await model.apply([.printable("A"), .tab, .printable("B")])
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
            + [.newline]
            + Array(repeating: TerminalEvent.printable("B"), count: 4)
            + [.newline]
            + Array(repeating: TerminalEvent.printable("C"), count: 4)
        )

        // Now newline from the last row triggers scroll, then print on new last row
        await model.apply([.newline, .printable("Z")])

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
        await model.apply([.printable("A"), .bell, .printable("B")])
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
        await model.apply([.printable("A"), .printable("B"), .newline, .printable("C")])

        let actorSnap = await model.snapshot()
        let lockSnap = model.latestSnapshot()

        #expect(lockSnap == actorSnap, "Lock-based latestSnapshot must equal actor-isolated snapshot after apply")
    }

    // MARK: - Restore from snapshot

    @Test func restoreFromSnapshot() async {
        let model = ScreenModel(cols: 4, rows: 3)
        await model.apply([.printable("A"), .printable("B"), .newline, .printable("C")])
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
            cells: ContiguousArray(repeating: Cell(character: "Q"), count: 12),
            cols: 4,
            rows: 3,
            cursor: Cursor(row: 2, col: 3)
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
            .newline,
        ])
        let snap = await model.snapshot()

        #expect(snap[0, 0].character == "A")
        #expect(snap[0, 3].character == "D")
        #expect(snap.cursor == Cursor(row: 1, col: 0),
                "Newline after filling last column should land at row 1, col 0")
    }
}
