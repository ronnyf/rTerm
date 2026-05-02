# T6 Simplify/Reuse — Empirical Findings

Date: 2026-05-01
Commit reviewed: a57dfa3 (model: scrollback history + attach-payload + restore — Phase 2 T6)
Prior reviews already addressed: ED 3 wiring, alt-history isolation test.

---

## Q1: Does `HistoryBox` duplicate the `SnapshotBox` pattern? Could a generic `ImmutableBox<T>` replace both?

**Method:** Read `TermCore/ScreenModel.swift` lines 97–123 directly. Searched `rg "private final class.*Box.*Sendable"` across the whole repo.

**Findings:**

`SnapshotBox` (lines 99–102):
```swift
private final class SnapshotBox: Sendable {
    let snapshot: ScreenSnapshot
    init(_ snapshot: ScreenSnapshot) { self.snapshot = snapshot }
}
```

`HistoryBox` (lines 119–122):
```swift
private final class HistoryBox: Sendable {
    let rows: ContiguousArray<ScrollbackHistory.Row>
    init(_ rows: ContiguousArray<ScrollbackHistory.Row>) { self.rows = rows }
}
```

The two types are structurally identical: both are `private final class … Sendable` with a single immutable `let` property and a one-argument `init`. The only difference is the property name (`snapshot` vs `rows`) and the wrapped type (`ScreenSnapshot` vs `ContiguousArray<ScrollbackHistory.Row>`). A generic `private final class ImmutableBox<T: Sendable>: Sendable { let value: T; init(_ value: T) { self.value = value } }` could replace both.

`rg` found no other box types in the codebase; the pattern is confined to `ScreenModel.swift`. No pre-existing generic box exists elsewhere.

**Conclusions:** The duplication is real. A generic `ImmutableBox<T: Sendable>` would DRY two near-identical types. The tradeoff is readability at call sites: `ImmutableBox<ScreenSnapshot>` and `ImmutableBox<ContiguousArray<…>>` vs named `SnapshotBox`/`HistoryBox`. The named types make each mutex's purpose self-documenting without hovering over a declaration. Because both types are `private` (scoped entirely inside `ScreenModel`), the duplication is bounded — it cannot multiply further without a new `nonisolated` mutex being added. Net verdict: the duplication is a known pattern, not a mistake. Extraction to a generic box is a cosmetic simplification worth considering in a future cleanup pass, but not a correctness issue. No action required now.

---

## Q2: Does `tail.suffix(500)` in `buildAttachPayload` require an explicit `ContiguousArray` conversion? Is there a cleaner pattern?

**Method:** Read `TermCore/ScreenModel.swift` line 697 directly:
```swift
let last500 = tail.count > 500 ? ContiguousArray(tail.suffix(500)) : tail
```
Checked what `tail` is (result of `_latestHistoryTail.withLock { $0.rows }`, type `ContiguousArray<ScrollbackHistory.Row>`). Consulted stdlib knowledge about `ContiguousArray.suffix(_:)`.

**Findings:**

`ContiguousArray.suffix(_:)` conforms to `Collection.suffix(_:)`, which returns a `SubSequence`. For `ContiguousArray`, the `SubSequence` is `ArraySlice<Element>`, not `ContiguousArray<Element>`. So `tail.suffix(500)` yields an `ArraySlice<Row>`, which shares the underlying buffer of `tail` but is not a `ContiguousArray`. The explicit `ContiguousArray(tail.suffix(500))` is therefore required to produce the declared type `ContiguousArray<ScrollbackHistory.Row>` — without it the assignment would not type-check.

The guard `tail.count > 500 ? … : tail` avoids the copy when 500 or fewer rows are present; the else branch returns the original `ContiguousArray` directly (zero copy, CoW). This is correct and idiomatic.

An alternative spelling: `ContiguousArray(tail.suffix(500))` unconditionally would always copy even when `tail.count <= 500`, returning a fresh array of the same elements. The current form is slightly more efficient because the copy is skipped when the tail already fits within the 500-row budget.

**Conclusions:** The explicit `ContiguousArray(...)` wrapping is necessary (not redundant). The `count > 500 ?` guard is a correct micro-optimization. No cleaner pattern exists for this specific constraint. Clean as-is.

---

## Q3: Does `restore(from payload:)` delegate to `restore(from snapshot:)`? Confirm.

**Method:** Read `TermCore/ScreenModel.swift` lines 620–629 directly. Then read `restore(from snapshot:)` at lines 573–609.

**Findings:**

```swift
public func restore(from payload: AttachPayload) {
    _latestHistoryTail.withLock { $0 = HistoryBox([]) }   // clear stale tail first
    restore(from: payload.snapshot)                        // delegate to snapshot overload
    let cap = payload.historyCapacity > 0 ? payload.historyCapacity : historyCapacity
    self.history = ScrollbackHistory(capacity: cap)
    for row in payload.recentHistory {
        history.push(row)
    }
    publishHistoryTail()
}
```

`restore(from payload:)` calls `restore(from: payload.snapshot)` on line 622. The snapshot overload does the full live-state restore: grid, cursor, `activeKind`, `windowTitle`, `TerminalModes`, `bellCount`, `version`, and calls `publishSnapshot()`. The payload overload then handles the history-specific steps (clear stale tail, seed history, publish history tail).

There is no duplicated live-state logic between the two overloads. The delegation is clean and complete.

**ContentView.swift call sites** (lines 88 and 151): both call `screenModel.restore(from: payload)` where `payload: AttachPayload`, so they always go through the payload overload. No caller passes `payload.snapshot` directly.

**Conclusions:** Confirmed — `restore(from payload:)` delegates to `restore(from snapshot:)` for all live-state restoration. The split is correct: snapshot overload owns grid/cursor/modes; payload overload owns history seeding. No logic duplication.

---

## Q4: The `for c in "abc" { await model.apply(...) }` pattern appears in 4+ history tests — is there a fixture helper that could DRY this up?

**Method:** Ran `rg "for.*in.*\"[a-z]" TermCoreTests --type swift -n`. Read the full `ScreenModelHistoryTests` suite (lines 1014–1204 of `TermCoreTests/ScreenModelTests.swift`). Searched for any `private func`, `extension`, or shared helpers in `TermCoreTests/`.

**Findings:**

The pattern appears at 5 locations in `TermCoreTests/ScreenModelTests.swift`:
- Line 1064: `for letter in "abcdef"` — `test_history_capacity_evicts_oldest`
- Line 1110: `for c in "abc"` — `test_restore_payload_seeds_history`
- Line 1142: `for c in "abc"` — `test_history_preserved_across_alt_enter_exit`
- Line 1170: `for c in "abc"` — `test_ed3_clears_scrollback`
- Line 1189: `for c in "ab"` — `test_ed3_in_alt_preserves_main_history`
- Line 71 (ScrollbackHistoryTests): `for c in "abcde"` — `test_tail` (struct, no `ScreenModel`)

The body of each iteration in the `ScreenModelHistoryTests` cases is:
```swift
await model.apply([
    .csi(.cursorPosition(row: 0, col: 0)),
    .printable(Character(String(c))),
    .csi(.cursorPosition(row: 1, col: 0)),
    .c0(.lineFeed),
])
```
This 4-event sequence is repeated verbatim in 4 tests. A helper such as:
```swift
func feedHistoryRow(_ model: ScreenModel, _ c: Character) async {
    await model.apply([
        .csi(.cursorPosition(row: 0, col: 0)),
        .printable(c),
        .csi(.cursorPosition(row: 1, col: 0)),
        .c0(.lineFeed),
    ])
}
```
could reduce repetition. However: (a) there are no `private func` helpers anywhere in `TermCoreTests/ScreenModelTests.swift` — the entire file uses inline `apply` calls per the existing convention; (b) the `ScrollbackHistoryTests` struct uses a different `row(_ s:)` helper because it operates on `ScrollbackHistory` directly, not `ScreenModel`; (c) the 4-event sequence is short and its intent (position, print a char, move to last row, LF to trigger eviction) is clear from reading.

**Conclusions:** A `feedHistoryRow` helper would reduce 4 repetitions of a 5-line block. The refactoring is legitimate but cosmetic — the current repetition does not cause any correctness risk and matches the file's existing style of inline apply arrays. No helper was added in the commit, consistent with the style of every other test suite in the file. If the pattern proliferates beyond the current 4 call sites (e.g., in T10 scrollback UI tests), extraction would be warranted.

---

## Q5: Does `ScrollbackHistory.tail(_:)` do its own iteration arithmetic — does `CircularCollection` already provide a `suffix` or `lastN` operation?

**Method:** Read `TermCore/CircularCollection.swift` in full (125 lines). Read `TermCore/ScrollbackHistory.swift` `tail(_:)` implementation (lines 67–83).

**Findings:**

`CircularCollection` provides:
- `append`, `prepend` (O(1) mutations)
- `Sequence` conformance via a custom `Iterator` that walks from `offset+1` to `offset` in ring order (oldest → newest)
- `Collection` and `BidirectionalCollection` conformances
- No `suffix`, `lastN`, `tail`, or similar bulk-copy methods

`CircularCollection.subscript(position:)` maps logical index `i` to physical index `(offset+1+i) % count` — valid but O(1) per element, no bulk-copy path.

`ScrollbackHistory.tail(_:)` manually iterates via `ring.enumerated()`, skipping the `(capacity - validCount)` leading placeholder slots and the first `(validCount - take)` real rows:
```swift
let skip = validCount - take
var seen = 0
for (i, row) in ring.enumerated() {
    if i < (capacity - validCount) { continue }
    if seen < skip { seen += 1; continue }
    result.append(row)
}
```

This is O(capacity) regardless of `take`. Because `CircularCollection` conforms to `Collection` and `BidirectionalCollection`, stdlib `suffix(_:)` is available on it — but it returns `Slice<CircularCollection<…>>`, not a `ContiguousArray`. That slice shares no storage with the ring's underlying buffer; materializing it into a `ContiguousArray` would still require iterating.

More importantly, the `validCount` complication (the ring has `capacity` slots, only `validCount` are real) means stdlib `suffix` on the raw ring would include placeholder empty-row slots during the fill-up phase. `ScrollbackHistory.tail` correctly skips those placeholders via `if i < (capacity - validCount) { continue }`. Stdlib `suffix` has no awareness of `validCount`.

**Conclusions:** `CircularCollection` does not have a `suffix`/`lastN` method. Even if it did, the `validCount`-aware placeholder-skipping logic is specific to `ScrollbackHistory` and cannot be pushed down to `CircularCollection` without leaking `ScrollbackHistory` semantics into the generic ring. The manual iteration in `tail(_:)` is the correct and necessary approach. No simplification is available here.

---

## Overall verdict

All five questions find the T6 implementation sound with respect to reuse:
- `HistoryBox` / `SnapshotBox` duplication is bounded and deliberate — named types are more readable than a generic box in this context. Low-priority cleanup candidate only.
- `ContiguousArray(tail.suffix(500))` is necessary and correct; the count guard avoids a copy in the common case.
- `restore(from payload:)` delegates cleanly to `restore(from snapshot:)` — confirmed, no duplication.
- The `for c in "abc"` test pattern is consistent with the file's established style; 4 repetitions is below the extraction threshold for this codebase.
- `ScrollbackHistory.tail(_:)` cannot be simplified using `CircularCollection`'s existing API — `validCount`-aware placeholder skipping is inherently local to `ScrollbackHistory`.

No changes recommended from this review.
