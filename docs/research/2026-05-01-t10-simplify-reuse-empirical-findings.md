# T10 Simplify/Reuse — Empirical Findings

Date: 2026-05-01
Commit: 10923bc ("ui: scrollback view (wheel + PgUp/PgDn + auto-anchor) (Phase 2 T10)")
Reviewer: Claude Sonnet 4.6

---

## Q1: Should the 4 view-callback closures (onScrollWheel/onPageUp/onPageDown/onActiveInput) be unified into a "view bindings" struct alongside cursorKeyModeProvider/onPaste?

**Finding: Not a clean unification candidate. The two groups serve different wiring patterns and sit in different code paths.**

The current closure inventory on `TerminalMTKView` (`TermView.swift:37-58`):

| Property | Type | Wired in | Updated in |
|----------|------|----------|------------|
| `onKeyInput` | `((Data) -> Void)?` | `makeNSView` | `updateNSView` |
| `onPaste` | `((String) -> Void)?` | `makeNSView` | `updateNSView` |
| `cursorKeyModeProvider` | `(() -> CursorKeyMode)?` | `makeNSView` | `updateNSView` |
| `onScrollWheel` | `((CGFloat) -> Void)?` | `makeNSView` | — |
| `onPageUp` | `(() -> Bool)?` | `makeNSView` | — |
| `onPageDown` | `(() -> Bool)?` | `makeNSView` | — |
| `onActiveInput` | `(() -> Void)?` | `makeNSView` | — |

There are two structural groups:

**Group A — make + update:** `onKeyInput`, `onPaste`, `cursorKeyModeProvider`. These three are set in both `makeNSView` and `updateNSView` because they capture values that can change when the SwiftUI struct is reconstructed (e.g. a new `onInput` closure from `ContentView`). `updateNSView` currently re-sets all three (`TermView.swift:180-185`).

**Group B — make only:** `onScrollWheel`, `onPageUp`, `onPageDown`, `onActiveInput`. These four capture `[weak view, weak coordinator]` references that are stable for the lifetime of the view. They do not need to be re-set in `updateNSView` because the captured targets are identity-stable Metal/coordinator objects, not SwiftUI-derived values. Accordingly none of them appears in `updateNSView`.

A "view bindings" struct would need to hold either both groups or force callers to split them anyway. Since the groups have different update semantics, a single struct would obscure the distinction rather than clarify it. The `makeCursorKeyModeProvider()` comment at `TermView.swift:187-196` already documents the reason for the current grouping explicitly: "Centralising the closure here keeps `makeNSView` and `updateNSView` in lockstep."

If the Group A closures were extracted into a `TermViewBindings` struct, that struct would need to be passed to both `makeNSView` and `updateNSView`, and `updateNSView` would still need to apply all three properties individually — no actual call-site reduction. Group B closures don't belong there.

**Verdict: The grouping is correct as-is. No unification opportunity.**

---

## Q2: Does the `cellAt(row:col:)` nested function in draw(in:) duplicate `ScreenSnapshot.subscript(_:_:)`?

**Finding: Partial duplication on the live-grid path; the history path is new logic with no equivalent.**

`ScreenSnapshot.subscript(_:_:)` is defined at `ScreenSnapshot.swift:95-97`:

```swift
public subscript(row: Int, col: Int) -> Cell {
    activeCells[row * cols + col]
}
```

The `cellAt` nested function in `RenderCoordinator.draw(in:)` (`RenderCoordinator.swift:197-207`):

```swift
@inline(__always) func cellAt(row: Int, col: Int) -> Cell {
    if row < scrollOffset {
        let historyRowIdx = historyStart + row
        let historyRow = history[historyRowIdx]
        guard col < historyRow.count else { return .empty }
        return historyRow[col]
    } else {
        let liveRow = row - scrollOffset
        return liveCells[liveRow * cols + col]
    }
}
```

The live-grid branch (`liveRow * cols + col` into `liveCells`) is structurally identical to `ScreenSnapshot.subscript` but operates on a pre-extracted `ContiguousArray<Cell>` local (`liveCells = snapshot.activeCells`) rather than going through the snapshot's subscript. The direct array access is intentional: `cellAt` needs `liveRow = row - scrollOffset`, not `row`, so calling `snapshot[row, col]` would give the wrong cell when `scrollOffset > 0`. Even if `scrollOffset == 0` the call would be `snapshot[row, col]` — identical arithmetic to `liveCells[row * cols + col]` — but there would be no saving from routing through the subscript.

The history branch has no analogue in `ScreenSnapshot`. `ScrollbackHistory.Row` is `ContiguousArray<Cell>` (a row of cells), not a flat grid, so there is no shared 2D subscript. The `guard col < historyRow.count` bounds check is necessary because history rows may be narrower than the current terminal width (captured when they were scrolled off).

**Verdict: The `cellAt` live-grid path is a trivial reimplementation of `snapshot[row, col]` arithmetic, but offset-adjusted in a way that makes delegation back to the subscript awkward. The history path is novel. No extraction opportunity; the nested function is the right shape for this use.**

---

## Q3: Does `latestHistoryTail()` return type allow direct subscript (`history[i]`), or does it wrap?

**Finding: Direct subscript is valid. The return type is `ContiguousArray<ScrollbackHistory.Row>` which is `ContiguousArray<ContiguousArray<Cell>>`. Both levels support standard integer subscript.**

`latestHistoryTail()` is declared at `ScreenModel.swift:691`:

```swift
nonisolated public func latestHistoryTail() -> ContiguousArray<ScrollbackHistory.Row>
```

`ScrollbackHistory.Row` is a typealias defined at `ScrollbackHistory.swift:33`:

```swift
public typealias Row = ContiguousArray<Cell>
```

So the return type expands to `ContiguousArray<ContiguousArray<Cell>>`.

`ContiguousArray` conforms to `RandomAccessCollection` with `Int` indices, so:
- `history[i]` — valid, returns a `ContiguousArray<Cell>` (one row)
- `history[i][j]` — valid, returns a `Cell`

In `RenderCoordinator.draw(in:)` the renderer uses exactly this pattern:

```swift
let history = screenModel.latestHistoryTail()
// ...
let historyRow = history[historyRowIdx]      // history[i] → ContiguousArray<Cell>
guard col < historyRow.count else { return .empty }
return historyRow[col]                        // historyRow[j] → Cell
```

No wrapper type is interposed. `history[i]` is a direct `ContiguousArray` subscript. The bounds check (`col < historyRow.count`) is required because history rows can have fewer columns than the current grid width.

**Verdict: Clean direct subscript at both levels. No unwrapping or accessor indirection needed.**

---

## Summary

| Question | Finding |
|----------|---------|
| Closure unification into a bindings struct | Not warranted. The 4 scroll closures (make-only, stable captures) and the 3 existing closures (make + update, SwiftUI-value-derived) have different update semantics. A struct would conflate them. Current grouping is correct. |
| `cellAt` vs `ScreenSnapshot.subscript` duplication | Partial overlap on the live-grid arithmetic, but offset-adjustment makes delegation to the subscript awkward rather than cleaner. History path is entirely novel. No extraction opportunity. |
| `latestHistoryTail()` return type subscriptability | `ContiguousArray<ContiguousArray<Cell>>` — direct `history[i]` and `historyRow[j]` subscripts work without any wrapping. The renderer uses them correctly. |
