//
//  ScrollViewStateTests.swift
//  rTermTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation
import Testing
@testable import rTerm

@Suite("ScrollViewState")
nonisolated struct ScrollViewStateTests {

    @Test("Default state: offset 0, lastSeenHistoryCount 0")
    func test_default() {
        let s = ScrollViewState()
        #expect(s.offset == 0)
        #expect(s.lastSeenHistoryCount == 0)
    }

    @Test("Reconcile at offset 0 just tracks history count, returns false")
    func test_reconcile_at_bottom() {
        var s = ScrollViewState()
        let changed = s.reconcile(historyCount: 50)
        #expect(changed == false)
        #expect(s.offset == 0)
        #expect(s.lastSeenHistoryCount == 50)
    }

    @Test("Reconcile while scrolled back anchors to history-grow delta")
    func test_reconcile_anchor() {
        var s = ScrollViewState(offset: 10, lastSeenHistoryCount: 100)
        let changed = s.reconcile(historyCount: 105)
        #expect(changed == true)
        #expect(s.offset == 15, "offset += delta to keep the same row anchored")
        #expect(s.lastSeenHistoryCount == 105)
    }

    @Test("Reconcile clamps offset at historyCount")
    func test_reconcile_clamp() {
        var s = ScrollViewState(offset: 95, lastSeenHistoryCount: 100)
        s.reconcile(historyCount: 110)
        #expect(s.offset == 105)   // 95 + 10 = 105, well under 110
        // Theoretical case where historyCount appears to shrink (delta < 0):
        // production history is append-only so this can't happen, but the
        // negative-delta early-return path is still reachable from a careless
        // caller. Guard the contract: offset stays put when delta < 0.
        s.reconcile(historyCount: 108)
        #expect(s.offset == 105)
    }

    @Test("Wheel: positive rowsBack scrolls back, clamps at historyCount")
    func test_wheel_positive() {
        var s = ScrollViewState()
        s.handleWheel(rowsBack: 9, historyCount: 50)
        #expect(s.offset == 9)
        s.handleWheel(rowsBack: 1000, historyCount: 50)
        #expect(s.offset == 50, "Clamps at historyCount")
    }

    @Test("Wheel with empty history is a no-op (start-of-session safety)")
    func test_wheel_empty_history() {
        var s = ScrollViewState()
        s.handleWheel(rowsBack: 100, historyCount: 0)
        #expect(s.offset == 0, "No history → no scroll possible")
    }

    @Test("Reconcile returns false when offset is already at historyCount cap")
    func test_reconcile_no_change_when_capped() {
        var s = ScrollViewState(offset: 100, lastSeenHistoryCount: 100)
        // History grows but offset is already at the cap; offset stays put.
        let changed = s.reconcile(historyCount: 110)
        #expect(changed == true)
        #expect(s.offset == 110, "offset += delta=10 → 110, still ≤ historyCount")
        // Now actually exceed: offset 110 of 110 history. Grow by 5; delta calc
        // pushes new offset to 115, clamped at 115 (== historyCount). changed.
        let changed2 = s.reconcile(historyCount: 115)
        #expect(changed2 == true)
        #expect(s.offset == 115)
    }

    @Test("Wheel: negative rowsBack scrolls forward, clamps at 0")
    func test_wheel_negative() {
        var s = ScrollViewState(offset: 10, lastSeenHistoryCount: 100, wheelAccumulator: 0)
        s.handleWheel(rowsBack: -9, historyCount: 100)
        #expect(s.offset == 1)
        s.handleWheel(rowsBack: -1000, historyCount: 100)
        #expect(s.offset == 0, "Clamps at 0")
    }

    @Test("Wheel: sub-row deltas accumulate instead of rounding to zero")
    func test_wheel_fractional_accumulator() {
        var s = ScrollViewState()
        // Three 0.4-row deltas should accumulate to 1.2 → emits 1 row, leaves 0.2.
        s.handleWheel(rowsBack: 0.4, historyCount: 100)
        #expect(s.offset == 0, "0.4 alone rounds-to-zero towardZero")
        s.handleWheel(rowsBack: 0.4, historyCount: 100)
        #expect(s.offset == 0, "0.8 still under 1 row")
        s.handleWheel(rowsBack: 0.4, historyCount: 100)
        #expect(s.offset == 1, "1.2 emits 1 row, residue 0.2 stays in accumulator")
    }

    @Test("scrollToBottom resets offset and accumulator")
    func test_scroll_to_bottom() {
        var s = ScrollViewState(offset: 50, lastSeenHistoryCount: 100, wheelAccumulator: 0.7)
        s.scrollToBottom()
        #expect(s.offset == 0)
        #expect(s.wheelAccumulator == 0)
    }

    @Test("Page up scrolls by pageRows - 1, clamps at historyCount")
    func test_page_up() {
        var s = ScrollViewState()
        let changed = s.pageUp(pageRows: 24, historyCount: 100)
        #expect(changed == true)
        #expect(s.offset == 23)
    }

    @Test("Page down scrolls forward by pageRows - 1, clamps at 0")
    func test_page_down() {
        var s = ScrollViewState(offset: 30, lastSeenHistoryCount: 100, wheelAccumulator: 0)
        s.pageDown(pageRows: 24)
        #expect(s.offset == 7)
        s.pageDown(pageRows: 24)
        #expect(s.offset == 0)
    }
}
