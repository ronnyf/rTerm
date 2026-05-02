# Phase 2 Final Review — Empirical Findings

- **Date:** 2026-05-01
- **Reviewer:** Code Review (Claude Sonnet 4.6)
- **Scope:** Full branch `phase-2-control-chars`, 11 commits (T1–T10)
- **Spec reference:** `docs/superpowers/specs/2026-04-30-control-characters-design.md` §8

---

## Question 1: Cross-task coherence of abstractions

**Method:** Read the public interfaces and usage sites for `Buffer`, `TerminalModes`, `ScrollbackHistory`, `AttributeProjection`, `ScrollViewState`, and `CursorKeyMode` across their defining task and all consuming tasks.

**Findings:**

- `Buffer` (T2): `mutateActive<R>` + read-only `active` var pattern is used consistently across every CSI handler (T3-T5) and history eviction (T6). The `shouldScroll(rows:)` predicate added by the T5 plan correction is in place and is the sole gating condition in both `handlePrintable` and `handleC0(.lineFeed/…)`.
- `TerminalModes` (T3): Internal to TermCore (`struct`, no public visibility). Four fields map 1-to-1 to `ScreenSnapshot` public fields (`cursorVisible`, `cursorKeyApplication`, `bracketedPaste`, `autoWrap`). No redundant storage; the snapshot is the only public exposure. Correct.
- `ScrollbackHistory` (T6): Wraps `CircularCollection<ContiguousArray<Row>>`. The double-container shape (`ContiguousArray` inside `ContiguousArray`) is intentional: the outer ring holds `ContiguousArray<Cell>` rows, which allows CoW-safe snapshot sharing per the comment in `push()`. The `tail()` implementation iterates the Sequence path (not the Collection subscript path), which correctly skips leading placeholder slots.
- `AttributeProjection` (T9): `nonisolated enum` with two pure static methods. Used at two call sites in `RenderCoordinator.draw(in:)`. No isolation mismatch.
- `ScrollViewState` (T10): `nonisolated struct Sendable` — correct, as it's mutated on the MainActor and read from the same. The `reconcile(historyCount:)` anchor-on-new-output behavior is correctly called at the start of each `draw(in:)` frame before `scrollOffset` is computed. The frame-level `scrollOffset` is further clamped to `min(history.count, rows)` to guard against a snapshot/history two-mutex race window.
- `CursorKeyMode` (T7): `@frozen public enum` with `.normal` / `.application`. Consumed by `KeyEncoder.encode(_:cursorKeyMode:)` (stateless, value parameter) and provided by the closure `cursorKeyModeProvider` set on `TerminalMTKView`. The provider closure is rebuilt on both `makeNSView` and `updateNSView`, keeping it in sync across SwiftUI updates.

**Conclusions:** The abstractions introduced across T1-T10 hang together coherently. Naming is consistent. No abstraction is used with different semantics at different call sites.

---

## Question 2: Consistency of similar patterns across tasks

**Method:** Compared closure-capture patterns (`[weak ...]`), `nonisolated` annotations, and static vs. instance helpers.

**Findings:**

- Closure capture in `makeNSView`: all closures capturing `coordinator` and `view` use `[weak view, weak coordinator]`. Correct — `MTKView` can outlive the coordinator during teardown.
- `onActiveInput` (T10), `onScrollWheel` (T10), `onPageUp`/`onPageDown` (T10) are set only in `makeNSView`, not in `updateNSView`. This is correct: the closures capture `coordinator` weakly, and `coordinator` is stable for the lifetime of the view (`makeCoordinator()` is called once). The comment on `updateNSView` says it only updates `onKeyInput`, `onPaste`, and `cursorKeyModeProvider` — handlers that depend on current closure values from the SwiftUI state. The scroll handlers do not depend on SwiftUI-driven values and need no re-assignment.
- Static helper pattern (`scrollAndMaybeEvict`, `clearGrid`): declared `private static func` so they cannot access `self.history` / `self.activeKind` from inside a `mutateActive` closure that already holds an inout borrow on one buffer. This is the correct exclusivity discipline, and the comment in `scrollAndMaybeEvict` explains it.
- `nonisolated` on public `ScreenModel` accessors (`latestSnapshot()`, `latestHistoryTail()`, `buildAttachPayload()`): all three read from `Mutex<_>`-protected immutable `let` boxes — correct pattern per spec §4.

**Conclusions:** Closure-capture patterns, `nonisolated` annotations, and static/instance split are applied consistently across all tasks. No deviations.

---

## Question 3: T1 parser changes vs. T3-T10 consumer alignment

**Method:** Traced the `appendCSIEvents` dispatcher dispatch path for DEC private modes; verified `DECPrivateMode.init(rawParam:)` coverage; confirmed `handleSetMode` and `handleAltScreen` in `ScreenModel` consume every documented mode.

**Findings:**

- `appendCSIEvents` intercepts `intermediates == [0x3F]` + `h/l` before `mapCSI`, emitting one `.csi(.setMode(...))` per param (the multi-emit behavior documented in the plan's spec-extending decisions). The path is exercised by the `test_csi_decset_multi_param` parser test.
- `DECPrivateMode.init(rawParam:)` covers all eight modes enumerated in the spec: 1, 7, 25, 47, 1047, 1048, 1049, 2004. Anything else routes to `.unknown(n)`.
- `handleSetMode` in `ScreenModel` handles all eight cases: autoWrap, cursorVisible, cursorKeyApplication, bracketedPaste route to the mode struct; alternateScreen47/1047/1049 and saveCursor1048 route to `handleAltScreen`.
- The `DECSTBM` (`r`) route in `mapCSI` (T1) is consumed by `handleSetScrollRegion` (T5). The `saveCursor`/`restoreCursor` routes (T1, ESC 7/8) are consumed by their respective CSI handlers (T4/T3). All T1 parser additions have a consuming handler in the model.

**Conclusions:** Parser (T1) and model consumers (T3-T10) are fully aligned. No orphaned parser events.

---

## Question 4: Spec §8 Phase 2 coverage

**Method:** Checked each bullet in spec §8 "Phase 2 — Full TUI + scrollback" against the implementation.

**Findings:**

| Spec item | Status | Evidence |
|-----------|--------|----------|
| DECAWM (7) | Delivered | `TerminalModes.autoWrap`, `handlePrintable` DECAWM-off branch, `test_decawm_off_*` tests |
| DECTCEM (25) | Delivered | `modes.cursorVisible`, snapshot field, cursor suppressed at `scrollOffset > 0` |
| DECCKM (1) + KeyEncoder hook | Delivered | `CursorKeyMode`, `cursorKeyModeProvider` closure, arrow-key DECCKM tests |
| Bracketed paste (2004) | Delivered | `TerminalSession.bracketedPasteWrap`, `paste(_:)`, `onPaste` wiring, `BracketedPasteTests` |
| Alt screen 47 / 1047 / 1049 | Delivered | `handleAltScreen`, `ScreenModelAltScreenTests` (10 tests) |
| Dual-buffer ScreenModel | Delivered | `Buffer` struct, `main`/`alt` vars, `mutateActive`, `activeKind` |
| DECSTBM | Delivered | `handleSetScrollRegion`, `ScrollRegion`, T5 plan correction applied |
| ESC 7/8 + CSI s/u | Delivered | `handleEscapeByte` (0x37/0x38), `saveCursor`/`restoreCursor` CSI cases |
| saveCursor1048 (1048) | Delivered | `handleAltScreen(.saveCursor1048, ...)`, `test_save_cursor_1048` tests |
| Scrollback history | Delivered | `ScrollbackHistory`, `ScreenModel.history`, main-only eviction |
| recentHistory on attach | Delivered | `buildAttachPayload()`, `AttachPayload.recentHistory`, `restore(from payload:)` |
| Scrollback UI (wheel + PgUp/PgDn + anchor) | Delivered | `ScrollViewState`, `RenderCoordinator` scroll handlers, T10 wiring |
| Renderer italic + bold-italic | Delivered | `GlyphAtlas.Variant.italic/.boldItalic`, four-atlas RenderCoordinator |
| Renderer dim + reverse | Delivered | `AttributeProjection.project(fg:bg:attributes:)` |
| Renderer strikethrough | Delivered | `strikethroughVerts` pass in `RenderCoordinator.draw(in:)` |
| Bell | Delivered | `bellCount` counter, `NSSound.beep()` with 200 ms rate limiter |

All spec §8 Phase 2 items are delivered. No silent drops.

**Known deferred items (explicitly acknowledged in plan):**

- Cold-attach when alt active: client receives empty `recentHistory`. Documented in plan §"Known Phase 2 limitations".
- Integration fixture corpus: only `vimStartupSequence` shipped; `ls --color`, `clear`, `top/htop` fixtures were deferred to Phase 2.5 per plan. The three inline fixtures in `TerminalIntegrationTests.swift` (`clearSequence`, `lsColorSequence`, `vimStartupSequence`) partially close this gap at unit level.

---

## Question 5: Plan deviations — documented vs. undocumented

**Method:** Searched plan file for inline correction notes; compared plan's type designs against what was implemented.

**Findings:**

- **T5 scroll dispatcher trigger condition (documented).** The plan's inline correction at T5 Step 4 documents two contradictions found during implementation — the `>= rows`-only trigger and the non-scrolling else branch — and provides the corrected `Buffer.shouldScroll(rows:)` predicate. The implemented code matches the corrected plan exactly.

- **`ScreenSnapshot` fields beyond spec §4 (plan-documented extension).** The plan's "Spec-extending decisions" section documents that `cursorKeyApplication`, `bracketedPaste`, `bellCount`, and `autoWrap` were added to `ScreenSnapshot` (beyond the four spec §4 fields). Implementation matches. All four use `decodeIfPresent ?? default` in the hand-coded `Codable`.

- **`windowTitle` nonisolated-snapshot cleanup — partial (undocumented deviation, low severity).** The comment in `ContentView.installResponseHandler` says "Task 7's snapshot reshape eliminates the MainActor race entirely by publishing windowTitle through the nonisolated snapshot" but the code still calls `applyAndCurrentTitle` (actor hop) and `currentWindowTitle()` (actor hop) rather than reading `latestSnapshot().windowTitle`. The `windowTitle` field IS on the snapshot (and was there since Phase 1). The comment documents intent but the code was not updated to match. The existing pattern is safe and correct — the race is narrowed, not eliminated. This should be cleaned up in Phase 3 but is not a bug.

- **`TerminalModes.Codable` conformance (not in spec).** The spec says `TerminalModes` is internal and its values surface through `ScreenSnapshot`; `TerminalModes` itself is not described as `Codable`. The implementation adds `Codable` to `TerminalModes`, which is harmless (it's used only in `restore(from snapshot:)` to reconstruct from snapshot fields, not serialized over the wire separately). No functional impact.

- **No other undocumented deviations found.**

---

## Question 6: Concurrency invariants

**Method:** Checked publish-ordering, nonisolated mutex pattern, exclusivity discipline, and `Sendable` annotations.

**Findings:**

- **Publish ordering (history before snapshot).** In `apply(_:)`, `publishHistoryTail()` is called before `publishSnapshot()` when `pendingHistoryPublish` is true. The comment explains the rationale: a renderer reading both mutexes between these two calls sees a history tail newer than the snapshot (briefly duplicate row) rather than a snapshot newer than history (briefly missing row). The ordering is correct per the documented "lesser evil" reasoning.

- **`_latestHistoryTail` clear in `restore(from payload:)`.** History tail is cleared first (`_latestHistoryTail.withLock { $0 = HistoryBox([]) }`), then the live snapshot is restored, then the new history is published. This prevents a renderer from briefly compositing a stale history tail above the freshly-restored live grid. The ordering is correct.

- **Exclusivity discipline in `scrollAndMaybeEvict` and `clearGrid`.** Both are `private static func` to prevent accessing `self.history` or other actor storage from inside `mutateActive`'s inout borrow on a `Buffer`. This pattern is consistent and correctly applied.

- **`buildAttachPayload()` is `nonisolated`.** It reads both `_latestSnapshot` and `_latestHistoryTail` via their respective mutexes (two separate acquisitions, not combined). This means there is a window where history and snapshot are not jointly consistent. The plan acknowledges this and documents it as acceptable — the live fan-out is raw PTY bytes anyway, and the client re-parses independently.

- **`TerminalParser` wrapped in `Mutex<TerminalParser>` in `TerminalSession`.** The XPC response handler (running on the XPC queue) takes the lock to call `parse`, then releases before handing off events to `ScreenModel` via `Task { @MainActor in ... }`. No deadlock risk; the lock is held for a bounded duration.

- **`@MainActor` on `RenderCoordinator`.** The `draw(in:)` method calls `latestSnapshot()` and `latestHistoryTail()` — both `nonisolated`, reading from `Mutex`-protected storage. No isolation violation.

**Conclusions:** Concurrency invariants are consistently enforced across all tasks. No violations found.

---

## Question 7: Test surface

**Method:** Counted `@Test` annotations per file; assessed behavioral gaps not covered.

**Findings (test counts by file on this branch):**

| File | Tests |
|------|-------|
| `TerminalParserTests.swift` | 72 |
| `ScreenModelTests.swift` | 77 |
| `ScrollbackHistoryTests.swift` | 5 |
| `KeyEncoderTests.swift` | 17 |
| `BracketedPasteTests.swift` | 4 |
| `AttributeProjectionTests.swift` | 5 |
| `ScrollViewStateTests.swift` | 12 |
| **Total Phase 2 additions** | **~80 new (192 total)** |

Coverage observations:

- Parser tests (72): Cover all DEC private modes individually, multi-param compound sets, cross-chunk boundaries, ESC 7/8, DECSTBM with nil/partial params, unknown modes.
- ScreenModel tests (77): Cover all 8 alt-screen tests (modes 47/1047/1049/1048), 6 DECSTBM tests, 8 bell/mode tests, 13 history tests (including alt suppression, region suppression, ED3 clearing, attach-payload restore, tail publication cap).
- Integration tests: 4 tests (`clear`, `ls --color`, `vimStartup`, split-chunk cross-chunk). The `top`/`htop` fixture is absent (plan-deferred).
- `ScrollViewState` tests (12): Cover reconcile anchor, wheel, page up/down, fractional accumulator, scroll-to-bottom, edge cases. Solid.

**Behavioral gaps (suggestions for Phase 3):**

1. No test for `AttributeProjection.atlasVariant` being called with all combinations of dim, underline, blink alongside bold/italic. The current 6-case test covers the mapping but not that non-atlas attributes genuinely have no effect on the variant.
2. No test for `ScrollbackHistory.tail(0)` (edge case: `n == 0`). The guard `guard validCount > 0, n > 0` handles it silently (returns `[]`), but the behavior is not tested.
3. No test verifying that `restore(from payload:)` clears the history tail BEFORE publishing the new snapshot (the ordering invariant). This is a timing/ordering invariant that unit tests cannot trivially assert without a concurrent reader, but an integration fixture could exercise the clean path.
4. No integration test for bracketed-paste round-trip through parser → model → TerminalSession (only the `bracketedPasteWrap` pure function is tested; the `TerminalSession.paste(_:)` wiring is not exercised in tests).

**Conclusions:** The ~80 new tests are well-targeted and cover the behavioral contracts. The four gaps above are suggestions, not blocking issues.

---

## Question 8: Code quality regressions against CLAUDE.md conventions

**Method:** Checked new files against project conventions: Swift Testing (not XCTest), GPLv3 headers, `@Test` style, TermCore vs. rTerm target separation, `BUILD_LIBRARY_FOR_DISTRIBUTION` implications, logging conventions.

**Findings:**

- All new test files use `import Testing` + `@Test` / `#expect` — no XCTest regression.
- New source files (`ScrollbackHistory.swift`, `TerminalModes.swift`, `DECPrivateMode.swift`, `AttributeProjection.swift`, `ScrollViewState.swift`) carry GPLv3 headers.
- `ScrollbackHistory` is `public` in TermCore, correctly exported via `TermCore.h` (umbrella). `TerminalModes` is `internal` (not exported), which is correct per the spec: it's a TermCore-private helper.
- `DECPrivateMode` is `public` and lives in its own file, consistent with the existing per-type file layout in TermCore.
- `AttributeProjection` and `ScrollViewState` are in the `rTerm` app target, not TermCore — correct (they depend on `simd` / `AppKit` / `Foundation` and are renderer/UI concerns).
- `rTermTests/AttributeProjectionTests.swift` cross-imports `TermCore` (`@testable import TermCore`) for `CellAttributes`. This is correct for a test file in the `rTermTests` target.
- `TerminalModes.Codable` conformance (noted above): harmless since `TerminalModes` is not exported and not on the XPC wire.
- The `DispatchQueue`-to-`DispatchSerialQueue` force-cast in `ScreenModel.init` is annotated with `// swiftlint:disable:next force_cast`. This was pre-existing from Phase 1 and is acknowledged as an unavoidable downcast when the caller passes a `DispatchQueue` from a daemon context that is known to be serial. No regression.
- Metal buffer allocation: six `device.makeBuffer(...)` calls per frame (up to 6 passes: regular/bold/italic/boldItalic glyph + underline + strikethrough). All allocate with `.storageModeShared`. This is a pre-existing Phase 1 pattern (Phase 1 had two glyph passes); Phase 2 adds four more. The plan notes this as a Phase 3 optimization target (pre-allocated ring buffer). No regression introduced; known technical debt documented.

**Conclusions:** No CLAUDE.md convention regressions.

---

## Question 9: Public API surface

**Method:** Checked new public declarations in TermCore for over-exposure.

**Findings:**

- `ScrollbackHistory` is entirely public (`public struct`, `public typealias Row`, `public let capacity`, `public private(set) var validCount`, `public init`, `public mutating func push`, `public func tail`, `public func all`). The spec requires `AttachPayload.recentHistory: ContiguousArray<Row>` which uses `ScrollbackHistory.Row` as a type alias. The full public surface of `ScrollbackHistory` is justified: `buildAttachPayload()` and `restore(from payload:)` both cross the TermCore boundary.
- `TerminalModes` is `struct` with no access modifier, defaulting to `internal`. Correct — it is an implementation detail of `ScreenModel`.
- `DECPrivateMode.init(rawParam:)` is `public init`. Necessary so the parser (TermCore-internal) and tests (`@testable import TermCore`) can construct modes.
- `ScreenModel.historyCapacity: Int` is `public let`. Justified: carried in `AttachPayload` so the client mirror can size its own history.
- `ScreenModel.latestHistoryTail()` is `nonisolated public func`. Necessary for T10's renderer (MainActor) to read history without `await`.

**Conclusions:** No over-exposed API surface found. Each public symbol has a documented reason.

---

## Summary

**Plan-vs-implementation deltas beyond the documented T5 correction:**

1. `windowTitle` cleanup: the comment in `ContentView` documents a future cleanup (reading `latestSnapshot().windowTitle` instead of awaiting actor methods) that was not applied. The current code is correct but slightly inefficient (extra actor hop per output chunk). The comment creates forward documentation confusion. Low priority.

**No blocking issues found.**

---

*Generated by: code review session, 2026-05-01*
