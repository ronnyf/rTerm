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
import Synchronization

/// Inclusive 0-indexed row range that limits where natural scrolls move data.
/// `nil` `scrollRegion` on a `Buffer` means full-screen (default).
private struct ScrollRegion: Sendable, Equatable {
    var top: Int       // 0-indexed inclusive
    var bottom: Int    // 0-indexed inclusive
}

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

    /// Per-buffer mutable grid + cursor state. The active buffer (selected by
    /// ``activeKind``) is the one mutated by event handlers; the inactive one
    /// is preserved in place so alt-screen swap (Phase 2 T4) only flips the
    /// selector.
    private var main: Buffer
    private var alt: Buffer
    private var activeKind: BufferKind = .main

    /// Current SGR pen — stamped onto every cell written via `handlePrintable`.
    /// Mutated by `applySGR`; reset to `.default` on SGR `0`.
    private var pen: CellStyle = .default

    /// Window title set via OSC 0 / OSC 2. `nil` until the shell sets one.
    private var windowTitle: String? = nil

    /// Icon name set via OSC 1. Stored separately from `windowTitle` per xterm
    /// semantics — OSC 0 updates both, OSC 1 updates only `iconName`, OSC 2
    /// updates only `windowTitle`.
    private var iconName: String? = nil

    /// DEC private modes (DECAWM / DECTCEM / DECCKM / bracketed paste).
    /// Persists across buffer swap (T4); set via `handleCSI(.setMode(...))`.
    private var modes: TerminalModes = .default

    /// Monotonic count of `BEL` (0x07) events received. Renderer side (T9)
    /// observes deltas and triggers `NSSound.beep()` on the MainActor.
    private var bellCount: UInt64 = 0

    /// Number of columns.
    public let cols: Int

    /// Number of rows.
    public let rows: Int

    /// Monotonically increasing snapshot version. Bumped on every apply that
    /// mutates grid / cursor / title / other visible state. `UInt64` wrap is
    /// effectively impossible in practice.
    private var version: UInt64 = 0

    /// Inner Sendable box holding the snapshot by reference so the mutex
    /// guards only a pointer swap instead of a full struct copy.
    private final class SnapshotBox: Sendable {
        let snapshot: ScreenSnapshot
        init(_ snapshot: ScreenSnapshot) { self.snapshot = snapshot }
    }

    /// Lock-protected snapshot cache for synchronous renderer access.
    private let _latestSnapshot: Mutex<SnapshotBox>

    private let log = Logger.TermCore.screenModel

    // MARK: - Custom executor

    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        executorQueue.asUnownedSerialExecutor()
    }

    // MARK: - Buffer

    /// Per-buffer mutable state. Both `main` and `alt` are full instances;
    /// `activeKind` selects which one event handlers mutate.
    private struct Buffer: Sendable {
        var grid: ContiguousArray<Cell>
        var cursor: Cursor
        var savedCursor: Cursor?
        var scrollRegion: ScrollRegion?

        init(rows: Int, cols: Int) {
            self.grid = ContiguousArray(repeating: .empty, count: rows * cols)
            self.cursor = Cursor(row: 0, col: 0)
            self.savedCursor = nil
            self.scrollRegion = nil
        }
    }

    // MARK: - Active-buffer access

    /// Yields an inout reference to whichever buffer is currently active.
    /// All event handlers that mutate per-buffer state route through here.
    private func mutateActive<R>(_ body: (inout Buffer) -> R) -> R {
        switch activeKind {
        case .main: return body(&main)
        case .alt:  return body(&alt)
        }
    }

    /// Read-only view of the currently active buffer.
    private var active: Buffer {
        activeKind == .main ? main : alt
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
        let main = Buffer(rows: rows, cols: cols)
        let alt = Buffer(rows: rows, cols: cols)
        self.main = main
        self.alt = alt
        let initial = ScreenSnapshot(
            activeCells: main.grid,
            cols: cols,
            rows: rows,
            cursor: main.cursor,
            cursorVisible: true,
            activeBuffer: .main,
            windowTitle: nil,
            cursorKeyApplication: false,
            bracketedPaste: false,
            bellCount: 0,
            autoWrap: true,
            version: 0
        )
        self._latestSnapshot = Mutex(SnapshotBox(initial))
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
    ///
    /// Each handler returns a `Bool` indicating whether the event produced a
    /// visible state change. `version` is bumped (and a new snapshot published)
    /// only when at least one event in the batch reports `true`.
    public func apply(_ events: [TerminalEvent]) {
        log.debug("Applying \(events.count) events")
        var changed = false
        for event in events {
            switch event {
            case .printable(let c):
                changed = handlePrintable(c) || changed
            case .c0(let control):
                changed = handleC0(control) || changed
            case .csi(let cmd):
                changed = handleCSI(cmd) || changed
            case .osc(let cmd):
                changed = handleOSC(cmd) || changed
            case .unrecognized:
                break
            }
        }
        if changed {
            version &+= 1
            publishSnapshot()
        }
    }

    /// Build a fresh snapshot from the current state and swap it into the
    /// lock-protected cache. Called only when `apply(_:)` reports a real change.
    private func publishSnapshot() {
        let snap = makeSnapshot(from: active)
        _latestSnapshot.withLock { $0 = SnapshotBox(snap) }
    }

    /// Construct a `ScreenSnapshot` from the given buffer plus the current
    /// terminal-wide state (modes, bell count, title, version). Shared between
    /// `publishSnapshot` (the cache update path) and the actor-isolated
    /// `snapshot()` accessor so adding a snapshot field needs only one edit.
    private func makeSnapshot(from buf: Buffer) -> ScreenSnapshot {
        ScreenSnapshot(
            activeCells: buf.grid,
            cols: cols,
            rows: rows,
            cursor: snapshotCursor(from: buf),
            cursorVisible: modes.cursorVisible,
            activeBuffer: activeKind,
            windowTitle: windowTitle,
            cursorKeyApplication: modes.cursorKeyApplication,
            bracketedPaste: modes.bracketedPaste,
            bellCount: bellCount,
            autoWrap: modes.autoWrap,
            version: version
        )
    }

    // MARK: - Event handlers (all return Bool; true = state mutated = version bump)

    private func handlePrintable(_ char: Character) -> Bool {
        let pen = self.pen
        let autoWrap = modes.autoWrap
        return mutateActive { buf in
            if buf.cursor.col >= cols {
                if autoWrap {
                    buf.cursor.col = 0
                    buf.cursor.row += 1
                    if buf.cursor.row >= rows { Self.scrollUp(in: &buf, cols: cols, rows: rows) }
                } else {
                    // DECAWM off: writes overwrite the last column without wrapping.
                    buf.cursor.col = cols - 1
                }
            }
            buf.grid[buf.cursor.row * cols + buf.cursor.col] = Cell(character: char, style: pen)
            // With autoWrap on, advance unconditionally (the deferred-wrap guard
            // at the top of the next call will resolve col == cols).
            // With autoWrap off (DECAWM-off), stop at cols-1 so the cursor never
            // exceeds the grid boundary and subsequent writes keep overwriting that
            // last column — xterm DECAWM-off semantics.
            if autoWrap || buf.cursor.col < cols - 1 {
                buf.cursor.col += 1
            }
            return true
        }
    }

    private func handleC0(_ control: C0Control) -> Bool {
        switch control {
        case .nul, .shiftOut, .shiftIn, .delete:
            return false
        case .bell:
            bellCount &+= 1
            return true   // snapshot includes bellCount; renderer observes delta.
        case .backspace:
            return mutateActive { buf in
                guard buf.cursor.col > 0 else { return false }
                buf.cursor.col -= 1
                return true
            }
        case .horizontalTab:
            return mutateActive { buf in
                let next = min(cols - 1, ((buf.cursor.col / 8) + 1) * 8)
                guard next != buf.cursor.col else { return false }
                buf.cursor.col = next
                return true
            }
        case .lineFeed, .verticalTab, .formFeed:
            return mutateActive { buf in
                buf.cursor.col = 0
                buf.cursor.row += 1
                if buf.cursor.row >= rows { Self.scrollUp(in: &buf, cols: cols, rows: rows) }
                return true
            }
        case .carriageReturn:
            return mutateActive { buf in
                guard buf.cursor.col != 0 else { return false }
                buf.cursor.col = 0
                return true
            }
        }
    }

    private func clampCursor(in buf: inout Buffer) {
        buf.cursor.row = max(0, min(rows - 1, buf.cursor.row))
        buf.cursor.col = max(0, min(cols - 1, buf.cursor.col))
    }

    private func handleCSI(_ cmd: CSICommand) -> Bool {
        switch cmd {
        case .cursorUp(let n):
            return mutateActive { buf in
                buf.cursor.row -= max(1, n)
                clampCursor(in: &buf)
                return true
            }
        case .cursorDown(let n):
            return mutateActive { buf in
                buf.cursor.row += max(1, n)
                clampCursor(in: &buf)
                return true
            }
        case .cursorForward(let n):
            return mutateActive { buf in
                buf.cursor.col += max(1, n)
                clampCursor(in: &buf)
                return true
            }
        case .cursorBack(let n):
            return mutateActive { buf in
                buf.cursor.col -= max(1, n)
                clampCursor(in: &buf)
                return true
            }
        case .cursorPosition(let r, let c):
            return mutateActive { buf in
                buf.cursor.row = r
                buf.cursor.col = c
                clampCursor(in: &buf)
                return true
            }
        case .cursorHorizontalAbsolute(let n):
            // Parser emits VT 1-indexed value; shift to 0-indexed on consume.
            return mutateActive { buf in
                buf.cursor.col = max(0, n - 1)
                clampCursor(in: &buf)
                return true
            }
        case .verticalPositionAbsolute(let n):
            return mutateActive { buf in
                buf.cursor.row = max(0, n - 1)
                clampCursor(in: &buf)
                return true
            }
        case .saveCursor:
            return mutateActive { buf in
                buf.savedCursor = buf.cursor
                return false   // pure cursor state — no visible change.
            }
        case .restoreCursor:
            return mutateActive { buf in
                guard let saved = buf.savedCursor else { return false }
                buf.cursor = saved
                clampCursor(in: &buf)
                return true
            }
        case .eraseInDisplay(let region):
            eraseInDisplay(region)
            return true
        case .eraseInLine(let region):
            eraseInLine(region)
            return true
        case .sgr(let attrs):
            applySGR(attrs)
            return false    // Pen change alone — grid unchanged.
        case .setMode(let mode, let enabled):
            return handleSetMode(mode, enabled: enabled)
        case .setScrollRegion, .unknown:
            return false   // T5 wires .setScrollRegion.
        }
    }

    private func applySGR(_ attrs: [SGRAttribute]) {
        for attr in attrs {
            switch attr {
            case .reset:
                pen = .default
            case .bold:              pen.attributes.insert(.bold)
            case .dim:               pen.attributes.insert(.dim)
            case .italic:            pen.attributes.insert(.italic)
            case .underline:         pen.attributes.insert(.underline)
            case .blink:             pen.attributes.insert(.blink)
            case .reverse:           pen.attributes.insert(.reverse)
            case .strikethrough:     pen.attributes.insert(.strikethrough)
            case .resetIntensity:    pen.attributes.remove(.bold); pen.attributes.remove(.dim)
            case .resetItalic:       pen.attributes.remove(.italic)
            case .resetUnderline:    pen.attributes.remove(.underline)
            case .resetBlink:        pen.attributes.remove(.blink)
            case .resetReverse:      pen.attributes.remove(.reverse)
            case .resetStrikethrough: pen.attributes.remove(.strikethrough)
            case .foreground(let c): pen.foreground = c
            case .background(let c): pen.background = c
            }
        }
    }

    private func handleOSC(_ cmd: OSCCommand) -> Bool {
        switch cmd {
        case .setWindowTitle(let t):
            guard windowTitle != t else { return false }
            windowTitle = t
            return true
        case .setIconName(let t):
            guard iconName != t else { return false }
            iconName = t
            return false   // Icon name is not a user-visible render change in Phase 1.
        case .unknown:
            return false
        }
    }

    private func eraseInDisplay(_ region: EraseRegion) {
        mutateActive { buf in
            let idx = buf.cursor.row * cols + buf.cursor.col
            switch region {
            case .toEnd:
                for i in idx..<(rows * cols) { buf.grid[i] = .empty }
            case .toBegin:
                for i in 0...idx where i < rows * cols { buf.grid[i] = .empty }
            case .all, .scrollback:
                // .scrollback is handled in T6 once history exists; for now treat as .all.
                for i in 0..<(rows * cols) { buf.grid[i] = .empty }
            }
        }
    }

    private func eraseInLine(_ region: EraseRegion) {
        mutateActive { buf in
            let rowStart = buf.cursor.row * cols
            switch region {
            case .toEnd:
                for c in buf.cursor.col..<cols { buf.grid[rowStart + c] = .empty }
            case .toBegin:
                for c in 0...buf.cursor.col where c < cols { buf.grid[rowStart + c] = .empty }
            case .all, .scrollback:
                for c in 0..<cols { buf.grid[rowStart + c] = .empty }
            }
        }
    }

    // MARK: - Restore

    /// Resets the screen model to the state captured in a snapshot.
    ///
    /// This is the inverse of ``snapshot()``: it replaces the grid, cursor,
    /// window title, and version with the values from the given snapshot and
    /// updates the lock-protected cache so ``latestSnapshot()`` reflects the
    /// restored state immediately.
    ///
    /// Use this during session reattach — the daemon sends an
    /// `AttachPayload` and the client calls `restore(from:payload.snapshot)`
    /// to synchronize its local model.
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
        precondition(
            snapshot.activeCells.count == snapshot.rows * snapshot.cols,
            "Snapshot has \(snapshot.activeCells.count) cells; expected \(snapshot.rows * snapshot.cols)"
        )
        // Restore into the buffer indicated by the snapshot. The other buffer is
        // reset to a fresh empty state — when the daemon hasn't recorded alt
        // contents (Phase 2 doesn't carry alt grids over the wire), starting alt
        // from blank is the only safe default.
        var seeded = Buffer(rows: rows, cols: cols)
        seeded.grid = snapshot.activeCells
        seeded.cursor = snapshot.cursor
        switch snapshot.activeBuffer {
        case .main:
            self.main = seeded
            self.alt = Buffer(rows: rows, cols: cols)
        case .alt:
            self.alt = seeded
            self.main = Buffer(rows: rows, cols: cols)
        }
        self.activeKind = snapshot.activeBuffer
        self.windowTitle = snapshot.windowTitle
        self.modes = TerminalModes(
            autoWrap: snapshot.autoWrap,
            cursorVisible: snapshot.cursorVisible,
            cursorKeyApplication: snapshot.cursorKeyApplication,
            bracketedPaste: snapshot.bracketedPaste
        )
        self.bellCount = snapshot.bellCount
        self.version = snapshot.version
        publishSnapshot()
    }

    // MARK: - Snapshot access

    /// Returns a value-type snapshot of the current screen state.
    ///
    /// This is actor-isolated and requires `await`. When a deferred wrap is
    /// pending (`col >= cols`), the snapshot cursor reports the position the
    /// next printable character would land at.
    public func snapshot() -> ScreenSnapshot {
        makeSnapshot(from: active)
    }

    /// Returns the current window title set via OSC 0 / OSC 2, or `nil` if the
    /// shell hasn't set one. Actor-isolated — callers `await`.
    public func currentWindowTitle() -> String? { windowTitle }

    /// Returns the current icon name set via OSC 1, or `nil` if unset.
    /// Actor-isolated — callers `await`.
    public func currentIconName() -> String? { iconName }

    /// Convenience combining ``apply(_:)`` and ``currentWindowTitle()`` in a
    /// single actor hop.
    ///
    /// `TerminalSession` uses this from the XPC response handler so that the
    /// title it reads corresponds to the state immediately after *this* chunk's
    /// apply — not whatever state the actor holds by the time a separate
    /// `currentWindowTitle()` round-trip returns. Without this collapsing, two
    /// rapid output chunks could have their MainActor continuations reorder
    /// the title reads and produce stale-title flicker.
    public func applyAndCurrentTitle(_ events: [TerminalEvent]) -> String? {
        apply(events)
        return windowTitle
    }

    /// Returns the most recently published snapshot.
    ///
    /// This is `nonisolated` and safe to call from any thread (including the
    /// render thread) without `await`. The snapshot is updated atomically after
    /// every ``apply(_:)`` call that reports a state change.
    nonisolated public func latestSnapshot() -> ScreenSnapshot {
        _latestSnapshot.withLock { $0.snapshot }
    }

    /// Build an `AttachPayload` from the currently-published snapshot.
    ///
    /// `nonisolated` so the daemon's attach path (running on the same daemon
    /// queue that backs the actor executor) can call this without an async
    /// hop. In Phase 1 `recentHistory` is always empty — the payload shape
    /// exists so Phase 2 can add history without a protocol break.
    nonisolated public func buildAttachPayload() -> AttachPayload {
        let snap = _latestSnapshot.withLock { $0.snapshot }
        return AttachPayload(snapshot: snap, recentHistory: [], historyCapacity: 0)
    }

    // MARK: - Private helpers

    /// Compute the cursor position for a snapshot. When a deferred wrap is
    /// pending (`col >= cols`), the returned cursor is at the start of the
    /// next row (or the last row if a scroll would occur).
    private func snapshotCursor(from buf: Buffer) -> Cursor {
        let c = buf.cursor
        guard c.col >= cols else { return c }
        let nextRow = c.row + 1
        if nextRow >= rows { return Cursor(row: rows - 1, col: 0) }
        return Cursor(row: nextRow, col: 0)
    }

    /// Shifts all rows in `buf` up by one, discarding the top row and clearing the
    /// last row. Cursor row clamped to `rows - 1`. Static so handlers can call it
    /// inside a `mutateActive` closure without re-entering the helper.
    ///
    /// T6 will add a history-feed path: when `buf` is the main buffer, the evicted
    /// row gets pushed to scrollback. For T2 we just discard, matching Phase 1.
    private static func scrollUp(in buf: inout Buffer, cols: Int, rows: Int) {
        for dstRow in 0 ..< (rows - 1) {
            let srcStart = (dstRow + 1) * cols
            let dstStart = dstRow * cols
            for col in 0 ..< cols {
                buf.grid[dstStart + col] = buf.grid[srcStart + col]
            }
        }
        let lastRowStart = (rows - 1) * cols
        for col in 0 ..< cols {
            buf.grid[lastRowStart + col] = .empty
        }
        buf.cursor.row = rows - 1
    }

    /// Apply a `CSI ? Pm h/l` mode change. Returns `true` when the change
    /// produces a state mutation that should be reflected in a new snapshot
    /// (all four wired user modes — DECAWM, DECTCEM, DECCKM, bracketed paste —
    /// each surface as a snapshot field). Returns `false` for idempotent
    /// no-ops, alt-screen modes (T4), and unknown modes.
    private func handleSetMode(_ mode: DECPrivateMode, enabled: Bool) -> Bool {
        switch mode {
        case .autoWrap:
            guard modes.autoWrap != enabled else { return false }
            modes.autoWrap = enabled
            return true
        case .cursorVisible:
            guard modes.cursorVisible != enabled else { return false }
            modes.cursorVisible = enabled
            return true
        case .cursorKeyApplication:
            guard modes.cursorKeyApplication != enabled else { return false }
            modes.cursorKeyApplication = enabled
            return true
        case .bracketedPaste:
            guard modes.bracketedPaste != enabled else { return false }
            modes.bracketedPaste = enabled
            return true
        case .alternateScreen47, .alternateScreen1047,
             .alternateScreen1049, .saveCursor1048:
            // T4 wires these.
            return false
        case .unknown:
            return false
        }
    }
}
