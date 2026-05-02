# T6 Quality Review — Empirical Findings
# Phase 2 T6: scrollback history + attach-payload + restore
# Commit: 1de34da  BASE: 24f9a5a

## Method

Files examined:
- TermCore/ScrollbackHistory.swift (new)
- TermCore/ScreenModel.swift (full read; diff inspected)
- TermCore/CircularCollection.swift (Sendable extension)
- TermCore/AttachPayload.swift (full read)
- TermCoreTests/ScrollbackHistoryTests.swift (new)
- TermCoreTests/ScreenModelTests.swift (history section, lines 1008–1137)
- rTerm/ContentView.swift (2-line change)

LSP workspace-symbol: not yet indexed (no results). Navigation done by direct read + rg.

---

## Q1: tail() iteration correctness

**Method:** Manual trace through CircularCollection.Iterator state.

### Case A: capacity=5, push a,b,c,d,e (validCount==capacity)
Ring after 5 appends (each `append` does `(offset+1)%count`):
- elements=[a,b,c,d,e], offset=4
- Iterator starts at currentIndex=(4+1)%5=0
- Iteration order: a,b,c,d,e (indices 0..4, i=0..4)
- capacity-validCount=0, no leading skip
- tail(2): skip=5-2=3. Skip a(i=0,seen=1), b(i=1,seen=2), c(i=2,seen=3). Append d,e. Result=[d,e]. CORRECT.

### Case B: capacity=5, push a,b,c (validCount=3), tail(2)
Ring: elements=[a,b,c,_,_], offset=2
- Iterator: currentIndex=(2+1)%5=3
- Iteration order: elements[3,4,0,1,2] = _,_,a,b,c  (i=0..4)
- capacity-validCount=5-3=2: skip i=0,i=1 (placeholders)
- skip=validCount-take=3-2=1. Skip a (i=2,seen=1). Append b(i=3), c(i=4). Result=[b,c]. CORRECT.

**Finding:** `tail()` iteration logic is correct.

---

## Q2: scrollAndMaybeEvict region-scroll condition

T5 used: `buf.cursor.row == region.bottom + 1`
T6 uses:  `buf.cursor.row - 1 == region.bottom`

These are algebraically identical. Both callers (handlePrintable and handleC0 LF) increment `cursor.row` before calling `shouldScroll()` → `scrollAndMaybeEvict`. When the pre-increment cursor was at `region.bottom`, the post-increment cursor is `region.bottom + 1`, so both forms detect the same condition.

**Finding:** Semantically equivalent. No regression.

---

## Q3: Static scrollAndMaybeEvict exclusivity safety

`mutateActive` holds an inout reference to either `self.main` or `self.alt`. If a helper called inside that closure were to also access `self.main`, `self.alt`, `self.activeKind`, or `self.history`, Swift 6's exclusivity enforcement would trap at runtime.

`scrollAndMaybeEvict` is `private static`. It takes `inout Buffer` and two value params (`cols`, `rows`, `isMain`). It cannot access any `self` storage. The `isMain` bool was captured before entering `mutateActive`, and `evictedRow` is a local `var` outside the closure. History push happens after `mutateActive` returns.

**Finding:** Exclusivity is correctly maintained. No runtime exclusivity violation possible.

---

## Q4: pendingHistoryPublish actor flag safety

`pendingHistoryPublish` is an actor-isolated `var`. `apply(_:)` is synchronous on the actor's serial executor — no suspension points, no reentrancy possible. The flag is set by handlers and cleared at the end of `apply`. Multiple events in one `apply` batch can each set it; the single `if pendingHistoryPublish` block at the end consolidates into one publish call, which is correct (one publish per batch, not one per row).

**Finding:** Safe. The flag is a legitimate intra-apply communication channel.

---

## Q5: nonisolated buildAttachPayload two-mutex window

```swift
let snap  = _latestSnapshot.withLock { $0.snapshot }    // mutex 1
let tail  = _latestHistoryTail.withLock { $0.rows }     // mutex 2
```

These are two separate mutex reads. Between them the actor could publish a new snapshot+history (from a concurrent `apply`). Worst case: `snap` reflects N rows and `tail` reflects N+1 rows (an extra row visible at the top of the scrollback). The snap's `activeBuffer` check prevents alien-buffer history from leaking in.

This is a cosmetic tearing artefact at attach time (one extra row briefly visible), not a data corruption. The alternative — a combined lock over both — would require SnapshotBox and HistoryBox to live in a single mutex, which would couple the two publish paths.

**Finding:** Acceptable design trade-off. Not a bug. Documented in the restore(from:payload) comment.

---

## Q6: historyCapacity fallback in restore(from payload:)

```swift
let cap = payload.historyCapacity > 0 ? payload.historyCapacity : historyCapacity
```

Phase 1 payloads carry `historyCapacity: 0` (AttachPayload default). The `> 0` guard falls back to `self.historyCapacity` in that case, which is correct. A Phase 2 daemon talking to a Phase 1 client would send `historyCapacity > 0` and the client would honour it.

**Finding:** Wire compatibility is correct.

---

## Q7: eraseInDisplay(.scrollback) stale TODO comment

ScreenModel.swift line 527:
```swift
case .all, .scrollback:
    // .scrollback is handled in T6 once history exists; for now treat as .all.
    for i in 0..<(rows * cols) { buf.grid[i] = .empty }
```

This comment was written in T5 as a forward-reference to T6. T6 has now landed and `self.history` exists. However, `eraseInDisplay` is called via `mutateActive` — it cannot access `self.history` inside the closure due to exclusivity. The correct fix requires the same pattern as history push: detect the erase-scrollback case outside the closure and clear history after `mutateActive` returns. The stale comment makes it appear this was intentionally deferred to T7, but the T6 feature it was waiting for is now present.

**Finding:** IMPORTANT — stale comment is misleading and the behaviour (ED 3 not clearing scrollback) is now a correctness gap since T6 introduced the history object.

---

## Q8: CircularCollection Sendable constraint

```swift
extension CircularCollection: Sendable where Container: Sendable, Container.Index: Sendable {}
```

CircularCollection stores:
- `elements: Container` (Sendable if Container: Sendable)
- `offset: Container.Index` (Sendable if Container.Index: Sendable)

`Container: Sendable` does NOT imply `Container.Index: Sendable` — Index is an associated type that could be a non-Sendable class for some hypothetical Container. For `ContiguousArray<T>` the Index is `Int` which is trivially Sendable, but the constraint is correct and necessary for the general case.

**Finding:** Constraint is precise. No issue.

---

## Q9: SnapshotBox / HistoryBox duplication

Both are identical private final class patterns: `let rows` / `let snapshot`, immutable after init, `Sendable` by virtue of immutable stored properties. They could share a generic `ImmutableBox<T: Sendable>` or be replaced by `Mutex<T>` pointing directly at the value type (since `Mutex<ScreenSnapshot>` and `Mutex<ContiguousArray<Row>>` would also work). The duplication is contained to two nested private classes, both in one file.

**Finding:** Minor duplication. Justifiable as explicit; no functional issue.

---

## Q10: suffix(500) ternary in buildAttachPayload

```swift
let last500 = tail.count > 500 ? ContiguousArray(tail.suffix(500)) : tail
```

`ContiguousArray.suffix(n)` when n >= count returns a SubSequence containing all elements. `ContiguousArray(tail.suffix(500))` when `tail.count <= 500` produces a full copy equal to `tail`. The ternary avoids allocating a second ContiguousArray when not needed (tail is already a ContiguousArray value). This is a micro-optimization that avoids one copy on the common path (history < 500 rows). Not harmful but slightly over-engineered; `ContiguousArray(tail.suffix(500))` unconditionally is cleaner and still O(min(count,500)).

**Finding:** Suggestion-level. Functionally correct.

---

## Q11: Test suite gap — interleaved alt+main scroll

The 8 history tests cover:
- Main LF feeds history ✓
- Alt LF suppressed ✓
- Region scroll suppressed ✓
- Capacity eviction ✓
- buildAttachPayload (main/alt) ✓
- restore from payload ✓
- tail cap at publishedHistoryTailSize ✓

Missing: main scroll → enter alt → alt scroll → exit alt → history still intact.
This tests that alt activity (even with full-screen scrolls in alt) doesn't pollute or reset `self.history`. The code path is provably correct (isMain check in scrollAndMaybeEvict), but the test gap leaves it unverified under the test suite.

**Finding:** Test gap. Should be added.

---

## Q12: @Suite annotation missing on ScreenModelHistoryTests

`ScreenModelHistoryTests` has no `@Suite` decorator. The prior test structs in the file (`ScreenModelScrollRegionTests`, etc.) also lack it — this is the file-wide convention. Not a defect.

**Finding:** Consistent with file convention. No issue.

---

## Q13: HistoryBox conformance to Sendable

`private final class HistoryBox: Sendable` relies on the `rows` stored property being `Sendable`. `ContiguousArray<ScrollbackHistory.Row>` where `Row = ContiguousArray<Cell>` and `Cell: Sendable`. The compiler can verify this chain. `let` storage makes HistoryBox safely Sendable.

**Finding:** Correct.

---

## Q14: ContentView.swift change

Two call sites changed from `restore(from: payload.snapshot)` to `restore(from: payload)`. Both are inside `Task { @MainActor in }` blocks on the client side. ScreenModel is `public actor`. `await screenModel.restore(from: payload)` hops to the actor executor. No isolation concern.

**Finding:** Correct.

---

## Summary of issues

| # | Severity | File | Description |
|---|----------|------|-------------|
| 1 | Important | ScreenModel.swift:527 | Stale `.scrollback` TODO — T6 landed but ED 3 still doesn't clear `history` |
| 2 | Important | ScreenModelTests.swift | Missing test: main-scroll → alt-enter → alt-scroll → alt-exit → history intact |
| 3 | Suggestion | ScreenModel.swift:686 | `tail.count > 500 ? ContiguousArray(tail.suffix(500)) : tail` simplifiable to `ContiguousArray(tail.suffix(500))` |
| 4 | Suggestion | ScreenModel.swift | `historyCapacity: Int = 10_000` and `publishedHistoryTailSize = 1000` could be `public static let` with a doc comment for configurability |
| 5 | Suggestion | ScreenModel.swift | `HistoryBox` / `SnapshotBox` duplication; minor, low priority |
