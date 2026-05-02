# T6 Spec Review — Empirical Findings

**Date:** 2026-05-01
**Commit:** 1de34da
**Reviewer:** Claude Sonnet 4.6 (code review)
**Task:** Phase 2 T6 — Scrollback history + AttachPayload + history-aware restore

---

## Question 1: Does `ScrollbackHistory` match the spec shape exactly?

**Method:** Read `/Users/ronny/rdev/rTerm/TermCore/ScrollbackHistory.swift`; compared to spec §4 Step 1 (plan lines 1990–2076).

**Findings:**
- `public struct ScrollbackHistory: Sendable` — matches.
- `typealias Row = ContiguousArray<Cell>` — matches.
- `public let capacity: Int` — matches.
- `@usableFromInline var ring: CircularCollection<ContiguousArray<Row>>` — matches spec storage shape.
- `public private(set) var validCount: Int = 0` — matches.
- `init(capacity:)` with `precondition(capacity > 0, ...)` — matches.
- `public var count: Int { validCount }` — matches.
- `public mutating func push(_ row: Row)` bumps `validCount` up to `capacity` — matches.
- `public func tail(_ n: Int) -> ContiguousArray<Row>` returning last `n` chronologically — matches.
- `public func all() -> ContiguousArray<Row>` alias for `tail(validCount)` — matches.
- CoW WARNING doc comment present on `push` — matches spec requirement.
- `@usableFromInline` on `ring` not in spec but harmless (needed for inlinable `push`/`tail` if ever annotated).

**Conclusions:** Full spec compliance. No deviations.

---

## Question 2: Does `ScreenModel` contain all required history fields and init changes?

**Method:** Read `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift` lines 107–235.

**Findings:**
- `private var history: ScrollbackHistory` — present at line 111.
- `public let historyCapacity: Int` — present at line 114.
- `private final class HistoryBox: Sendable` — present at lines 119–122.
- `private let _latestHistoryTail: Mutex<HistoryBox>` — present at line 123.
- `private static let publishedHistoryTailSize = 1000` — present at line 128.
- `private var pendingHistoryPublish: Bool = false` — present at line 134.
- Init signature `(cols:rows:historyCapacity:queue:)` with defaults — present at line 205.
- `historyCapacity` is declared `let` (immutable stored property), making the `nonisolated` read inside `buildAttachPayload` safe without a lock.
- `_latestHistoryTail` initialized with `Mutex(HistoryBox([]))` — present at line 234.

**Conclusions:** All spec-required fields present. The `let` on `historyCapacity` is a correctness point: because it's immutable, `buildAttachPayload` can read it `nonisolated` without data-race risk.

---

## Question 3: Are `publishHistoryTail()` and `latestHistoryTail()` implemented to spec?

**Method:** Read `ScreenModel.swift` lines 290–670.

**Findings:**
- `private func publishHistoryTail()` calls `history.tail(Self.publishedHistoryTailSize)` and swaps into `_latestHistoryTail` via `withLock` — matches spec Step 3.
- `nonisolated public func latestHistoryTail() -> ContiguousArray<ScrollbackHistory.Row>` returns `_latestHistoryTail.withLock { $0.rows }` — matches spec Step 3.

**Conclusions:** Compliant.

---

## Question 4: Does `scrollAndMaybeEvict` correctly replace T5's scroll helpers?

**Method:** Read `ScreenModel.swift` lines 711–775; searched for `scrollUp`, `scrollWithinActiveBounds`, `scrollRegionUp`.

**Findings:**
- No residual T5 helpers (`scrollUp`, `scrollWithinActiveBounds`) exist in the file — replaced entirely by `scrollAndMaybeEvict`.
- Region-internal condition: `buf.cursor.row - 1 == region.bottom` — correctly detects cursor stepped one past region bottom after the `row += 1` increment.
- Region-internal scroll: copies rows within `region.top ..< region.bottom`, blanks `region.bottom` row, moves cursor to `region.bottom`, returns `nil` — matches spec.
- Below-region fall-through: correctly falls through to full-screen scroll when `cursor.row - 1 != region.bottom` — matches spec comment (xterm behavior preserved from T5).
- Full-screen scroll: only captures top row when `isMain == true` — matches spec §4 "Alt buffer never feeds history."
- `isMain` is captured from `activeKind` BEFORE `mutateActive` is called in both `handlePrintable` and `handleC0` — correct Swift 6 exclusivity discipline.
- `var evictedRow` is declared outside the closure and assigned inside, pushed to `history` after closure returns — matches spec hot-path discipline.

**Conclusions:** Fully spec-compliant. The static design satisfies the Swift 6 exclusivity rationale documented in spec §4 Step 4.

---

## Question 5: Does `apply(_:)` publish history before snapshot?

**Method:** Read `ScreenModel.swift` lines 252–281.

**Findings:**
- Sequence: `version &+= 1` → `publishHistoryTail()` (if `pendingHistoryPublish`) → `pendingHistoryPublish = false` → `publishSnapshot()`.
- This matches spec Step 4 ordering requirement: "Publish history FIRST so a renderer reading both nonisolated mutexes between these two calls sees history newer than snapshot."

**Conclusions:** Correct ordering. Compliant.

---

## Question 6: Does `buildAttachPayload` correctly populate `recentHistory`?

**Method:** Read `ScreenModel.swift` lines 681–696.

**Findings:**
- `nonisolated` — matches spec Step 5.
- Reads `snap.activeBuffer` to gate `recentHistory` — spec-correct.
- When main: reads `_latestHistoryTail.withLock { $0.rows }` then takes `suffix(500)` — gives last 500 rows, matches spec "last 500 rows."
- When alt: `rows = []` — matches spec "empty when alt active."
- `historyCapacity: historyCapacity` in the `AttachPayload` init — passes capacity to wire format.
- Note: `buildAttachPayload` reads `historyCapacity` nonisolated. This is safe because `historyCapacity` is a `let` stored property (initialized once, never mutated).

**Conclusions:** Compliant. The nonisolated `let` access is correct.

---

## Question 7: Does `restore(from payload:)` follow spec ordering?

**Method:** Read `ScreenModel.swift` lines 609–618.

**Findings:**
- Clears `_latestHistoryTail` to empty BEFORE calling `restore(from: payload.snapshot)` — matches spec Step 6 "Clear the published history tail BEFORE the live restore."
- `restore(from: payload.snapshot)` called next — delegates to the existing snapshot-only overload.
- Re-inits `history` with `payload.historyCapacity` (fallback to `self.historyCapacity` when `<= 0`) — matches spec.
- Pushes each row from `payload.recentHistory` — matches spec.
- Calls `publishHistoryTail()` at end — matches spec.

**Conclusions:** Compliant. Ordering matches spec's stated renderer-correctness rationale.

---

## Question 8: Are both ContentView call sites updated to `restore(from: payload)`?

**Method:** Read git diff for `rTerm/ContentView.swift` in commit 1de34da.

**Findings:**
- Line 88: `restore(from: payload.snapshot)` → `restore(from: payload)` in `connect()` after `.attach` reply — updated.
- Line 151: `restore(from: payload.snapshot)` → `restore(from: payload)` in `installResponseHandler` `.attachPayload` case — updated.
- Both call sites confirmed, matching spec Step 7.

**Conclusions:** Compliant.

---

## Question 9: Do the ScrollbackHistory tests match spec Step 2?

**Method:** Read `/Users/ronny/rdev/rTerm/TermCoreTests/ScrollbackHistoryTests.swift`.

**Findings:**
- 5 `@Test` functions present — matches spec count.
- `@Suite("ScrollbackHistory")` annotation present.
- Test names match spec: `test_empty`, `test_push_grows`, `test_push_evicts`, `test_tail`, `test_tail_caps`.
- All test bodies are character-for-character matches to spec Step 2.

**Conclusions:** Compliant.

---

## Question 10: Do the ScreenModelHistoryTests match spec Step 8?

**Method:** Read `ScreenModelTests.swift` lines 1012–1137.

**Findings:**
- 8 `@Test` functions in `ScreenModelHistoryTests` — matches spec count.
- `@Suite` annotation is absent on `ScreenModelHistoryTests`. All other test structs in this file also lack `@Suite` (consistent with project convention — `@Suite` is only used in `ScrollbackHistoryTests`). This is not a spec violation; spec does not require `@Suite`.
- `test_history_feed_main_buffer` — matches spec.
- `test_history_feed_alt_buffer_suppressed` — matches spec.
- `test_history_feed_region_scroll_suppressed` — matches spec.
- `test_history_capacity_evicts_oldest` — DEVIATED from spec (documented below).
- `test_attach_payload_populates_history` — matches spec.
- `test_attach_payload_empty_history_in_alt` — matches spec.
- `test_restore_payload_seeds_history` — DEVIATED from spec (documented below).
- `test_history_tail_publication_cap` — matches spec.

**Conclusions:** 6/8 match spec exactly. 2 tests carry a justified off-by-one fix.

---

## Question 11: Are the two test deviations (off-by-one fixes) correct?

**Method:** Manual trace of both spec version and implementation version.

**Findings for `test_history_capacity_evicts_oldest`:**

Spec version iterates with `[.printable(letter), .cursorPosition(row:1,col:0), .lineFeed]`.

Trace of spec version (cols=1, rows=2):
- Iter 'a': cursor starts at (0,0), `printable('a')` → grid[0]='a', cursor=(0,1) [deferred wrap]. `cursorPosition(1,0)` → cursor=(1,0). `lineFeed` → row=2, scroll evicts top row = grid[0]='a' → history=['a']. Grid: [empty, empty].
- Iter 'b': cursor at (1,0). `printable('b')` → grid[1]='b', cursor=(1,1). `cursorPosition(1,0)` → cursor=(1,0). `lineFeed` → scroll evicts grid[0] = EMPTY (not 'b'!). History=['a', empty].

The spec version silently evicts wrong rows because after a scroll, row 0 is empty and the printable in the next iteration lands in row 1 (cursor is already there from `cursorPosition(1,0)`).

Implementation fix adds `.csi(.cursorPosition(row:0,col:0))` at the start of each iteration, ensuring the printable lands in row 0 and the subsequent LF-scroll evicts the just-written letter.

Trace of fixed version:
- Each iter: `cursorPosition(0,0)`, `printable(letter)` → grid[0]=letter, `cursorPosition(1,0)`, `lineFeed` → scroll evicts grid[0]=letter ✓.
- After 6 iters (capacity=3): history = [d, e, f] ✓.

**Findings for `test_restore_payload_seeds_history`:**

Same root cause: the spec version uses `[.printable(c), .cursorPosition(row:1,col:0), .lineFeed]`. Without the row-0 reset, 'a' lands in row 0 on iter 1 (cursor starts there), but on iters 2+ the printable lands in row 1 (because the prior scroll left cursor at row 1, then `cursorPosition(1,0)` keeps it there). The evicted row on iters 2+ would be empty instead of the letter.

Fix adds `.csi(.cursorPosition(row:0,col:0))` at start of each iteration — correct for the same reason.

**Conclusions:** Both fixes are necessary and correct. The spec's test code had a logical error in the scenario setup that the implementer correctly identified and repaired. The assertions being tested (history contents) are unchanged; only the setup is corrected.

---

## Question 12: Does the CircularCollection Sendable extension addition satisfy its stated rationale?

**Method:** Read `/Users/ronny/rdev/rTerm/TermCore/CircularCollection.swift` lines 120–124; analyzed constraint necessity.

**Findings:**
- New extension: `extension CircularCollection: Sendable where Container: Sendable, Container.Index: Sendable {}`.
- `CircularCollection` has two stored properties: `elements: Container` and `offset: Container.Index`.
- For `Sendable`, both must be `Sendable`. `Container: Sendable` covers `elements`; `Container.Index: Sendable` covers `offset`.
- The `Container.Index: Sendable` constraint is therefore necessary — without it the conformance would be unsound (the offset, a stored `Index` value, could be non-Sendable).
- `ContiguousArray<T>.Index = Int`, and `Int: Sendable`, so `ScrollbackHistory.ring` (a `CircularCollection<ContiguousArray<Row>>`) satisfies both constraints. The added constraint admits exactly the correct set of conforming types.
- The extension does not modify any behavior — it is purely declarative.
- File scope is limited: only `CircularCollection.swift` modified, doc comment explains rationale.

**Conclusions:** The addition is technically necessary, minimally scoped, correctly constrained, and properly documented. Justified deviation.

---

## Question 13: Were only the allowed files modified?

**Method:** `git show 1de34da --name-only`.

**Findings:**
Files changed:
1. `TermCore/CircularCollection.swift` — not listed in spec's allowed files but the modification was required by Swift 6 strict concurrency to make `ScrollbackHistory` compile (see Question 12). The spec's allowed-file list pre-dates knowing this compiler requirement. Justified.
2. `TermCore/ScreenModel.swift` — allowed.
3. `TermCore/ScrollbackHistory.swift` — allowed (create).
4. `TermCoreTests/ScreenModelTests.swift` — allowed.
5. `TermCoreTests/ScrollbackHistoryTests.swift` — allowed (create).
6. `rTerm.xcodeproj/project.pbxproj` — implied by creating two new source files; no explicit mention in spec but required for Xcode build graph.
7. `rTerm/ContentView.swift` — allowed.

`TermCore/AttachPayload.swift` was NOT modified. The spec says "Modify: TermCore/AttachPayload.swift (add convenience init(snapshot:) if not already; ensure existing public init accepts the rows)." The existing `AttachPayload` already had `recentHistory: ContiguousArray<Row>` and `historyCapacity: Int` fields with a `public init` accepting them (confirmed by reading the file). No modification was needed; the spec's "if not already" qualifier covers this case.

**Conclusions:** No out-of-scope file modifications. The one unlisted file (`CircularCollection.swift`) was a required compiler-driven fix.

---

## Question 14: Do xcodeproj entries exist for both new files?

**Method:** `grep -n "ScrollbackHistory" rTerm.xcodeproj/project.pbxproj`.

**Findings:**
- `ScrollbackHistory.swift` has PBXFileReference, PBXBuildFile, and group membership entries — correctly added to TermCore target Sources.
- `ScrollbackHistoryTests.swift` has PBXFileReference, PBXBuildFile, and group membership entries — correctly added to TermCoreTests target Sources.

**Conclusions:** Compliant.

---

## Question 15: Does `buildAttachPayload` correctly take last 500 from the published tail (not directly from `history`)?

**Method:** Read `ScreenModel.swift` lines 681–696.

**Findings:**
- Reads `_latestHistoryTail.withLock { $0.rows }` — this is the published tail (capped at `publishedHistoryTailSize = 1000`).
- Then takes `suffix(500)` of that tail.
- So the 500-row cap is taken from the published-1000-row mirror, not from the full `history` ring. This means if `history.validCount > 1000`, the attach payload shows rows `validCount-1000` through `validCount-501` (oldest available in mirror) to `validCount-1` (newest). The history ring is an actor-isolated `var` and cannot be read nonisolated, so the mirror is the only safe path.
- This design is intentional and matches the spec's note: "Phase 3's fetchHistory RPC can expand this to deep backscroll without growing the published tail."

**Conclusions:** Compliant with the stated design trade-off.

---

## Summary

| Checklist item | Status | Notes |
|---|---|---|
| `ScrollbackHistory` struct shape | PASS | Exact match to spec |
| `ScrollbackHistory` doc/invariant comment | PASS | Present |
| ScreenModel history fields | PASS | All 5 required fields present |
| Init signature `(cols:rows:historyCapacity:queue:)` | PASS | Correct defaults |
| `publishHistoryTail()` | PASS | |
| `latestHistoryTail()` nonisolated | PASS | |
| `scrollAndMaybeEvict` static dispatcher | PASS | T5 helpers fully replaced |
| Region-internal returns nil | PASS | |
| Alt buffer returns nil | PASS | |
| Below-region full-screen fall-through | PASS | |
| `handlePrintable` isMain + evictedRow capture | PASS | Correct exclusivity discipline |
| `handleC0` LF/VT/FF isMain + evictedRow capture | PASS | |
| `apply(_:)` history-before-snapshot ordering | PASS | |
| `buildAttachPayload` main active path | PASS | Last 500 from published tail |
| `buildAttachPayload` alt active path | PASS | Empty |
| `buildAttachPayload` `nonisolated` | PASS | |
| `restore(from payload:)` clear-before-restore ordering | PASS | |
| `restore(from payload:)` seeds history + publishes | PASS | |
| ContentView call site 1 (`connect`) | PASS | |
| ContentView call site 2 (`installResponseHandler`) | PASS | |
| ScrollbackHistoryTests — 5 tests | PASS | |
| ScreenModelHistoryTests — 8 tests | PASS | |
| `CircularCollection` Sendable extension | PASS (deviation) | Necessary for Swift 6; correctly constrained |
| Test off-by-one fixes | PASS (deviation) | Spec had buggy setup; fix is correct |
| AttachPayload unchanged | PASS | Already had required fields |
| xcodeproj entries | PASS | Both new files registered |
| File scope (no unauthorized files) | PASS | CircularCollection justified by compiler |

**Overall verdict: SPEC COMPLIANT** — with two documented deviations both of which are improvements over the spec (a compiler-required Sendable fix and a bugfix to the spec's own test setup).

No issues require remediation before proceeding to T7.
