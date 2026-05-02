# T10 Spec Review — Empirical Findings

**Commit:** `6290934` ("ui: scrollback view (wheel + PgUp/PgDn + auto-anchor) (Phase 2 T10)")
**Reviewer:** Claude Code (spec-review pass)
**Date:** 2026-05-01

---

## Commit Scope

Files changed per `git show 6290934 --stat`:

| File | Change |
|---|---|
| `rTerm.xcodeproj/project.pbxproj` | +12/-4 (ScrollViewState.swift + ScrollViewStateTests.swift registration; BracketedPasteTests entries moved — net zero for T8's file) |
| `rTerm/RenderCoordinator.swift` | +70/-1 |
| `rTerm/ScrollViewState.swift` | +90 (new) |
| `rTerm/TermView.swift` | +64 |
| `rTermTests/ScrollViewStateTests.swift` | +104 (new) |

All five entries are within the plan's allowed set (`rTerm/ScrollViewState.swift`, `rTermTests/ScrollViewStateTests.swift`, `rTerm/RenderCoordinator.swift`, `rTerm/TermView.swift`, `rTerm.xcodeproj/project.pbxproj`). No extra source files were added or modified.

The xcodeproj also shows `BracketedPasteTests.swift` entries appearing in the diff — these are a Xcode project file re-serialisation artefact. `BracketedPasteTests` was properly registered in the T8 commit (`0dc9586`) and remains correctly registered in HEAD. Net effect on that file: zero.

---

## ScrollViewState.swift

**Location:** `/Users/ronny/rdev/rTerm/rTerm/ScrollViewState.swift`

### Deviation: `nonisolated struct`

The plan spec (line 3780) declares:

```swift
struct ScrollViewState: Sendable, Equatable {
```

The implementation declares:

```swift
nonisolated struct ScrollViewState: Sendable, Equatable {
```

`nonisolated` on a struct type declaration is a Swift 6 / Swift 5.10 feature that exempts the type from global-actor inference. Since `rTerm` uses `@MainActor` as its default isolation (per `SWIFT_APPROACHABLE_CONCURRENCY = YES` / rTerm app target default), the annotation prevents `ScrollViewState` from being inferred as `@MainActor`-isolated. This is intentional and correct: the value type is `Sendable` and should be freely usable from any context. The annotation is a defensive addition not in the plan spec but is a beneficial deviation.

### All other properties and methods: exact match

- `var offset: Int = 0` — matches.
- `var lastSeenHistoryCount: Int = 0` — matches.
- `var wheelAccumulator: CGFloat = 0` — matches.
- `reconcile(historyCount:) -> Bool` — logic is byte-for-byte identical to the plan code block (lines 3789–3801).
- `handleWheel(rowsBack:historyCount:)` — identical to plan (lines 3811–3817).
- `pageUp(pageRows:historyCount:) -> Bool` — identical to plan (lines 3821–3826).
- `pageDown(pageRows:) -> Bool` — identical to plan (lines 3830–3835).
- `scrollToBottom()` — identical to plan (lines 3839–3842).
- `@discardableResult` on `reconcile`, `pageUp`, `pageDown` — all present.
- `import Foundation` — present.
- GPLv3 header — present.

---

## ScrollViewStateTests.swift

**Location:** `/Users/ronny/rdev/rTerm/rTermTests/ScrollViewStateTests.swift`

### Test count: 10 (plan says 9)

The plan Step 3 comment states "Expected: 9 tests pass." The implementation contains 10 `@Test` annotations. The extra test is `test_reconcile_clamp`, which appears in the plan's Step 2 code block (lines 3892–3898) as a fourth test case. The plan's Step 3 expected count of "9" is a documentation error — the code block in Step 2 specifies 10 tests, and the implementation correctly implements all 10.

Test names and assertion values are identical to the plan code block:

| Test | Plan assertions | Implementation |
|---|---|---|
| `test_default` | offset==0, lastSeenHistoryCount==0 | matches |
| `test_reconcile_at_bottom` | changed==false, offset==0, lastSeenHistoryCount==50 | matches |
| `test_reconcile_anchor` | changed==true, offset==15, lastSeenHistoryCount==105 | matches |
| `test_reconcile_clamp` | offset==105 after +10, offset==105 after -2 | matches |
| `test_wheel_positive` | offset==9, then clamped to 50 | matches |
| `test_wheel_negative` | offset==1, then clamped to 0 | matches |
| `test_wheel_fractional_accumulator` | 0→0→0→1 at 0.4 increments | matches |
| `test_scroll_to_bottom` | offset==0, wheelAccumulator==0 | matches |
| `test_page_up` | changed==true, offset==23 | matches |
| `test_page_down` | offset==7 after first, 0 after second | matches |

### Deviation: `nonisolated struct ScrollViewStateTests`

The plan spec shows `struct ScrollViewStateTests`. The implementation uses `nonisolated struct ScrollViewStateTests`. Same rationale as the production type: prevents global-actor inference on the test suite. This is a valid Swift Testing pattern and is not problematic.

---

## RenderCoordinator.swift

**Location:** `/Users/ronny/rdev/rTerm/rTerm/RenderCoordinator.swift`

### State field

```swift
private(set) var scrollState = ScrollViewState()
```
Matches plan exactly (line 3973). Declared at line 68 of the file.

### `screenModelForView` accessor

```swift
var screenModelForView: ScreenModel { screenModel }
```
Matches plan exactly (line 3185). Present at line 72.

### Scroll handler methods

All four are present with matching signatures and bodies:
- `handleScrollWheel(rowsBack:view:)` — matches plan lines 3982–3986.
- `handlePageUp(view:) -> Bool` — matches plan lines 3990–3995.
- `handlePageDown(view:) -> Bool` — matches plan lines 3998–4003.
- `scrollToBottom()` — matches plan lines 4007–4009.

The MARK comment `// MARK: - Scrollback handlers` is present (line 118), which is a minor addition beyond the plan but consistent with the file's existing MARK style.

### `draw(in:)` — reconcile and composite logic

The implementation reads `latestSnapshot()` then `latestHistoryTail()`, then calls `reconcile`, then computes `scrollOffset`. This matches the plan's specified ordering (lines 4014–4040).

The `cellAt(row:col:)` nested function is present at lines 191–201, marked `@inline(__always)`, with the exact split logic from the plan (history rows for `row < scrollOffset`, live grid for `row >= scrollOffset`).

Cursor suppression:
```swift
if snapshot.cursorVisible && scrollOffset == 0 {
```
Matches plan exactly (line 4054), at line 397 of the file.

---

## TermView.swift — TerminalMTKView

**Location:** `/Users/ronny/rdev/rTerm/rTerm/TermView.swift`

### Four new closure properties

All four are present:
- `var onScrollWheel: ((CGFloat) -> Void)?` — line 49.
- `var onPageUp: (() -> Bool)?` — line 53.
- `var onPageDown: (() -> Bool)?` — line 54.
- `var onActiveInput: (() -> Void)?` — line 58.

Match plan lines 4067–4077 exactly.

### `scrollWheel(with:)` override

Present at lines 92–106. Logic is identical to plan (lines 4082–4096): reads `scrollingDeltaY`, applies `0.05` rate for precise deltas and `1.0` for coarse, calls `onScrollWheel?()`.

### `keyDown` PgUp/PgDn intercept

Present at lines 67–90. The `switch event.keyCode` block at lines 72–79 intercepts keyCode 116 (PgUp) and 121 (PgDn) before the encoder, returning early when the handler returns `true`. This matches the plan exactly (lines 4107–4124).

`onActiveInput?()` fires at line 83, before `onKeyInput?(data)` at line 85. The plan specifies this ordering (plan comment: "Called when the user types — RenderCoordinator scrolls back to the bottom of the live grid before the input is sent"). Order is correct.

---

## TermView.swift — TermView (SwiftUI bridge)

### `makeNSView` — deviation: `makeCursorKeyModeProvider()` helper

The plan's `makeNSView` code block (lines 4130–4167) inlines the cursor key mode closure:

```swift
let model = screenModel
view.cursorKeyModeProvider = {
    model.latestSnapshot().cursorKeyApplication ? .application : .normal
}
```

The implementation extracts this to a private helper `makeCursorKeyModeProvider()` (lines 193–196) and calls it from both `makeNSView` and `updateNSView`:

```swift
view.cursorKeyModeProvider = makeCursorKeyModeProvider()
```

This is a beneficial refactor: the helper ensures `makeNSView` and `updateNSView` stay in lockstep, noted in the doc comment at line 191. The plan's `updateNSView` block already set `cursorKeyModeProvider` as one of the re-wired properties, so the helper just avoids duplication. No behavioral difference.

### Four closures wired in `makeNSView`

All four are present and structurally identical to the plan (lines 4143–4165):

- `onScrollWheel` — `[weak view, weak coordinator]` capture, calls `coordinator.handleScrollWheel(rowsBack:view:)`.
- `onPageUp` — `[weak view, weak coordinator]` capture, guards `activeBuffer == .main` and `history.count > 0`, calls `coordinator.handlePageUp(view:)`.
- `onPageDown` — `[weak view, weak coordinator]` capture, guards `activeBuffer == .main` and `coordinator.scrollState.offset > 0`, calls `coordinator.handlePageDown(view:)`.
- `onActiveInput` — `[weak coordinator]` capture, calls `coordinator?.scrollToBottom()`.

### `updateNSView`

Re-wires only `onKeyInput`, `onPaste`, `clearColor`, and `cursorKeyModeProvider`. Scroll closures are not re-wired (correct — they capture coordinator/view by weak reference and are stable across SwiftUI updates). Matches plan lines 4169–4177.

---

## Summary of Deviations

| # | Location | Deviation | Type |
|---|---|---|---|
| 1 | `ScrollViewState.swift` line 27 | `nonisolated struct` vs plan's plain `struct` | Beneficial — prevents global-actor inference on Sendable value type |
| 2 | `ScrollViewStateTests.swift` line 14 | `nonisolated struct` on test suite | Beneficial — consistent Swift Testing pattern |
| 3 | `TermView.swift` `makeNSView` | `cursorKeyModeProvider` extracted to `makeCursorKeyModeProvider()` helper | Beneficial — DRY, keeps make/update in lockstep |
| 4 | Plan Step 3 expected count | Plan says "9 tests pass"; implementation has 10 | Plan documentation error — Step 2 code block specifies all 10, count in Step 3 was not updated |

All four deviations are improvements or plan-doc corrections. No deviation introduces incorrect behavior or violates any plan requirement.

---

## Verdict

PASS. The implementation is spec-compliant on all substantive requirements. Every required property, method signature, handler method, closure wire-up, render-path composite logic, cursor suppression condition, and test assertion matches the plan. The three implementation deviations are all justified improvements over the plan's literal text; the test count discrepancy is a plan documentation error, not an implementation error.
