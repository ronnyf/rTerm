//
//  ScrollViewState.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation

/// Value type holding the renderer's scrollback view state. Pure logic;
/// testable without Metal or AppKit.
///
/// `offset` counts rows scrolled back from the bottom of the live grid.
/// `offset == 0` means the user is viewing live output; `offset > 0` means
/// the user has scrolled into history.
///
/// `lastSeenHistoryCount` is what `historyCount` was the last time the
/// renderer drew. When `historyCount` grows by `delta` while `offset > 0`,
/// the renderer increments `offset` by `delta` (clamped) so the same row
/// content stays at the same screen position — the "anchor" behavior.
///
/// `wheelAccumulator` holds the fractional row delta from sub-row trackpad
/// gestures so small precise scrolls don't all round to zero. Trackpads
/// emit dozens of tiny deltas per gesture; without accumulation each one
/// rounds to 0 and the view feels stuck.
nonisolated struct ScrollViewState: Sendable, Equatable {

    var offset: Int = 0
    var lastSeenHistoryCount: Int = 0
    var wheelAccumulator: CGFloat = 0

    /// Reconcile against a fresh history count. Returns `true` if `offset`
    /// changed (renderer should treat the frame as needing redraw).
    @discardableResult
    mutating func reconcile(historyCount: Int) -> Bool {
        guard offset > 0 else {
            lastSeenHistoryCount = historyCount
            return false
        }
        let delta = historyCount - lastSeenHistoryCount
        lastSeenHistoryCount = historyCount
        guard delta > 0 else { return false }
        let newOffset = min(historyCount, offset + delta)
        let changed = newOffset != offset
        offset = newOffset
        return changed
    }

    /// Apply a wheel delta. Caller passes a "scroll-back-positive" delta —
    /// `TermView.scrollWheel(with:)` is responsible for normalizing AppKit's
    /// raw `event.scrollingDeltaY` (which depends on natural-scroll setting)
    /// into this convention before calling here.
    ///
    /// `historyCount` is the upper bound; `rowsPerNotch` controls scroll speed.
    /// Sub-row deltas accumulate in `wheelAccumulator` so trackpad small
    /// gestures move the view smoothly instead of feeling sticky.
    mutating func handleWheel(rowsBack: CGFloat, historyCount: Int) {
        wheelAccumulator += rowsBack
        let rowDelta = Int(wheelAccumulator.rounded(.towardZero))
        wheelAccumulator -= CGFloat(rowDelta)
        guard rowDelta != 0 else { return }
        offset = max(0, min(historyCount, offset + rowDelta))
    }

    /// Page Up: scroll back by `pageRows - 1` rows. Returns whether offset changed.
    /// The `-1` preserves one row of context across the page jump, matching
    /// xterm/iTerm2 convention so users don't lose their place.
    @discardableResult
    mutating func pageUp(pageRows: Int, historyCount: Int) -> Bool {
        let target = min(historyCount, offset + max(1, pageRows - 1))
        let changed = target != offset
        offset = target
        return changed
    }

    /// Page Down: scroll forward by `pageRows - 1` rows. Returns whether offset changed.
    /// Mirrors `pageUp`'s one-row-of-context convention.
    @discardableResult
    mutating func pageDown(pageRows: Int) -> Bool {
        let target = max(0, offset - max(1, pageRows - 1))
        let changed = target != offset
        offset = target
        return changed
    }

    /// Force scroll-to-bottom (e.g., user typed input). Resets the accumulator
    /// so a subsequent gesture starts fresh.
    mutating func scrollToBottom() {
        offset = 0
        wheelAccumulator = 0
    }
}
