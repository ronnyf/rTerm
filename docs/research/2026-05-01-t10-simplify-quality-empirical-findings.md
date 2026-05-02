# T10 Simplify Quality Review — Empirical Findings

Commit: `10923bc` — "ui: scrollback view (wheel + PgUp/PgDn + auto-anchor) (Phase 2 T10)"
Review date: 2026-05-01
Reviewer: Swift-engineering skill (LSP-assisted)

## Scope

This review covers the four questions posed:
1. `cellAt(row:col:)` closure dispatch overhead — inline or fine as-is?
2. `screenModelForView` naming — confusing or fine?
3. `[weak view, weak coordinator]` verbosity — worth a helper?
4. Anything not caught by prior reviews?

---

## 1. `cellAt(row:col:)` — `@inline(__always)` local function

**File:** `rTerm/RenderCoordinator.swift:197`

```swift
@inline(__always) func cellAt(row: Int, col: Int) -> Cell {
    if row < scrollOffset { … } else { … }
}
```

**Verdict: fine as-is.** The function is annotated `@inline(__always)`, which instructs the
compiler to inline the body at every call site. There is no indirect call at runtime; the
branch becomes part of the inner loop body. The local-function form is semantically
equivalent to a manually inlined `if/else` block, but it is significantly more readable —
the intent is explicit and the two paths (history vs. live) are named clearly.

Refactoring to a raw inline `if/else` would not change code generation and would make
`draw(in:)` harder to read. No action needed.

---

## 2. `screenModelForView` accessor — naming

**File:** `rTerm/RenderCoordinator.swift:72`

```swift
var screenModelForView: ScreenModel { screenModel }
```

**Verdict: acceptable, but misleading.** The prior reviewer flagged it; the name was
accepted by the implementer. From a pure Swift API perspective the suffix `ForView` is
unusual — Swift naming convention typically names accessors after what they return, not
who calls them (e.g. `model`, `screenModel`, or just exposing the property at `internal`
visibility rather than keeping it `private` with a forwarding accessor).

The word "ForView" implies the returned model has been filtered or transformed for view
consumption, which it hasn't. The accessor returns the raw `ScreenModel` unchanged.

**Simpler alternative:** Change `private let screenModel` to `private(set) var` at
`internal` visibility (the default), drop the forwarding accessor entirely, and let the
closure capture `coordinator.screenModel` directly. The `private` on the stored property
is what forces the forwarding accessor to exist.

This is a suggestion-level finding. The current code compiles, is correct, and works.

---

## 3. `[weak view, weak coordinator]` capture lists

**File:** `rTerm/TermView.swift:154–176`

```swift
view.onScrollWheel = { [weak view, weak coordinator] rowsBack in … }
view.onPageUp      = { [weak view, weak coordinator] in … }
view.onPageDown    = { [weak view, weak coordinator] in … }
view.onActiveInput = { [weak coordinator] in … }
```

**Verdict: verbose but correct; helper not justified here.** All four closures execute on
`@MainActor` (inferred: `TerminalMTKView` is `@MainActor`-isolated; `onScrollWheel`,
`onPageUp`, `onPageDown`, `onActiveInput` are all confirmed `@MainActor` via LSP).
`RenderCoordinator` is `@MainActor final class`. The weak references prevent a retain
cycle: `TerminalMTKView` -> closure -> `coordinator` and `view` -> `TerminalMTKView`.

The `onActiveInput` closure omits `weak view` correctly because `view` is not used inside
its body — not an oversight.

A helper such as `withWeakRefs(view:coordinator:) { view, coordinator in … }` would add
abstraction without simplifying the captures — there is no repeated pattern beyond the
guard at the top. The four closures are not interchangeable (different return types: `Void`
vs `Bool`). Merging them into a helper type would require more boilerplate than it removes.

**One genuine issue** in this area: `onScrollWheel` and `onPageUp`/`onPageDown` each call
`screenModelForView` twice per invocation for `onPageUp` (once for `latestSnapshot()`,
once for `latestHistoryTail()`). Each call acquires a mutex lock and copies the result.
The two reads are not atomic with each other: `activeBuffer` and `historyCount` could
diverge between the two acquisitions. In practice this is harmless (both reads are
bounded by the same lock-protected data), but it is slightly inelegant. Not flagged as
a defect; noted for awareness.

---

## 4. Additional findings not in prior review

### 4a. `test_reconcile_clamp` comment is misleading (documentation defect)

**File:** `rTermTests/ScrollViewStateTests.swift:46–51`

```swift
// Theoretical case where historyCount appears to shrink (delta < 0):
// production history is append-only so this can't happen, but the
// negative-delta early-return path is still reachable from a careless
// caller. Guard the contract: offset stays put when delta < 0.
s.reconcile(historyCount: 108)
#expect(s.offset == 105)
```

The comment says "offset stays put when delta < 0" but `offset=105` with
`historyCount=108` would leave `offset` at 105 unchanged only because `delta = 108-110`
is negative (-2), which triggers the early `guard delta > 0 else { return false }` path.
That is factually what happens, so the logic is correct. However the comment's phrase
"Guard the contract" suggests `offset` would violate some invariant if it were not
clamped — it doesn't, because 105 < 108. The comment is misleading but the test is
correct. Suggestion: change the comment to "delta is -2 (shrink); early-return fires;
offset stays at 105, well under the new historyCount 108."

### 4b. Missing test: `reconcile` returns `false` when `newOffset == offset` after clamp

**File:** `rTermTests/ScrollViewStateTests.swift`

Path not covered: `offset` is already at `historyCount`, `delta > 0`, but
`min(historyCount, offset + delta)` equals `offset` because `historyCount` has not grown
enough to allow `offset` to advance. This path returns `false` from `reconcile` even
though `delta > 0`. Not a correctness defect — the code is correct — but the branch is
untested. The prior review listed it as gap #4; confirming it persists.

### 4c. `scrollOffset` double-`min` expression — correct but the comment is the only
     defense; consider an assertion

**File:** `rTerm/RenderCoordinator.swift:189`

```swift
let scrollOffset = min(scrollState.offset, min(history.count, rows))
```

The comment above this line (lines 183–188) correctly explains the race window that
necessitates the `rows` cap. The logic is correct. The comment is the only enforcement.
Consider a `precondition(scrollOffset <= rows, "...")` as a belt-and-suspenders guard.
Suggestion-level only.

### 4d. No test for `handleScrollWheel` when `history.count == 0`

**File:** `rTermTests/ScrollViewStateTests.swift`

`handleWheel(rowsBack:historyCount:)` with `historyCount: 0` will clamp any positive
delta to `offset = min(0, ...) = 0`. This path is correct by inspection (`max(0, min(0,
anything)) = 0`), but it is not tested. Entering scrollback with an empty history is the
common case at session start.

### 4e. `nonisolated struct` — correct and intentional

**File:** `rTerm/ScrollViewState.swift:27`

Confirmed correct (verified against xcconfig). The rTerm target has
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without `nonisolated` the struct would
be `@MainActor`-bound and the test target (`SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`)
would require `await` or `@MainActor` annotation to instantiate it. The keyword is the
right solution. Matches the pattern established by the prior review.

### 4f. Prior review reference to wrong commit hash

**File:** `docs/research/2026-05-01-t10-quality-review-empirical-findings.md:3`

The header says `Commit: 6290934` but that is not `10923bc` (the actual T10 commit).
`6290934` appears to be a draft/staging commit hash that was superseded. The document
content is correct for the code at `10923bc`; only the commit reference is stale.
Cosmetic, but worth correcting to keep the audit trail accurate.

---

## Summary

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | `cellAt` `@inline(__always)` — no overhead, do not refactor | None | — |
| 2 | `screenModelForView` naming is technically fine; a simpler option exists | Suggestion | Optional rename |
| 3 | Weak-capture verbosity is correct and no helper is justified | None | — |
| 4a | Test comment misleading for `reconcile` shrink-delta case | Suggestion | Reword comment |
| 4b | Missing test: `reconcile` returns false when capped at historyCount with delta>0 | Suggestion | Add test |
| 4c | Double-`min` for `scrollOffset` — consider `precondition` | Suggestion | Optional |
| 4d | No test for `handleWheel` with `historyCount: 0` | Suggestion | Add test |
| 4e | `nonisolated struct` — correct | None | — |
| 4f | Stale commit hash in prior review doc | Cosmetic | Fix header |
