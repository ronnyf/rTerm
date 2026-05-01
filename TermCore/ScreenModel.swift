//
//  ScreenModel.swift
//  TermCore
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

import Dispatch
import os

/// The terminal screen model: owns a grid of cells, processes terminal events,
/// and publishes snapshots for the renderer.
///
/// `ScreenModel` is an actor so all grid mutations are serialized. For the
/// renderer thread (which cannot `await`), call ``latestSnapshot()`` -- a
/// `nonisolated` method that reads from a lock-protected cache updated after
/// every `apply(_:)`.
///
/// ## Custom Executor
///
/// By default the actor runs on a private serial dispatch queue. Callers may
/// pass an existing `DispatchQueue` at init time to pin the actor to that
/// queue. This allows the daemon to call `assumeIsolated` from the daemon
/// queue without an async hop, while app-side and test code continue to use
/// normal `await`-based access.
public actor ScreenModel {

    /// Serial dispatch queue that backs the actor's executor.
    ///
    /// When a caller provides a queue at init, the actor runs on that queue
    /// and `assumeIsolated` is legal from its dispatch context. When no queue
    /// is provided, a private serial queue is created automatically.
    private let executorQueue: DispatchSerialQueue

    /// Flat row-major grid storage: `grid[row * cols + col]`.
    private var grid: ContiguousArray<Cell>

    /// Current write position.
    private var cursor: Cursor

    /// Number of columns.
    public let cols: Int

    /// Number of rows.
    public let rows: Int

    /// Lock-protected snapshot cache for synchronous renderer access.
    private let _latestSnapshot: OSAllocatedUnfairLock<ScreenSnapshot>

    private let log = Logger.TermCore.screenModel

    // MARK: - Custom executor

    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    // MARK: - Initialization

    /// Creates a screen model with the given dimensions.
    ///
    /// - Parameters:
    ///   - cols: Number of columns (default 80).
    ///   - rows: Number of rows (default 24).
    ///   - queue: Optional serial dispatch queue to use as the actor's
    ///     executor. When `nil`, a private serial queue is created. Pass the
    ///     daemon queue here to enable synchronous `assumeIsolated` access
    ///     from the daemon's dispatch context.
    public init(cols: Int = 80, rows: Int = 24, queue: DispatchQueue? = nil) {
        let q = queue ?? DispatchQueue(label: "com.ronnyf.TermCore.ScreenModel")
        // swiftlint:disable:next force_cast
        self.executorQueue = q as! DispatchSerialQueue
        self.cols = cols
        self.rows = rows
        let cursor = Cursor(row: 0, col: 0)
        self.cursor = cursor
        let grid = ContiguousArray(repeating: Cell.empty, count: rows * cols)
        self.grid = grid
        self._latestSnapshot = OSAllocatedUnfairLock(
            initialState: ScreenSnapshot(
                cells: grid,
                cols: cols,
                rows: rows,
                cursor: cursor
            )
        )
    }

    // MARK: - Event processing

    /// Apply a batch of terminal events to the screen model.
    ///
    /// After processing, the lock-protected snapshot cache is updated so the
    /// renderer can read it without awaiting.
    ///
    /// Line wrapping is deferred: when a printable character is written at the
    /// last column, the cursor advances past the grid edge (`col == cols`) but
    /// the row does not change. The wrap executes on the next printable
    /// character, keeping newline and carriage-return from double-advancing.
    public func apply(_ events: [TerminalEvent]) {
        log.debug("Applying \(events.count) events")
        for event in events {
            switch event {
            case .printable(let c):
                handlePrintable(c)
            case .c0(let control):
                handleC0(control)
            case .csi:
                break   // CSI handling lands in Task 4
            case .osc:
                break   // OSC handling lands in Task 6
            case .unrecognized:
                break
            }
        }

        // Publish updated snapshot for the renderer.
        let snap = ScreenSnapshot(cells: grid, cols: cols, rows: rows, cursor: snapshotCursor())
        _latestSnapshot.withLock { $0 = snap }
    }

    // MARK: - Event handlers

    private func handlePrintable(_ char: Character) {
        if cursor.col >= cols {
            cursor.col = 0
            cursor.row += 1
            if cursor.row >= rows { scrollUp() }
        }
        grid[cursor.row * cols + cursor.col] = Cell(character: char)
        cursor.col += 1
    }

    private func handleC0(_ control: C0Control) {
        switch control {
        case .nul, .bell, .shiftOut, .shiftIn, .delete:
            break
        case .backspace:
            cursor.col = max(0, cursor.col - 1)
        case .horizontalTab:
            cursor.col = min(cols - 1, ((cursor.col / 8) + 1) * 8)
        case .lineFeed, .verticalTab, .formFeed:
            cursor.col = 0
            cursor.row += 1
            if cursor.row >= rows { scrollUp() }
        case .carriageReturn:
            cursor.col = 0
        }
    }

    // MARK: - Restore

    /// Resets the screen model to the state captured in a snapshot.
    ///
    /// This is the inverse of ``snapshot()``: it replaces the grid and cursor
    /// with the values from the given snapshot and updates the lock-protected
    /// cache so ``latestSnapshot()`` reflects the restored state immediately.
    ///
    /// Use this during session reattach — the daemon sends a `ScreenSnapshot`
    /// and the client calls `restore(from:)` to synchronize its local model.
    ///
    /// - Precondition: `snapshot.cols == cols && snapshot.rows == rows`.
    ///   Restoring from a snapshot with different dimensions is a programming
    ///   error (resize the model first if dimensions changed).
    public func restore(from snapshot: ScreenSnapshot) {
        precondition(
            snapshot.cols == cols && snapshot.rows == rows,
            "Cannot restore from snapshot with dimensions \(snapshot.cols)x\(snapshot.rows) "
            + "into model with dimensions \(cols)x\(rows)"
        )
        grid = snapshot.cells
        cursor = snapshot.cursor
        _latestSnapshot.withLock { $0 = snapshot }
    }

    // MARK: - Snapshot access

    /// Returns a value-type snapshot of the current screen state.
    ///
    /// This is actor-isolated and requires `await`. When a deferred wrap is
    /// pending (`col >= cols`), the snapshot cursor reports the position the
    /// next printable character would land at.
    public func snapshot() -> ScreenSnapshot {
        ScreenSnapshot(cells: grid, cols: cols, rows: rows, cursor: snapshotCursor())
    }

    /// Returns the most recently published snapshot.
    ///
    /// This is `nonisolated` and safe to call from any thread (including the
    /// render thread) without `await`. The snapshot is updated atomically after
    /// every ``apply(_:)`` call.
    nonisolated public func latestSnapshot() -> ScreenSnapshot {
        _latestSnapshot.withLock { $0 }
    }

    // MARK: - Private helpers

    /// Compute the cursor position for a snapshot. When a deferred wrap is
    /// pending (`col >= cols`), the returned cursor is at the start of the
    /// next row (or the last row if a scroll would occur).
    private func snapshotCursor() -> Cursor {
        guard cursor.col >= cols else { return cursor }
        let nextRow = cursor.row + 1
        if nextRow >= rows {
            return Cursor(row: rows - 1, col: 0)
        }
        return Cursor(row: nextRow, col: 0)
    }

    /// Shift all rows up by one, discarding row 0 and filling the last row
    /// with empty cells. Cursor row is clamped to `rows - 1`.
    private func scrollUp() {
        // Move rows 1..<rows into 0..<rows-1 in the flat array.
        let stride = cols
        for dstRow in 0 ..< (rows - 1) {
            let srcStart = (dstRow + 1) * stride
            let dstStart = dstRow * stride
            for col in 0 ..< stride {
                grid[dstStart + col] = grid[srcStart + col]
            }
        }
        // Clear the last row.
        let lastRowStart = (rows - 1) * stride
        for col in 0 ..< stride {
            grid[lastRowStart + col] = Cell.empty
        }
        cursor.row = rows - 1
    }
}
