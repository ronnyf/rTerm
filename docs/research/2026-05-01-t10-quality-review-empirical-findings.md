# T10 Quality Review — Empirical Findings

Commit: `6290934` — "ui: scrollback view (wheel + PgUp/PgDn + auto-anchor) (Phase 2 T10)"
Review date: 2026-05-01

## Files examined

- `rTerm/ScrollViewState.swift` (new)
- `rTerm/RenderCoordinator.swift` (modified)
- `rTerm/TermView.swift` (modified)
- `rTermTests/ScrollViewStateTests.swift` (new)
- `rTerm/KeyEncoder.swift` (read-only, for keyCode cross-check)
- `TermCore/ScreenSnapshot.swift` (read-only, for type shapes)
- `TermCore/ScrollbackHistory.swift` (read-only, for Row typedef)
- `TermCore/Cell.swift` (read-only, for Cell.empty)

---

## Concurrency model

**`ScrollViewState` isolation.**
`nonisolated struct ScrollViewState: Sendable, Equatable` — same pattern as T8/T9
value types (e.g. `ScreenSnapshot`). Confirmed correct. All mutations happen inside
`@MainActor` methods on `RenderCoordinator` (`handleScrollWheel`, `handlePageUp`,
`handlePageDown`, `scrollToBottom`, `draw(in:)`). No cross-isolation boundary crossing.

**Closure capture lists.**
`onScrollWheel`, `onPageUp`, `onPageDown` capture `[weak view, weak coordinator]`.
`onActiveInput` captures `[weak coordinator]` only — `view` is not used inside the
body, so the omission is correct, not an oversight.
`RenderCoordinator` is `@MainActor final class`; the closures are set from `makeNSView`
which also runs on MainActor. No actor-crossing.

**`screenModelForView` accessor.**
`var screenModelForView: ScreenModel { screenModel }` — `screenModel` is `private`,
so the closures in `TermView.makeNSView` cannot reach it directly. The forwarder is
the minimal viable solution. Confirmed.

**`draw(in:)` calls `latestHistoryTail()` and `latestSnapshot()` — both `nonisolated`,
lock-protected.** No actor hop needed. Consistent with prior renderer pattern.

---

## `reconcile(historyCount:)` dual responsibility

The method both mutates `offset` AND returns a `Bool` indicating whether the offset
changed. The doc-comment and the `@discardableResult` annotation together make the
dual purpose clear. The `Bool` return is used by exactly zero callers (draw path uses
`@discardableResult`). This is an opportunity for simplification noted below.

---

## `handleWheel` rounding direction

`Int(wheelAccumulator.rounded(.towardZero))` truncates toward zero for both signs:
- Positive delta (scroll back): 0.8 → 0, 1.2 → 1. Correct.
- Negative delta (scroll forward): -0.8 → 0, -1.2 → -1. Correct.

`test_wheel_fractional_accumulator` confirms three 0.4-unit pushes accumulate to
1.2 → emit 1, residue 0.2. Verified mathematically: 0.4+0.4+0.4 = 1.2,
`Int(1.2.rounded(.towardZero))` = 1. Correct.

`test_wheel_negative` starts at `offset: 10`, applies `-9` → `offset = 1`. Verified:
accumulator starts 0, +(-9) = -9, `Int((-9.0).rounded(.towardZero))` = -9,
residue = 0, `offset = max(0, min(100, 10 + (-9))) = 1`. Correct.

**Asymmetry edge case** (not tested): what happens when the user scrolls forward past
offset=0 with residual negative accumulator? e.g. offset=0, accumulator=-0.3,
new rowsBack=-0.8 → accumulator=-1.1 → rowDelta=-1 → offset = max(0, min(h, 0-1)) = 0.
The negative clamp is correct, but `accumulator` is now -0.1 (negative while offset==0).
On next forward scroll, the -0.1 residual will carry forward. This is harmless but subtle.
No test covers "accumulator has negative residue while at bottom."

---

## `pageUp / pageDown` `pageRows - 1` heuristic

`pageUp(pageRows: 24)` → moves `max(1, 24-1)` = 23 rows. xterm convention:
page moves preserve one line of context. Comment at call site says nothing; doc-comment
on the method explains only the parameter semantics. The `-1` is not annotated with
the xterm convention rationale. Minor.

---

## `keyDown` intercept: keyCode 116/121

Cross-referenced with `KeyEncoder.swift` lines 82–83:
```
case 116: return Data([0x1B, 0x5B, 0x35, 0x7E])  // PgUp → ESC [ 5 ~
case 121: return Data([0x1B, 0x5B, 0x36, 0x7E])  // PgDn → ESC [ 6 ~
```
The `keyDown` intercept fires `onPageUp`/`onPageDown` first; when the hook returns
`true` (consumed by scrollback), we `return` before reaching `KeyEncoder.encode`.
When the hook returns `false`, the encoder runs normally and emits the VT sequence.
No double-send. Logic is clean.

---

## `cellAt(row:col:)` — history row bounds check

```swift
let historyRow = history[historyRowIdx]
guard col < historyRow.count else { return .empty }
return historyRow[col]
```
`history[historyRowIdx]` is `ContiguousArray<Cell>`. `historyRow.count` can be < `cols`
if the row was shorter than the terminal width when it was evicted (e.g. the user
resized the window). The bounds check is therefore correct and necessary.
`liveCells[liveRow * cols + col]` has no bounds check — but `activeCells` is always
exactly `rows * cols` (guaranteed by `ScreenModel` invariant). Safe.

`scrollOffset = min(scrollState.offset, history.count)` — caps scrollOffset at the
actual history length before the inner closure is defined. `historyStart = history.count - scrollOffset`
is therefore always >= 0. No underflow.

---

## `updateNSView` drift

`updateNSView(_:context:)` (TermView.swift line 180–185) re-wires only:
- `onKeyInput`
- `onPaste`
- `clearColor`
- `cursorKeyModeProvider`

The four scroll closures (`onScrollWheel`, `onPageUp`, `onPageDown`, `onActiveInput`)
are NOT re-wired. The closures close over `coordinator` (the SwiftUI-managed
`Coordinator` object, which is stable for the lifetime of the view). Because the
closures hold only a `weak` reference to the coordinator, and the coordinator does not
change across `updateNSView` calls, there is no drift risk. The implementer's stated
rationale is sound.

---

## `reconcile` return value usage

`scrollState.reconcile(historyCount: history.count)` — the `Bool` return is
dropped in `draw(in:)`. The `@discardableResult` suppresses the warning. The Bool is
potentially useful for a future "only re-encode vertices when view actually changed"
optimization (frame skip). Currently unused at any call site.

---

## `screenModelForView` necessity

`screenModel` is declared `private let screenModel: ScreenModel` on line 46.
The closures in `TermView.makeNSView` capture `coordinator` (not `TermView`), so they
need to read `coordinator.screenModel` — but that's private. The public forwarder
`screenModelForView` is the minimally-invasive solution. Confirmed necessary.

---

## Test coverage gaps

Covered: default state, reconcile at bottom, reconcile anchor, reconcile clamp,
wheel positive/negative/fractional, scrollToBottom, pageUp, pageDown.

NOT covered:
1. Negative accumulator residue at offset==0 (noted above — harmless but subtle).
2. `reconcile` when `historyCount` shrinks (delta < 0): test_reconcile_clamp line 46
   asserts `offset == 105` after `reconcile(historyCount: 108)`. Comment says
   "shrunk? edge case — delta is -2; offset unchanged." BUT offset=105 > historyCount=108
   is a reachable violation — `offset` is now 105 with only 108 rows of actual history,
   which is fine because the renderer clamps via `scrollOffset = min(scrollState.offset, history.count)`.
   However, the test comment is misleading: it says "delta is -2; offset unchanged"
   but actually 105 <= 108, so no clamp fires. The comment should say "no clamp needed
   because 105 <= 108." This is a documentation defect, not a logic defect.
3. `pageDown` with `pageRows == 1` — `max(1, 1-1) = max(1, 0) = 1` → moves 1 row.
   The `max(1, pageRows-1)` guard is tested implicitly but not explicitly.
4. No test exercises `reconcile` returning `true` when `offset` actually remains
   unchanged after clamping (i.e. `newOffset == offset` after the `min`). The path
   `changed = (newOffset != offset)` / `return changed` where changed==false and
   delta>0 is not hit by any test. Reachable when `offset` is already at `historyCount`.

---

## `nonisolated` on struct declaration

`nonisolated struct ScrollViewState` — `nonisolated` on a struct declaration is
unusual Swift. The keyword suppresses implicit global-actor inference that would
otherwise apply in a file where the module default is `@MainActor` (rTerm target sets
`SWIFT_APPROACHABLE_CONCURRENCY = YES` which enables default MainActor isolation in
Swift 6.2+). Without `nonisolated`, the struct would be inferred as `@MainActor` and
could not be used in non-MainActor contexts (e.g. pure unit tests running without an
actor). The usage is correct and matches the T8/T9 pattern (`ScreenSnapshot` is also
`nonisolated(unsafe)` — actually checked: `ScreenSnapshot` is in TermCore which does
not have the default isolation setting, so it doesn't need the keyword). This is the
first rTerm-target value type to use `nonisolated` struct. Correct.

---

## Raw keyCode magic numbers

`keyDown` switch uses `116` and `121` as bare integer literals with no symbolic names
and no inline comment identifying them as `kVK_PageUp` / `kVK_PageDown`. KeyEncoder
uses the same pattern, so this is consistent with project convention. The lack of
`Carbon.HIToolbox.Events` import (or `kVK_*` constants) is a project-wide choice,
not a T10-specific defect.

---

## `rowsPerUnit` scaling factor

`let rowsPerUnit: CGFloat = event.hasPreciseScrollingDeltas ? 0.05 : 1.0`

At `0.05` each precise delta, a 20-unit precise gesture = 1 row. The comment says
"Trackpad emits precise sub-point deltas (typically ~1-3 per gesture step)." AppKit's
trackpad typically emits deltas of 1-4 points per `scrollWheel` call during a swipe,
so 20 calls × 0.05 = 1 row per ~5 calls. Scroll speed will feel slow for fast swipes
(many frames) but will feel very precise for careful scrolling. This is a tuning
constant, not a correctness defect, but no comment explains the reasoning for 0.05.
There is no test for the scaling factor.
