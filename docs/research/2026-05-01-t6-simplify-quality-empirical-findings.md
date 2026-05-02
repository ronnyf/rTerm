# T6 Simplify — Quality Empirical Findings
## Commit: a57dfa3  (Phase 2 T6 simplify pass)
## Date: 2026-05-01

Files examined:
- TermCore/ScreenModel.swift (full read, grep-annotated)
- TermCore/ScrollbackHistory.swift (full read)
- TermCore/CircularCollection.swift (full read — iterator semantics)
- TermCoreTests/ScreenModelTests.swift (history section)
- TermCoreTests/ScrollbackHistoryTests.swift (full read)
- rTerm/ContentView.swift (diff)
- docs/research/2026-05-01-t6-quality-review-empirical-findings.md (prior review for delta)

---

## Q1: scrollAndMaybeEvict complexity — single function or split?

**Method:** Read ScreenModel.swift:734–786. Counted branches and line weight.

**Structure:**
```
if let region = buf.scrollRegion {
    if buf.cursor.row - 1 == region.bottom {
        // region-internal scroll (~12 lines) → return nil
    }
    // else fall through to full-screen
}
// full-screen scroll (~22 lines) → return evicted? or nil
```

**Findings:**
The function has two logical paths (region-internal, full-screen) plus one fall-through. Total body: ~52 lines including comments. The if/else structure has no nesting beyond 2 levels. Each arm is coherent: region arm does region memmove, full-screen arm optionally captures the top row then does screen memmove.

The fall-through from the region block to the full-screen block is the non-obvious part: when a scrollRegion exists but the cursor didn't step past region.bottom (it stepped past the last screen row while outside the region), it falls through silently to the full-screen branch. A comment at line 757 explains this. Without the comment it would look like dead code after the `if let region`.

**Conclusion:** The function is at the upper limit of comfortable size for a single helper (~52 lines), but splitting it would require passing `region` out of the if-let or duplicating the full-screen body. The static constraint (can't access self) means a factored `fullScreenScrollAndEvict(in:cols:rows:isMain:)` helper would be trivially extractable and would clarify the fall-through. This is a suggestion, not a defect. The fall-through comment is load-bearing.

---

## Q2: apply(_:) ordering invariant — self-explanatory?

**Method:** Read ScreenModel.swift:268–280.

**Code:**
```swift
if changed {
    version &+= 1
    if pendingHistoryPublish {
        publishHistoryTail()
        pendingHistoryPublish = false
    }
    publishSnapshot()
}
```

**Findings:**
The inline comment at line 271 explains WHY history must be published before snapshot: "a renderer reading both nonisolated mutexes between these two calls sees history newer than snapshot (briefly-duplicate row at scrollOffset > 0 is the lesser evil versus a briefly-missing row)." This is sufficient. The ordering is non-obvious (it's not symmetric — swapping the two publish calls would produce a harder-to-debug artefact) and the comment names the trade-off explicitly.

**Conclusion:** Comment is adequate. No additional annotation needed.

---

## Q3: isMain capture + evictedRow pattern — duplication worth a helper?

**Method:** Read handlePrintable (lines 321–355) and handleC0 LF/VT/FF arm (lines 377–392).

**Pattern in both:**
```swift
let isMain = (activeKind == .main)
var evictedRow: ScrollbackHistory.Row? = nil
let result = mutateActive { buf in
    ...
    evictedRow = Self.scrollAndMaybeEvict(...)
    ...
}
if let evictedRow {
    history.push(evictedRow)
    pendingHistoryPublish = true
}
return result
```

**Findings:**
The pattern is repeated twice. The boilerplate is ~6 lines per site. A helper `func scrollAndFeedHistory(in buf: inout Buffer)` that captured `isMain` and returned `(Bool, Row?)` is conceivable but would require returning two values, since `mutateActive` already returns the Bool. Alternatively a `func feedHistoryIfEvicted(_ row: Row?)` could collapse the 3-line post-closure block.

The duplication is real but bounded to exactly 2 call sites. The Swift 6 exclusivity motivation (isMain must be captured before entering the closure) is the structural reason the pattern can't be fully abstracted without a helper that also bears the inout constraint. The prior quality review (docs/research/2026-05-01-t6-quality-review-empirical-findings.md Q3) noted this pattern as correct. No new concern found.

**Conclusion:** Suggestion-level duplication at 2 sites. `feedHistoryIfEvicted(_:)` would be a clean 1-liner helper. Not a defect.

---

## Q4: pendingHistoryPublish Bool — is the evictedRow itself sufficient as signal?

**Method:** Read all 5 uses of pendingHistoryPublish (lines 134, 275–277, 352, 390, 469).

**Findings:**
The flag is set in 3 places: after a row push in handlePrintable (L352), after a row push in handleC0 (L390), and after an ED 3 history-clear in handleCSI (L469). In all three cases, there IS a corresponding mutation to `self.history`. The flag is consumed once in `apply` at L275.

The ED 3 path (L469) is the reason `evictedRow?` cannot replace the flag: ED 3 reinitialises history (no row to check), yet still needs publishHistoryTail() to fire. If the flag were replaced by `evictedRow != nil`, ED 3 would silently fail to publish the (now-empty) tail.

**Conclusion:** The Bool is the correct signal. An `evictedRow?` approach would omit the ED 3 clear-publish. The flag name is clear. No defect.

---

## Q5: HistoryBox / SnapshotBox near-duplicate

**Method:** Read lines 97–105 (SnapshotBox) and 119–123 (HistoryBox).

**Both:**
```swift
private final class XBox: Sendable {
    let value: T   // (different field names/types)
    init(_ v: T) { self.value = v }
}
```

**Findings:**
They are structurally identical: immutable, Sendable, final class, single stored property. A generic `ImmutableBox<T: Sendable>` would unify them. However, they are private nested types inside the actor; the duplication is not visible across the module. A generic version at module scope would require `public` or at least `internal` visibility. At private scope the inline duplication is acceptable.

**Conclusion:** Suggestion-level. Confirmed same shape as prior review Q9. No new concern.

---

## Q6: suffix(500) ternary in buildAttachPayload

**Method:** Read line 697.

**Code:**
```swift
let last500 = tail.count > 500 ? ContiguousArray(tail.suffix(500)) : tail
```

**Analysis:**
`ContiguousArray.suffix(_:)` returns a `SubSequence`. When count <= 500, `suffix(500)` returns the whole thing as a SubSequence view (O(1)). `ContiguousArray(subseq)` then copies it, which is O(count). With the ternary: when count <= 500, `tail` is returned as-is (no copy). Without the ternary: `ContiguousArray(tail.suffix(500))` always allocates a new ContiguousArray even if tail is already <=500 elements.

So the ternary IS a meaningful micro-optimization on the common path (few history rows at attach time = no copy). However, it conflates two different things: "take at most 500 rows" and "avoid copying when already <=500". The comment in buildAttachPayload says "last 500 rows" — the ternary is consistent but non-obvious at a glance.

Alternative: `tail.count > 500 ? ContiguousArray(tail.suffix(500)) : tail` could be written as an extension on ContiguousArray or just left as-is with a comment.

**Conclusion:** Functionally correct, micro-optimisation is valid. Suggestion-level as before. No new concern beyond prior Q10.

---

## Q7: historyCapacity magic numbers (10_000, 500, 1000)

**Method:** Grep for all three in ScreenModel.swift.

**Locations:**
- `historyCapacity: Int = 10_000` — init default (L206)
- `private static let publishedHistoryTailSize = 1000` — named constant (L128)
- `500` inline in buildAttachPayload (L697) — attach payload cap

**Findings:**
Two of the three are already handled:
- `10_000` travels as `historyCapacity` (a named public param). It is the "tunable" capacity; configurable by the caller. No magic.
- `1000` is `publishedHistoryTailSize` — named private static.
- `500` is unnamed inline. It is the attach-payload row cap (a different budget from the published tail). The doc comment for buildAttachPayload mentions "last 500 rows" but the literal 500 in the code is unexplained. A `private static let attachPayloadRowCap = 500` would close this gap.

**Conclusion:** The `500` literal in L697 is the only un-named magic number. Suggestion-level.

---

## Q8: ScrollbackHistory.tail() two-pass loop — clarity

**Method:** Read ScrollbackHistory.swift lines 72–93. Re-examine against CircularCollection iterator.

**CircularCollection iterator semantics (from CircularCollection.swift:72):**
Iterator starts at `(offset+1) % count`. After N appends to a capacity-N ring:
- offset = (N-1) % count
- Iterator starts at offset+1 % count = N % count = 0
- Iteration: elements[0], [1], ..., [N-1] → chronological order

After M appends to a capacity-N ring where M < N (not full yet):
- offset = M-1
- Iterator starts at M % N
- This means placeholder slots come FIRST in iteration order (indices M..N-1 wrap around to 0..M-1)
- First (N - M) slots in iteration order are placeholder (empty) rows

So the filter `if i < (capacity - validCount) { continue }` correctly skips the leading placeholders. Then `skip = validCount - take` skips the oldest real rows to arrive at the last `take` rows.

**Clarity concern:** The loop has two layers of skip logic (placeholder skip, then chronological skip), and the comment interleaves them. A reader needs to understand CircularCollection's iteration contract to follow this. The comment at L86–88 explains it but the explanation references "most-recently-written slots" which is true but not the most direct phrasing.

An alternative loop structure:
```swift
// Collect only real rows (drop leading placeholders), then take the suffix.
let real = ring.dropFirst(capacity - validCount)   // or a suffix-based approach
```
However, `CircularCollection` doesn't expose a `dropFirst`-based view, so this would require either a new method on CircularCollection or materialising an intermediate array, which is worse.

**Conclusion:** The loop is correct (confirmed by prior review Q1). The two-layer skip is a necessary consequence of CircularCollection's storage model. The comment is adequate. No defect; the complexity is inherent, not accidental.

---

## Q9: Doc comments — WHAT narration and stale T10 forward-refs

**Method:** Grep for "T10" and "T6" in ScreenModel.swift after the commit.

**T10 forward-refs still present:**
- Line 128: "Phase 3's fetchHistory RPC can expand this..."
- Line 678: "(T10 wires the scrollback UI on top of this accessor)"
- Line 687: "(alt-screen apps like vim/htop don't need scrollback to be transferred)"

**T6 references turned stale comment:**
Prior finding (Q7 in t6-quality-review-empirical-findings.md) identified the stale TODO in eraseInDisplay at L527. That stale comment WAS fixed in this commit (the .scrollback arm now reads "Both clear the visible grid. .scrollback (ED 3) additionally clears self.history; that side-effect happens at the call site in handleCSI..."). Confirmed resolved.

**WHAT comments:**
- publishHistoryTail doc (L291): "Publish the most recent N history rows to the nonisolated mutex so the renderer can read them without `await`. Called whenever a row is pushed to history." — This is a WHY+WHEN, which is better than WHAT alone. Acceptable.
- scrollAndMaybeEvict doc block (L722–733): Explains returns-nil conditions and the static constraint. Good.

**Conclusion:** T10 forward-refs in line 678 and 687 are accurate (T10 isn't done yet). They are forward-references, not stale references. No issue. The one stale T6 TODO from prior review was fixed.

---

## Q10: restore(from payload:) — race window during re-init

**Method:** Read lines 620–629.

**Order:**
1. L621: clear published tail (mutex write)
2. L622: restore(from: payload.snapshot) → updates actor state + publishSnapshot()
3. L623: choose cap
4. L624: init new ScrollbackHistory
5. L625–627: push recentHistory rows one by one
6. L628: publishHistoryTail()

**Race window analysis:**
Between L622 and L628, the published snapshot reflects the restored live state but the published history tail is empty (cleared at L621). Any renderer frame during this window sees a correct live grid with no history tail. The tail goes from empty to correct at L628. There is no window where the tail is partially-filled: L628 fires once after all rows are pushed.

The doc comment says "The published history tail is cleared before the live restore so the renderer cannot briefly composite an alien (pre-restore) history tail above a freshly-restored live grid." This is accurate. What the comment doesn't mention is that the tail remains empty from L621 through L628 (covering the snapshot publish at L622). Whether that matters depends on whether `scrollOffset > 0` in the renderer at this exact moment — which is a T10 concern.

**Conclusion:** The race window is documented implicitly (empty tail during restore = safe blank) but not explicitly in the comment. The behaviour is correct; a one-sentence addition clarifying that the tail stays empty until publishHistoryTail() at L628 would complete the picture. Suggestion-level.

---

## Summary table

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | Suggestion | ScreenModel.swift:734 | scrollAndMaybeEvict fall-through is load-bearing; the comment is adequate but extracting `fullScreenScrollAndEvict` would clarify intent |
| 2 | Suggestion | ScreenModel.swift:350–354, 388–392 | 2-site pattern duplication; `feedHistoryIfEvicted(_:)` would deduplicate the 3-line post-closure block |
| 3 | Suggestion | ScreenModel.swift:697 | `500` literal should be `private static let attachPayloadRowCap = 500` |
| 4 | Suggestion | ScreenModel.swift:620 | restore(from payload:) doc could note tail stays empty until L628 publishHistoryTail() |
| 5 | Info | ScreenModel.swift:128 | publishedHistoryTailSize is already a named constant — no issue |
| 6 | Info | ScrollbackHistory.swift:72 | tail() loop is correct; inherent complexity, not accidental |
| 7 | Info | SnapshotBox/HistoryBox | Near-duplicate confirmed; private scope makes it acceptable |
| 8 | Info | buildAttachPayload ternary | Micro-optimisation valid; confirmed correct from prior review Q10 |
