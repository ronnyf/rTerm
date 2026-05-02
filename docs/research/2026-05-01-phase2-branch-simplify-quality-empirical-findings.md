# Phase 2 Branch-Wide Quality Review — Empirical Findings

- **Date:** 2026-05-01
- **Reviewer:** Claude Sonnet 4.6 (cross-task patterns pass)
- **Scope:** `phase-2-control-chars` branch, all 10 commits (T1–T10), ~2750 net lines across 23 files
- **Method:** `git diff main..phase-2-control-chars`, full file reads, LSP navigation, cross-reference with existing per-task research docs

---

## Q1: ScreenSnapshot init parameter sprawl — fix now or Phase 3?

**Method:** Read `TermCore/ScreenSnapshot.swift` on branch; read plan "spec-extending decisions" section; read per-task research for T3, T4, T6.

**Findings:**

`ScreenSnapshot` has 12 init parameters post-Phase 2:
`activeCells`, `cols`, `rows`, `cursor`, `cursorVisible`, `activeBuffer`, `windowTitle`, `cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`, `version`.

The parameters cluster naturally into two groups:
- Layout/grid: `activeCells`, `cols`, `rows`, `cursor`, `version`
- Terminal state: `cursorVisible`, `activeBuffer`, `windowTitle`, `cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`

The Phase 2 additions all went into the second group. The `makeSnapshot(from:)` private helper in `ScreenModel` is the sole producer of `ScreenSnapshot` (plus `restore(from:)` reading back from an existing snapshot), so call-site impact is low right now.

The existing `SnapshotBox`/pointer-swap pattern limits the cost of adding fields — the publish path copies the struct once; readers pay zero copy on `latestSnapshot()` reads. Adding more fields does not affect that invariant.

**Risk of deferring to Phase 3:** Phase 3 will add at least `windowTitle` on the snapshot path (the existing comment in `ContentView` documents this) and possibly `iconName`. Two more fields would reach 14. The breakpoint where the unwrapped init becomes genuinely risky for callers constructing test snapshots inline is already past (7 defaults help, but the first three non-defaulted params `activeCells/cols/rows` make positional mistakes possible). `TerminalParser` tests construct `ScreenSnapshot` via `ScreenModel.latestSnapshot()`, not directly, so there is no test fragility today.

**Plan recommendation:** The per-task reviewers' recommendation to extract a `TerminalStateSnapshot` sub-struct before more fields land is architecturally sound but not urgent. The sole producer (`makeSnapshot(from:)`) is private and well-contained. The cleaner trigger for extraction is when Phase 3 adds the `windowTitle` field to the snapshot path (eliminating the extra actor hop in `ContentView`) — at that point the second parameter cluster has grown again and refactoring has obvious co-located motivation.

**Conclusions:** Defer to Phase 3 remains the right call. Document the two-cluster shape in `ScreenSnapshot.swift` with a comment so the Phase 3 implementer has context without re-reading research docs.

---

## Q2: ScreenModel.swift size — split now or defer?

**Method:** Counted lines (`941`), read the file structure, counted logical sections.

**Findings:**

The file at 941 lines has these logical sections:
- `ScrollRegion` private struct (~5 lines)
- `ScreenModel` actor declaration and stored properties (~95 lines)
- `Buffer` nested struct + `mutateActive` + `active` (~50 lines)
- `init` (~45 lines)
- `apply(_:)` + `publishSnapshot()` + `publishHistoryTail()` + `makeSnapshot(from:)` (~60 lines)
- Event handlers: `handlePrintable`, `handleC0`, `handleCSI`, `applySGR`, `handleOSC` (~200 lines)
- `eraseInDisplay`, `eraseInLine` (~30 lines)
- `restore(from:)` x2 (~65 lines)
- Snapshot access (`snapshot()`, `latestSnapshot()`, `latestHistoryTail()`, `buildAttachPayload()`) (~80 lines)
- Private helpers: `snapshotCursor`, `scrollAndMaybeEvict`, `clearGrid`, `restoreActiveCursor`, `handleSetMode`, `handleSetScrollRegion`, `handleAltScreen` (~300 lines)

The proposed split into `ScreenModel.swift` + `ScreenModel+Buffer.swift` + `ScreenModel+History.swift` was evaluated against the actual code:

- `ScreenModel+Buffer.swift` would contain `ScrollRegion`, `Buffer`, `mutateActive`, `active`, `scrollAndMaybeEvict`, `clearGrid` — roughly 180 lines. These ARE conceptually cohesive.
- `ScreenModel+History.swift` would contain `ScrollbackHistory` storage fields, `publishHistoryTail`, `restore(from payload:)`, `buildAttachPayload`, `latestHistoryTail` — roughly 100 lines.
- This leaves `ScreenModel.swift` at ~660 lines, still large but focused on event processing.

The main obstacle to the split is that `Buffer`, `ScrollRegion`, `SnapshotBox`, and `HistoryBox` are all declared as `private` inside the actor or file scope. A Swift `extension` in a separate file CAN access them if they are not explicitly `private` on the type (only `fileprivate` or `internal`). Currently they ARE `private`, which means moving them to extensions in separate files would require promoting `Buffer` and `ScrollRegion` to at least `fileprivate`. That is a safe change but requires care.

**Conclusions:** The split is desirable and preparable now. However, it is not urgent — 941 lines with good MARK comments and clear section boundaries is navigable. The right time is Phase 3 when the file is expected to grow further. No action required before merge.

---

## Q3: Deferred refactors — which have aged into "fix now"?

**Method:** Read the source state of each deferred item; assessed materiality at current scale.

### WritableKeyPath-based `mutateMode` helper (T3 deferred)

**Finding:** The four cases in `handleSetMode` for `autoWrap`, `cursorVisible`, `cursorKeyApplication`, `bracketedPaste` follow identical patterns: guard idempotent, mutate one field, return true. A `WritableKeyPath`-based helper would collapse 12 lines to 4. However, `handleSetMode` also routes `alternateScreen*` and `saveCursor1048` cases to `handleAltScreen`, so a generalization would only cover 4 of 6 switch arms. At current scale the repetition is easily readable. Not urgent.

### `ImmutableBox<T>` to replace `SnapshotBox`/`HistoryBox` (T6 deferred)

**Finding:** Both classes are `private` inside `ScreenModel` (2 lines each). The duplication is bounded and both per-task reviewers and the final review independently concluded the named types are more readable than a generic. Not urgent; confirmed by multiple research passes.

### `Cursor.zero` / `.origin` static (T4 deferred)

**Finding:** `Cursor(row: 0, col: 0)` appears 4 times in `ScreenModel.swift` (init, `handleAltScreen` 1049 enter, and two `scrollAndMaybeEvict` branches do NOT use it — they use `buf.cursor.row = rows - 1`). Adding `public static let zero = Cursor(row: 0, col: 0)` to `ScreenSnapshot.swift` is a one-liner with no correctness risk. But at 4 sites the friction is low. Not urgent; nice-to-have for Phase 3.

### `screenModelForView` rename (T10 deferred)

**Finding:** The accessor `var screenModelForView: ScreenModel { screenModel }` exists at `RenderCoordinator.swift:72` and is used at `TermView.swift:161,163,169`. The name accurately describes its role (exposing the private `screenModel` to TermView's closures). The T10 reviewer called it confusing; the T10 simplify research called it fine. Verdict: at 3 call sites the cost is trivial either way. Remains a suggestion only.

### File-split for ScreenModel.swift (T2/T6 deferred)

**Finding:** See Q2. Not urgent before merge.

### Per-frame Metal buffer pre-allocation (T9/final deferred)

**Finding:** The renderer allocates 6 `device.makeBuffer(...)` calls per frame. At 60 fps this is 360 allocations/sec against the shared Metal heap. The plan documents this as a Phase 3 optimization. With a 24x80 terminal that is 1920 cells, each producing ~576 bytes of vertex data (if all are non-empty bold/italic). In practice most cells are regular, so the `regularVerts` buffer dominates and the others are tiny. The shared-memory path (`storageModeShared`) is relatively cheap on Apple Silicon. Not a correctness issue; profiling may not even show it as a hotspot. Stays deferred.

**Conclusions:** None of the deferred items have aged into "must fix before merge." All remain suggestions appropriate for Phase 3 cleanup.

---

## Q4: Concurrency invariant documentation

**Method:** Read the publish-ordering comment in `apply(_:)` (ScreenModel.swift:277-285); read the ordering comment in `restore(from payload:)` (ScreenModel.swift:624-630); assessed whether the invariant is findable by a future maintainer.

**Findings:**

The `apply(_:)` publish-ordering comment (history before snapshot) reads:
```
// Publish history FIRST so a renderer reading both nonisolated
// mutexes between these two calls sees history newer than snapshot
// (briefly-duplicate row at scrollOffset > 0 is the lesser evil
// versus a briefly-missing row).
```

This is present in the source. However, there is no reciprocal warning on `publishSnapshot()` or `publishHistoryTail()` themselves — a future refactor that calls `publishSnapshot()` before `publishHistoryTail()` in a new code path would not have an obvious guard. The invariant is expressed at the call site in `apply`, not enforced at the definition site.

The `restore(from payload:)` version has an equivalent ordering comment (lines 624-630) explaining why history tail is cleared first.

**Gap:** `ScreenModel+Buffer.swift` (if created in Phase 3) or any future `apply`-variant method would need to independently rediscover and copy the ordering rule. A doc-comment on the `pendingHistoryPublish` flag itself (currently "Set by handlers when a row is pushed to history; consumed at end of apply(_:) to publish a fresh history tail...") does not mention the ordering requirement.

**Conclusions:** The invariant is documented at the consumption sites in `apply` and `restore`. It is not documented at the property declaration for `pendingHistoryPublish` nor at the `publishHistoryTail()` function declaration. Adding one sentence to `publishHistoryTail()`'s doc comment ("Callers must invoke this before `publishSnapshot()` to maintain the history-before-snapshot ordering invariant") would make a future reviewer's job easier. This is a suggestion, not a blocking issue.

---

## Q5: Plan vs implementation drift — undocumented deviations

**Method:** Searched the plan file for all correction markers; compared plan's type designs against implemented source; read the final review findings Q5.

**Findings:**

- **T5 scroll dispatcher (documented correction).** The plan's inline `> **Plan correction (2026-05-01)**` block at T5 Step 4 correctly documents the two contradictions and the corrected code. Implemented source matches the correction exactly (`Buffer.shouldScroll(rows:)`, full-screen scroll on below-region LF). No divergence.

- **`windowTitle` nonisolated-snapshot cleanup (undocumented, low-severity).** The comment in `ContentView.swift` (line in the `.output` case handler) says "Task 7's snapshot reshape eliminates the MainActor race entirely by publishing windowTitle through the nonisolated snapshot" — but the code still calls `applyAndCurrentTitle` (an actor hop) and `currentWindowTitle()` (another actor hop). `windowTitle` is on `ScreenSnapshot` and accessible via `latestSnapshot().windowTitle` without any await. The comment documents a future cleanup intention but the code was not updated to match it. The current code is correct (race is narrowed, not fully eliminated). The misleading comment is the actual issue.

- **`TerminalModes.Codable` (undocumented addition, harmless).** Spec does not describe `TerminalModes` as `Codable`. Implementation adds it. It is only used internally in `restore(from snapshot:)` to reconstruct modes from snapshot fields. No functional impact, not serialized over the wire.

- **No other deviations found.**

**Conclusions:** One misleading comment in `ContentView.swift` (the `windowTitle` cleanup note). Should be corrected before merge — it will confuse a Phase 3 implementer looking for the "simpler path."

---

## Q6: Stale comments and forward references

**Method:** Searched all 23 changed source files for `T[0-9] wires`, `T[0-9] will`, `T8/T10`, `TODO`, `FIXME`; cross-checked against what actually landed.

**Findings:**

**In source files (the set that matters):**

- `rTerm/TermView.swift:192` — The `makeCursorKeyModeProvider()` doc comment says "keeps `makeNSView` and `updateNSView` in lockstep as additional view callback hooks are added (e.g. T10's scroll handlers)." T10 has landed. "e.g. T10's scroll handlers" is now a backward reference to completed work. The comment should be updated to remove the task reference and state the purpose directly.

- `TermCore/CircularCollection.swift:53` — `// TODO: we can split the payload into before and after slices, and apply them, 2 steps instead of n`. This is pre-existing from Phase 1 (not introduced by Phase 2), so it is not a Phase 2 regression. However, it remains an unresolved TODO in a public framework file.

**In the plan file (not source — not blocking):**
The plan's body contains `T4 wires`, `T5 wires`, `T6 will add`, etc. — these are now stale in the plan document but plan files are reference documents, not live code. They do not affect the codebase.

**Conclusions:** One stale task-reference comment in production source (`TermView.swift:192`). Should be cleaned up; low severity. The CircularCollection TODO is pre-existing and tracked separately.

---

## Q7: Dead code and unused parameters

**Method:** Searched for obviously unreachable code, `handleCSI` default arm, `handleAltScreen` default arm, unused stored properties; checked the `iconName` field.

**Findings:**

- `handleAltScreen` has a `default: return false` arm (ScreenModel.swift:937) with a comment "unreachable: handleSetMode filters to alt-screen modes before calling here." This is correct but the dead arm does prevent an exhaustive-switch compiler warning. Not a problem; the comment is accurate.

- `iconName: String?` is stored in `ScreenModel` and updated by `handleOSC(.setIconName(...))` but never exposed on `ScreenSnapshot` and never read by any consumer. The `currentIconName()` method exists but has no callers in the changed files. This is pre-existing from Phase 1 and is explicitly noted in CLAUDE.md. Not a regression.

- `TerminalSession.resize(rows:cols:)` has no call site in the changed files (the `.task` block in `ContentView` does not call it). Pre-existing behavior; not a Phase 2 regression.

- `applyAndCurrentTitle(_:)` is called from the `.output` response handler. The result is the window title from the actor hop — but the `windowTitle` field is also on the snapshot. The extra method exists to solve a race described in its doc comment. This is technically redundant with a direct `latestSnapshot().windowTitle` read but is correct per the documented rationale. See Q5.

**Conclusions:** No dead code introduced in Phase 2. Pre-existing `iconName` accumulator without a consumer is known and documented.

---

## Q8: `@discardableResult` consistency

**Method:** Searched all Swift files for `@discardableResult`; checked call sites.

**Findings:**

Three locations on the branch:
1. `ScrollViewState.reconcile(historyCount:)` → `@discardableResult` at `ScrollViewState.swift:35`
2. `ScrollViewState.pageUp(pageRows:historyCount:)` → `@discardableResult` at `ScrollViewState.swift:69`
3. `ScrollViewState.pageDown(pageRows:)` → `@discardableResult` at `ScrollViewState.swift:79`
4. `RenderCoordinator.handlePageUp(view:)` → `@discardableResult` at `RenderCoordinator.swift:130`
5. `RenderCoordinator.handlePageDown(view:)` → `@discardableResult` at `RenderCoordinator.swift:139`

Call sites:
- `RenderCoordinator.draw(in:)` calls `scrollState.reconcile(historyCount:)` and discards the `Bool`. The return value is never used at this call site. Appropriate use of `@discardableResult`.
- `TermView.makeNSView` calls `coordinator.handlePageUp(view:)` and `coordinator.handlePageDown(view:)` and returns the `Bool` to the closure callers. The closure callers (inside `onPageUp`/`onPageDown`) DO use the return value. So `@discardableResult` on `handlePageUp`/`handlePageDown` is technically unnecessary — no call site discards the result. However, it is not incorrect to annotate; it signals "the Bool is informational."
- `ScrollViewState.pageUp` and `pageDown` return values are used by `RenderCoordinator.handlePageUp/Down` to decide whether to call `view.needsDisplay = true`. Appropriate.

The rest of the codebase has no `@discardableResult` annotations. The usage here is consistent with the pattern: annotate when the Bool is informational and the void-use case (e.g., inside `draw(in:)`) is legitimate. No inconsistency.

**Conclusions:** `@discardableResult` usage is correct and consistent. The annotations on `handlePageUp`/`handlePageDown` are technically unnecessary (all callers use the Bool) but are not incorrect.

---

## Q9: Concurrency — `Task { @MainActor in }` unstructured tasks in response handler

**Method:** Read `ContentView.swift` `installResponseHandler`; assessed isolation, cancellation, and Sendable conformance.

**Findings:**

The XPC response handler runs on the XPC queue (outside MainActor). It creates unstructured `Task { @MainActor in ... }` at two places:

1. `.output` case: `Task { @MainActor in self.windowTitle = await screenModel.applyAndCurrentTitle(events) }` — the `events` array (`[TerminalEvent]`) must be `Sendable`. `TerminalEvent` is `Sendable` (it's an enum with only `Sendable`-conforming associated values). `self` captures as `@Sendable` closure capture; `TerminalSession` is `@MainActor`. This is safe.

2. `.attachPayload` case: `Task { @MainActor in await screenModel.restore(from: payload) ... }` — `AttachPayload` must be `Sendable`. The existing code has `AttachPayload: Codable` (it crosses XPC), which implies `Sendable` since all XPC-transmitted types must be. This is safe.

The unstructured `Task {}` pattern here is the correct choice: the XPC response handler is a `@Sendable` closure that cannot be `async`, so `Task { @MainActor in ... }` is the standard bridge from a synchronous `@Sendable` context into the MainActor. `Task.detached` would not inherit the `@MainActor` execution context; the plain `Task { @MainActor in ... }` is correct.

Cancellation: these tasks are not cancelled when the session disconnects. If the daemon sends output after the session ends, the task will apply events to a model that may already be in a terminal state. The existing `sessionEnded` case just logs; it doesn't cancel in-flight tasks. In practice the XPC session closes before the handler is called again, so this is a non-issue at current scale.

**Conclusions:** The concurrency usage is correct. No Sendable violations, no isolation errors, unstructured `Task {}` is the appropriate bridge here.

---

## Q10: DispatchQueue force-cast safety

**Method:** Traced all callers of `ScreenModel.init(queue:)` to verify they pass serial queues.

**Findings:**

`ScreenModel.init` has `queue: DispatchQueue? = nil`. When non-nil, it force-casts to `DispatchSerialQueue`:
```swift
self.executorQueue = q as! DispatchSerialQueue
```

Known callers:
- `TerminalSession.init` (ContentView.swift): passes `nil` → creates a private serial queue internally. Safe.
- `Session.init` (rtermd/Session.swift:123): passes `queue` which comes from `SessionManager` which receives `daemonQueue` from `main.swift`. `daemonQueue = DispatchQueue(label: "com.ronnyf.rtermd.daemon")` — a plain `DispatchQueue(label:)` with no `.concurrent` attribute, which in Foundation is a serial queue, and since `DispatchSerialQueue` is a subclass of `DispatchQueue`, the downcast succeeds at runtime.

The risk: a future caller passes a `DispatchQueue(label: "...", attributes: .concurrent)` — the force-cast crashes at runtime with no compile-time warning. The API takes `DispatchQueue` (the base class) but requires `DispatchSerialQueue` (the subclass). This is a pre-existing issue from Phase 1.

A safer API would accept `DispatchSerialQueue` directly:
```swift
public init(cols: Int = 80, rows: Int = 24, historyCapacity: Int = 10_000,
            queue: DispatchSerialQueue? = nil)
```
This would be source-breaking for the `rtermd` caller only (minor change to `Session.swift` to store the queue as `DispatchSerialQueue`). However, `BUILD_LIBRARY_FOR_DISTRIBUTION` is enabled, so changing the public API signature is a binary-compatibility break for any external consumer — there are none currently, but the flag implies intent.

**Conclusions:** The force-cast is a latent runtime crash risk for API misuse. Changing the parameter type to `DispatchSerialQueue` would make it safe at compile time but requires a binary-compatible API change path (add a new `init` with the typed parameter, deprecate the old one). Pre-existing from Phase 1; not introduced by Phase 2. Flagged as Important for Phase 3.

---

## Summary Table

| # | Severity | File(s) | Issue | Action |
|---|----------|---------|-------|--------|
| 1 | Suggestion | `TermCore/ScreenSnapshot.swift` | 12-param init — extract `TerminalStateSnapshot` sub-struct | Phase 3 |
| 2 | Suggestion | `TermCore/ScreenModel.swift` | 941 lines — candidate for file split | Phase 3 |
| 3 | Suggestion | `TermCore/ScreenModel.swift` | `publishHistoryTail()` lacks ordering-invariant doc comment | Phase 3 |
| 4 | Important | `rTerm/ContentView.swift` | Misleading comment about `windowTitle` cleanup ("Task 7 eliminates race") contradicts actual code | Fix before merge or Phase 3 |
| 5 | Suggestion | `rTerm/TermView.swift:192` | Stale "e.g. T10's scroll handlers" task reference in doc comment (T10 already landed) | Fix before merge |
| 6 | Important | `TermCore/ScreenModel.swift:216` | `DispatchQueue` → `DispatchSerialQueue` force-cast: latent runtime crash if caller passes concurrent queue | Phase 3 API hardening |
| 7 | Suggestion | All deferred refactors | `Cursor.zero`, `ImmutableBox<T>`, `mutateMode` helper, `screenModelForView` rename, file split | Phase 3 |
| 8 | Info | `TermCore/CircularCollection.swift:53` | Pre-existing TODO (not Phase 2 regression) | Separate backlog |
| 9 | Info | `TermCoreTests/ScreenModelTests.swift` | No test for `restore(from payload:)` clear-before-publish ordering invariant | Phase 3 |
| 10 | Info | `rTermTests/*` | `bracketedPasteWrap` tested but full `TerminalSession.paste(_:)` wiring not tested | Phase 3 |

---

*Generated by: branch-wide cross-task quality review, 2026-05-01*
