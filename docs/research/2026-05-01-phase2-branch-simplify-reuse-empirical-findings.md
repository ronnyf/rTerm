# Phase 2 Branch-Wide Simplify/Reuse — Empirical Findings

- **Date:** 2026-05-01
- **Scope:** Full branch `phase-2-control-chars` (T1–T10), 10 commits, ~2750 net lines across 23 files
- **Focus:** Cross-task patterns not visible inside any single commit's diff
- **Method:** `rg` across branch file contents (`git show phase-2-control-chars:<file>`), plus `git diff main..phase-2-control-chars`

---

## Q1: Closure-property-on-TerminalMTKView — should 7 closures become a bindings struct or protocol?

**Method:** Read `rTerm/TermView.swift` on branch; tabulated which closures appear in `makeNSView` vs `updateNSView`; read T10 `/simplify reuse` findings which already addressed Q1 from T10's narrower scope.

**Findings:**

The 7 closure properties split cleanly into two groups with different update semantics:

| Group | Properties | Set in makeNSView | Set in updateNSView | Capture type |
|-------|-----------|-------------------|---------------------|--------------|
| A — SwiftUI-value-derived | `onKeyInput`, `onPaste`, `cursorKeyModeProvider` | Yes | Yes | Escaping closures from SwiftUI struct fields, must refresh on each `updateNSView` because the SwiftUI struct is a value type that can be re-constructed with new values |
| B — stable-capture | `onScrollWheel`, `onPageUp`, `onPageDown`, `onActiveInput` | Yes | No | `[weak view, weak coordinator]` captures; `coordinator` is identity-stable for the view lifetime (`makeCoordinator()` called once) |

A `TermViewBindings` struct would need to expose both groups, but a caller setting Group B from `updateNSView` would be incorrect (the closures it builds during `updateNSView` have no `coordinator` at that call site — only `makeNSView` has access to the freshly created `coordinator`). The split is semantically required, not stylistic.

The existing comment on `makeCursorKeyModeProvider()` (`TermView.swift:187-196`) documents this distinction explicitly: "Centralising the closure here keeps `makeNSView` and `updateNSView` in lockstep."

A delegate protocol (`TerminalMTKViewDelegate`) would be a valid alternative architectural style, but: (a) it would require a weak reference to a delegate object and protocol conformance boilerplate on `RenderCoordinator`; (b) `RenderCoordinator` is already the `MTKViewDelegate`; adding a second delegate protocol increases layering; (c) the `cursorKeyModeProvider` is a query, not an event — its return value must be captured at call time, which is naturally expressed as a closure and awkward as a delegate method. No net improvement.

**Conclusion:** The 7-closure flat list is correct. The Group A / Group B distinction is functional (not cosmetic), already documented, and cannot be collapsed without losing the distinction. No unification opportunity.

---

## Q2: `nonisolated` value-type pattern — needs CLAUDE.md documentation or a lint rule?

**Method:** `git diff main..phase-2-control-chars` for all `nonisolated` additions; checked existing CLAUDE.md for any existing guidance; counted distinct usage shapes.

**Findings:**

New `nonisolated` declarations added by the branch (non-comment, non-doc lines):

| Declaration | File | Shape |
|-------------|------|-------|
| `nonisolated public func latestHistoryTail()` | `TermCore/ScreenModel.swift` | nonisolated method on actor, reads `Mutex`-protected field |
| `nonisolated enum AttributeProjection` | `rTerm/AttributeProjection.swift` | top-level `nonisolated` on a pure-computation enum (no storage) |
| `nonisolated public static func bracketedPasteWrap` | `rTerm/ContentView.swift` | nonisolated static method on `@MainActor` class |
| `nonisolated enum Variant: Sendable, Equatable` | `rTerm/GlyphAtlas.swift` | nested enum inside a non-isolated class |
| `nonisolated struct ScrollViewState: Sendable, Equatable` | `rTerm/ScrollViewState.swift` | top-level `nonisolated` value type |
| `nonisolated struct ScrollViewStateTests` | `rTermTests/ScrollViewStateTests.swift` | `nonisolated` on a Swift Testing suite struct |

These fall into three distinct shapes:

1. **Actor nonisolated accessors** (method on `ScreenModel` actor): `nonisolated` + `Mutex` is the established pattern since Phase 1 (`latestSnapshot()`, `buildAttachPayload()`). Phase 2 adds `latestHistoryTail()`. Already described in CLAUDE.md under "Terminal Processing Pipeline" prose.

2. **Enum / struct marked `nonisolated` to suppress actor-isolation inference**: `AttributeProjection`, `GlyphAtlas.Variant`, `ScrollViewState` are pure value types with no mutable storage. Swift 6 infers `@MainActor` on types defined in files where `@MainActor` context is dominant (e.g., `ContentView.swift`, `GlyphAtlas.swift`). `nonisolated` opts them out, enabling call-sites in non-`@MainActor` contexts (especially unit tests). Each instance has a doc comment explaining the `nonisolated` choice and why it matters for tests.

3. **Test suite `nonisolated`**: `ScrollViewStateTests` is `nonisolated` because its `@Test` methods are not `async` but the Swift Testing framework runs them from a non-isolated context; without `nonisolated`, the struct would inherit `@MainActor` from the file-level inference and the test runner would need to hop the actor for each test. The `nonisolated` annotation makes the tests free-threaded. `AttributeProjectionTests` is plain `struct` (not `nonisolated`) — the difference is file-level isolation inference: `AttributeProjectionTests.swift` does not sit alongside `@MainActor` context.

The pattern is well-understood by readers who know Swift 6 actor inference rules. No lint rule enforces consistent `nonisolated` placement because the need for it is context-dependent (per-file actor inference). However, it is not documented in CLAUDE.md, which means a future contributor adding a new enum in a `@MainActor`-dominant file might be confused about why test targets fail to compile.

**Conclusion:** The three shapes are correctly and consistently applied. A brief note in CLAUDE.md under "Key Conventions" documenting Shape 2 ("value types in `@MainActor` files use `nonisolated` to stay free-threaded for test access") would reduce future confusion. No lint rule needed; the Swift compiler enforces `Sendable` conformance and isolation mismatches. Priority: low.

---

## Q3: `private static let` on RenderCoordinator — style drift?

**Method:** Compared `main` vs branch in `rTerm/RenderCoordinator.swift`; checked what pattern main used; checked rest of the project for static-let precedent.

**Findings:**

On `main`, `floatsPerCellVertex`, `floatsPerOverlayVertex`, and `verticesPerCell` were declared as local `let` constants inside the `draw(in:)` method body. The branch promotes them to `private static let` on `RenderCoordinator` and adds a fourth: `bellMinInterval`.

Before promotion (main):
```swift
// Inside draw(in:):
let floatsPerCellVertex = 12
let floatsPerOverlayVertex = 8
let verticesPerCell = 6
```

After promotion (branch):
```swift
// On RenderCoordinator:
private static let bellMinInterval: TimeInterval = 0.2
private static let floatsPerCellVertex = 12
private static let floatsPerOverlayVertex = 8
private static let verticesPerCell = 6
```

The promotion is motivated by two separate needs: (a) `bellMinInterval` is read outside `draw(in:)` (in the bell handler), so it needs class scope; (b) the four new arrays added by T9 (italic, boldItalic, underline, strikethrough) also call `reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)`, so the constants are now referenced from two distinct code regions within `draw(in:)`. Keeping them as locals would mean duplicating the literals in the italic/boldItalic reservation block, which was the approach on main (two literal `12`/`8`/`6` usages per pass, now four).

`private static func` was already used in `RenderCoordinator` on `main` for factory helpers (`makeDevice`, `makeCommandQueue`, `makeLibrary`, etc.), so `private static let` for constants is consistent with the existing static usage style in this class.

Elsewhere in the codebase `GlyphAtlas.swift` uses `private static let columns = 16`, `private static let rows = 6`, etc. (pre-existing), so the pattern has precedent in `rTerm`.

**Conclusion:** The `private static let` promotion is style-consistent with both the pre-existing `RenderCoordinator` factory helpers and the `GlyphAtlas` pattern. No drift. The promotion is also functionally necessary for `bellMinInterval` (accessed from outside `draw(in:)`) and prevents literal duplication for the geometry constants across the expanded set of render passes. Clean.

---

## Q4: `HistoryBox` / `SnapshotBox` duplication — extract `ImmutableBox<T>` now?

**Method:** Read both class definitions in `TermCore/ScreenModel.swift` (lines 99–123 on branch); read T6 `/simplify reuse` findings (Q1), which already addressed this question.

**Findings:**

Both classes are identical in structure: `private final class … Sendable` with a single `let` field and a one-argument `init`. The only difference is the property name and wrapped type.

The T6 reuse review concluded: "the duplication is a known pattern, not a mistake. Extraction to a generic box is a cosmetic simplification worth considering in a future cleanup pass, but not a correctness issue."

Now that the branch is complete and neither a third `Mutex<Box>` nor a Phase 3 addition of one is planned, the assessment stands. Specifically:

- Both boxes are `private` to `ScreenModel.swift` — the duplication cannot spread to other files.
- The named types (`SnapshotBox`, `HistoryBox`) document the purpose of each `Mutex` at the declaration site without needing hover.
- `ImmutableBox<T>` would require callers to use `box.value` instead of `box.snapshot` / `box.rows` — slightly less readable at each `withLock { $0 = …Box(…) }` and `withLock { $0.snapshot }` call site.
- If a third `Mutex`-protected immutable is added in Phase 3, the case for extraction strengthens and the naming convention (`windowTitle`? `terminalSize`?) would clarify whether a generic box is the right shape.

**Conclusion:** Do not extract now. The T6 conclusion stands: bounded duplication, named types are more readable for two instances. Revisit if a third `Mutex<Box>` is added.

---

## Q5: `Mutex<Box>` pattern — unified?

**Method:** Checked `ScreenModel.swift` for all `Mutex<…>` properties; also checked if Phase 1 `_latestSnapshot` pattern changed.

**Findings:**

Three `Mutex` properties on `ScreenModel` in branch state:
- `private let _latestSnapshot: Mutex<SnapshotBox>` (Phase 1)
- `private let _latestHistoryTail: Mutex<HistoryBox>` (T6)
- `private let _executor: Mutex<DispatchSerialQueue>` — internal actor executor (Phase 1, not a Box wrapper)

The `_executor` mutex holds a `DispatchSerialQueue` directly (not via a Box class), so the `Mutex<Box>` pattern is only two instances, both snapshot-publishing. The pattern is consistent: published output state is held via an immutable heap-boxed wrapper in a mutex so `nonisolated` readers get a pointer-swap rather than a copy.

The `Mutex<Box>` pairing is fully unified in behavior — the T6 addition is a direct parallel of the Phase 1 `_latestSnapshot` pattern applied to history. No accidental variation.

**Conclusion:** Consistent. No unification needed beyond what's already done.

---

## Q6: Test fixture duplication — has the extraction threshold been crossed?

**Method:** Counted `ScreenModel(cols:rows:)` init lines across all test files; checked `mockKeyDown`/`makeKeyEvent` helper scope; examined Swift Testing suite structure.

**Findings:**

`ScreenModel` inline construction count:
- `ScreenModelTests.swift`: 79 occurrences (10 distinct dimension combos; `(cols: 4, rows: 3)` is 16 of 79, `(cols: 5, rows: 1)` is 12 of 79)
- `TerminalIntegrationTests.swift`: 5 occurrences
- `ScrollbackHistoryTests.swift`: 0 (tests `ScrollbackHistory` directly, not via `ScreenModel`)

The 79 inline inits in `ScreenModelTests.swift` span 10 suites (`ScreenModelTests`, `ScreenModelCSITests`, `ScreenModelPenTests`, etc.) across 1206 lines. Each suite is a `struct` — Swift Testing suites cannot have `@TestSuite`-level `setUp`/`tearDown` lifecycle hooks that re-initialize an actor per test (actors cannot be `var` at the struct level without a workaround). Even if they could, the different dimension combos per test (`(cols: 4, rows: 3)` for basic tests, `(cols: 80, rows: 24)` for integration-style tests) mean a single fixture would not serve all tests.

The practical extraction path would be a factory function: `private func makeModel(cols: Int = 80, rows: Int = 24) -> ScreenModel`. This exists as a pattern in `ScrollbackHistoryTests.swift` where `private func row(_ s: String) -> Row { … }` provides a Row factory. However, `ScreenModelTests.swift` uses at least 10 distinct (cols, rows) combinations, so a parameterized factory would reduce boilerplate only for tests that use the same default.

In practice, the per-test `let model = ScreenModel(cols: X, rows: Y)` inline is idiomatic Swift Testing style: each `@Test` is a standalone function, and constructing the fixture inside the test body is the recommended pattern per the Swift Testing documentation (avoids cross-test state sharing, which is especially important for actors).

`mockKeyDown`/`makeKeyEvent` helpers in `rTermTests/KeyEncoderTests.swift` (lines 38-76): defined as `private func` at file scope. Used exclusively in `KeyEncoderTests` — 9 call sites in that file, 0 in any other file. No duplication across files.

No other rTermTests file defines a competing `mockKeyDown` or `makeKeyEvent`.

**Conclusion:** The `ScreenModel` inline-init pattern is idiomatic for Swift Testing actor tests and cannot be easily unified without a `setUp`-equivalent that Swift Testing structs do not support. The `mockKeyDown` helper is file-scoped and not duplicated. Threshold is not crossed; per-task "below threshold" verdicts remain correct at branch scale.

---

## Q7: Forward-reference comments — stale after branch completion?

**Method:** Scanned all changed source files on the branch for `T[n] will`, `T[n] wires`, `T[n] reads`, `T[n] adds`, `T[n] hooks`, and `Phase 3` patterns.

**Findings:**

Surviving T-tagged comments in source (not docs) as of branch tip:

| File | Line | Comment | Status |
|------|------|---------|--------|
| `TermCore/ScreenModel.swift` | 126 | `Phase 3's fetchHistory RPC can expand this to deep backscroll` | Live forward reference — Phase 3 is future work. Not stale. |
| `TermCore/ScreenModel.swift` | 690 | `(T10 wires the scrollback UI on top of this accessor)` | T10 is landed. This is now a historical cross-reference, not a forward reference. Slightly stale in framing but low noise — it helps readers understand why `latestHistoryTail()` is public. |
| `TermCore/TerminalParser.swift` | 46 | `Phase 3 parses sixel / kitty images` | Live forward reference — Phase 3 is future work. Not stale. |
| `TermCore/TerminalParser.swift` | 546 | `Phase 3 (hyperlinks, clipboard, …) can disambiguate later` | Live forward reference. Not stale. |
| `TermCore/TerminalParser.swift` | 627 | `Phase 3 disambiguates these` | Live forward reference. Not stale. |
| `TermCore/DECPrivateMode.swift` | 41 | `Phase 3 introspection` | Live forward reference. Not stale. |

The earlier T-numbered forward references that were present during individual task passes (`T5 wires .setScrollRegion`, `T6 will add a history-feed path`, `T4 wires these`) were cleaned up as each task landed — they do not appear in the branch tip. The T3/T4/T5 pass reviews noted them as "useful scaffolding to be cleaned on landing"; the implementer did so.

Only one comment is "backward" (referencing a completed task): `ScreenModel.swift:690` where `(T10 wires…)` describes T10 which is now done. This is a low-severity documentation issue: it accurately describes the relationship but uses future-tense framing that is now past. It could be updated to read e.g. `(the scrollback UI in T10's RenderCoordinator reads this)`.

All `Phase 3` references are genuine forward references to the next development phase and should be kept.

**Conclusion:** 1 cosmetically stale comment (`ScreenModel.swift:690`), 5 correct live forward references (`Phase 3`). The single stale one is low-priority cleanup; no blocking issues.

---

## Summary table

| Pattern | Finding | Recommendation |
|---------|---------|----------------|
| 7 closure properties on TerminalMTKView | Correctly split Group A (make+update) and Group B (make-only). A bindings struct would conflate different update semantics. | No change. |
| `nonisolated` value-type pattern | 3 shapes: actor accessors (established), value types in @MainActor files (new), test suite annotation (new). Consistent and correct. Not in CLAUDE.md. | Add 1-sentence note to CLAUDE.md "Key Conventions" about Shape 2. |
| `private static let` on RenderCoordinator | Consistent with pre-existing `GlyphAtlas` and `RenderCoordinator` static patterns. Functionally required for `bellMinInterval`. | No change. |
| `HistoryBox`/`SnapshotBox` duplication | 2 instances, both `private`, named types more readable than generic `ImmutableBox<T>`. Bounded. | Revisit if a 3rd instance is added in Phase 3. No action now. |
| `Mutex<Box>` pattern | Two instances, fully parallel. No accidental variation. | No change. |
| Test fixture `ScreenModel(cols:rows:)` | 79 inits across 10 distinct dimension combos in `ScreenModelTests.swift`. Swift Testing actor tests cannot share a setUp-initialized fixture. Idiomatic as-is. `mockKeyDown` is file-scoped, not duplicated. | No change. |
| Forward-reference comments | 5 live `Phase 3` references (correct). 1 cosmetically stale `T10 wires…` in `ScreenModel.swift:690`. | Optional: reword `ScreenModel.swift:690` to past tense. All others fine. |

---

*Generated by: branch-wide simplify/reuse pass, 2026-05-01*
