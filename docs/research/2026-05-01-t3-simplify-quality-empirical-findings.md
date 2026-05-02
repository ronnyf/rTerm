# T3 Simplify Pass — Empirical Findings

**Date:** 2026-05-01
**Commit:** ed1b63f
**Reviewer:** Claude Sonnet 4.6 (simplify / second-pass review)
**Files read:** TermCore/TerminalModes.swift, TermCore/ScreenSnapshot.swift, TermCore/ScreenModel.swift,
TermCoreTests/ScreenModelTests.swift, TermCoreTests/CodableTests.swift, rTerm/ContentView.swift,
rTerm/TermView.swift, plus prior empirical docs.

---

## 1. Redundant state — can `modes.*` or `bellCount` be derived?

**Question:** Is `bellCount` or any mode flag redundant / derivable from other state?

**Method:** Traced all write paths for `modes` and `bellCount` in ScreenModel.swift. Surveyed snapshot consumers (rg across rTerm/ and rtermd/).

**Findings:**
- `bellCount` is monotonically incremented on every `.bell` C0 event. There is no other source of truth for "how many bells arrived." The renderer (T9) is designed to observe *deltas* between successive snapshots. The count cannot be derived from anything else on the snapshot — it is the sole carrier of bell-delivery state.
- `modes` fields are set only by `handleSetMode`, which is driven by parsed CSI sequences. They are not redundant with anything on `ScreenSnapshot` (the snapshot fields mirror them, and those mirrors are the whole point — they make modes reachable to `nonisolated` callers and across XPC via `restore(from:)`).
- No T3-snapshot field is derivable from any other field.

**Conclusion:** No redundant state. All four new `ScreenModel` fields serve distinct, non-derivable roles.

---

## 2. `TerminalModes` — public `var` fields: leaky abstraction?

**Question:** Should `TerminalModes.autoWrap`, `cursorVisible`, etc. be `public let` or `private(set)` to prevent external mutation?

**Method:** rg search for any direct field writes to a `TerminalModes` value outside `ScreenModel.swift`. Checked rTerm/, rtermd/, TermCoreTests/.

**Findings:**
- External access: zero direct field writes found outside ScreenModel.swift. Tests drive modes through `model.apply([.csi(.setMode(...))])` only — they never touch `TerminalModes` fields directly.
- `TerminalModes` is a value type (`struct`). External code that holds a `TerminalModes` value can mutate its own copy without affecting the actor's `modes`. The only way to mutate the actor's `modes` is through actor-isolated methods on `ScreenModel`.
- `BUILD_LIBRARY_FOR_DISTRIBUTION` is enabled for TermCore Release, so `public var` is part of the ABI. Changing to `private(set)` would reduce the API surface (callers can no longer write through snapshot-derived copies) and is a non-breaking ABI change for a value type if done as an additive restriction. However, making the fields `public private(set)` would still require a `public init` to set them, which already exists.
- Practical risk: extremely low. The fields being `public var` on a `struct` does not provide any path to mutate the actor's authoritative state. A caller who writes `var copy = modes; copy.autoWrap = false` only mutates their local copy.

**Conclusion:** The `public var` fields are not a material leaky abstraction because `TerminalModes` is a value type and the actor's copy is unreachable from outside. `public private(set)` would be more principled and communicates intent, but this is a suggestion-level concern only, not a safety issue.

---

## 3. `handlePrintable` — `let pen = self.pen` and `let autoWrap = modes.autoWrap` captures

**Question:** Are these two local variable captures necessary, or superfluous like the T2 `pen` capture that was previously removed?

**Method:** Read `handlePrintable` (ScreenModel.swift lines 247–272). Analyzed what `mutateActive` closure captures vs. what it needs. Compared with the T2 context where `pen` was removed.

**Findings:**
- `mutateActive(_:)` takes a `(inout Buffer) -> R` closure. It does NOT carry `@Sendable`; it executes synchronously within the same actor-isolated function call. There is no suspension point, no crossing of isolation boundaries.
- For a **synchronous, non-escaping** closure on an actor, Swift 6 allows the closure to capture actor-isolated state directly — the actor's isolation is maintained throughout. There is no data race risk.
- `let pen = self.pen` — `pen` is a `CellStyle` (value type). The closure captures it to write `Cell(character: char, style: pen)`. This capture is **not necessary** for correctness: the closure could reference `self.pen` directly (it's already actor-isolated). The capture was present in T2 and was apparently left over in T3 for the DECAWM work. It is superfluous.
- `let autoWrap = modes.autoWrap` — same analysis. `modes` is actor-isolated state. The closure is non-escaping and synchronous. There is no isolation boundary crossing. `modes.autoWrap` can be read directly inside the closure as `self.modes.autoWrap`. The capture is **not necessary**.
- Neither capture is harmful (no semantic difference, no performance impact). But together they establish a style convention that implies "we must always capture actor state before entering mutateActive" — which is false and will confuse future maintainers, especially since the T2 review explicitly removed a redundant `pen` capture.

**Conclusion:** Both captures in `handlePrintable` are superfluous. The prior T2 review removed `pen` from other handlers for exactly this reason. This handler re-introduced both. Suggestion-level (no correctness issue), but inconsistent with the T2 clean-up.

---

## 4. `ScreenSnapshot.init` parameter sprawl (11 parameters)

**Question:** Is the 11-parameter init getting unwieldy? Should it use a builder or sub-struct?

**Method:** Counted parameters on the current `ScreenSnapshot.init`. Checked all call sites (rg for `ScreenSnapshot(` across the codebase).

**Findings — parameter count:**
`activeCells`, `cols`, `rows`, `cursor`, `cursorVisible`, `activeBuffer`, `windowTitle`, `cursorKeyApplication`, `bracketedPaste`, `bellCount`, `autoWrap`, `version` = **12 parameters** (version lacks a default, so it is always required).

**Findings — call sites:**
- `ScreenModel.init` (line 170) — inlined literal, all 12 named explicitly with defaults
- `ScreenModel.publishSnapshot` (line 228) — 12 named parameters from live actor state
- `ScreenModel.snapshot()` (line 520) — identical structure to `publishSnapshot`
- `TermCoreTests/CodableTests.swift` (round-trip test) — 12 named
- `TermCoreTests/DaemonProtocolTests.swift` — uses subset with defaults

**Duplication between `publishSnapshot` and `snapshot()`:**
The two call sites are structurally identical — both read the same fields in the same order from `modes` and `bellCount`. If `ScreenSnapshot` grew another field, both would need to be updated in lockstep. This is the real maintenance risk, not the parameter count per se.

**Builder vs sub-struct analysis:**
- A `TerminalStateSnapshot` sub-struct grouping `{cursorVisible, cursorKeyApplication, bracketedPaste, autoWrap, bellCount}` would reduce the init to 8 parameters and let `restore(from:)` pass a single value instead of unpacking 5 fields. However, it would also partition the Codable keys, requiring a nested container, which makes the backward-compat decode (which must read Phase 1 flat JSON) significantly more complex.
- A builder pattern adds boilerplate without reducing complexity at this scale.

**Conclusion:** The sprawl is uncomfortable at 12 but not an actionable problem today. The more practical issue is the two structurally identical init call sites (`publishSnapshot` and `snapshot()`). Extracting a private `makeSnapshot(buf:)` helper that captures all 12 params once would eliminate the lockstep update risk. Suggestion-level for now; if Phase 3 adds 2–3 more fields it becomes Important.

---

## 5. Copy-paste pattern — 4 arms in `handleSetMode`

**Question:** Is the 4-arm idempotent pattern in `handleSetMode` worth extracting to a `mutateMode` key-path helper now?

**Method:** Read ScreenModel.swift lines 617–642. Evaluated the shape of future arms (alt-screen modes, DECNKM, mouse modes).

**Findings:**
- All 4 `Bool` mode arms have the same 3-line pattern: `guard X != enabled else { return false }; X = enabled; return true`.
- A `WritableKeyPath<TerminalModes, Bool>` helper could collapse this to 1 line each:
  `mutateMode(\.autoWrap, enabled: enabled)`.
- Counterarguments: (a) the `switch` already provides the semantic name at each arm; (b) alt-screen and `.unknown` arms need different return logic anyway; (c) Phase 3 mouse modes are likely to be non-`Bool` (enum-valued), so a key-path-to-Bool helper won't generalize.
- The 12 lines of repetition are not a correctness hazard.

**Conclusion:** Suggestion-level. The extraction is clean but not urgent. Revisit when Phase 3 adds more Bool arms.

---

## 6. Copy-paste in `init(from:)` — 4 `decodeIfPresent ?? default` lines

**Question:** Are the 4 backward-compat decode lines worth abstracting?

**Method:** Read ScreenSnapshot.swift lines 127–130.

**Findings:**
- The 4 lines are structurally identical: `self.X = try container.decodeIfPresent(T.self, forKey: .X) ?? defaultValue`.
- A helper `container.decodeOptional(_:forKey:default:)` could be written as a `KeyedDecodingContainer` extension, but Swift does not have a direct way to make `?? value` more concise without a wrapper.
- These 4 lines are standard "backward-compat with missing keys" Codable pattern; they're readable and familiar. The repetition is not problematic at this count.

**Conclusion:** No action needed. The pattern is idiomatic and clear.

---

## 7. Inline comment in `handlePrintable` — "xterm DECAWM-off semantics"

**Question:** Does the 4-line inline comment block at lines 262–266 earn its keep, or is it narrating the obvious?

**Method:** Read the comment in context (ScreenModel.swift lines 262–269). Assessed whether the logic is self-evident from the code.

**Findings:**
The comment block reads:
```
// With autoWrap on, advance unconditionally (the deferred-wrap guard
// at the top of the next call will resolve col == cols).
// With autoWrap off (DECAWM-off), stop at cols-1 so the cursor never
// exceeds the grid boundary and subsequent writes keep overwriting that
// last column — xterm DECAWM-off semantics.
```
The corresponding code:
```swift
if autoWrap || buf.cursor.col < cols - 1 {
    buf.cursor.col += 1
}
```
Assessment: the comment is not narrating the obvious. The condition `autoWrap || buf.cursor.col < cols - 1` encodes two independent semantics in one expression in a non-obvious way (why `cols - 1` rather than `cols`? why `||` rather than two separate `if` blocks?). Without the comment, a reader would need to know the deferred-wrap convention and DECAWM semantics to reconstruct the intent. The comment earns its keep.

The inline comment on `.bell` (line 280: "snapshot includes bellCount; renderer observes delta") is a single-line pin pointing forward to T9 — useful.

**Conclusion:** Both comments are earning their keep. No changes needed.

---

## 8. Forward-reference comments ("T4 wires these", "T6 will add")

**Question:** Are task-number signposts still useful or noise after the first-pass review?

**Method:** rg search for T4/T5/T6/T7/T8/T9 in ScreenModel.swift.

**Findings (8 occurrences total):**
- Line 61 (Buffer doc): "alt-screen swap (Phase 2 T4) only flips the selector" — architectural context for the dual-buffer design.
- Line 79 (modes doc): "Persists across buffer swap (T4)" — cross-reference.
- Line 84 (bellCount doc): "Renderer side (T9) observes deltas" — forward wire description for T9.
- Line 385 (setScrollRegion no-op): "T5 wires .setScrollRegion." — 3 words, direct.
- Line 438 (.scrollback): ".scrollback is handled in T6 once history exists" — explains intentional stub.
- Line 595–596 (scrollUp doc): "T6 will add a history-feed path" — explains intentional data discard.
- Line 615–616 (handleSetMode doc): "Returns false for ... alt-screen modes (T4)" — explains no-op.
- Line 637 (alt-screen arm): "// T4 wires these." — explains no-op.

All 8 references cross-index with `docs/superpowers/plans/2026-05-01-control-chars-phase2.md`. They are navigational aids, not noise. The first-pass review confirmed the plan numbering is stable.

**Conclusion:** All forward-reference comments are appropriate and useful. No changes.

---

## 9. Test naming — behavior vs. implementation

**Question:** Do new mode test names describe behavior or implementation? Are they consistent with the codebase style?

**Method:** Listed all new @Test function names (grep on ScreenModelTests.swift). Compared with pre-existing test naming in the same file.

**Findings — new tests:**
- `test_decawm_off_overwrites_last_column` — behavior-named. Good.
- `test_decawm_reenable_wraps` — behavior-named. Good.
- `test_dectcem_off` — implementation-named (references the mode code, not the behavior). The behavior is "cursor becomes hidden" but the test only checks `snap.cursorVisible == false`, which *is* the behavior from the caller's perspective. Acceptable; "off" maps directly to the observable effect.
- `test_decckm_on` — same analysis as above. Borderline.
- `test_bracketed_paste_on` — implementation-named but maps directly to one observable fact.
- `test_mode_toggle_idempotent` — behavior-named ("idempotent toggle"). Good.
- `test_bell_increments_count` — behavior-named. Good.
- `test_bell_batch_count` — behavior-named. Good.
- `test_restore_preserves_modes_and_bell` — behavior-named. Good.

Pre-existing style in the file: a mix of bare `func bellIsNoOp()` (old style, now renamed) and underscore-separated snake_case behavior names for T3. No inconsistency within the T3 block.

The `@Test("...")` string labels on the behavioral ones are clear and would appear in test reports. `test_dectcem_off` and `test_decckm_on` lack string labels; their behavior can be inferred from the name but a string label would improve test output readability.

**Conclusion:** Naming is generally good. `test_dectcem_off` and `test_decckm_on` are the weakest two names — they describe the mode toggle, not the effect. Suggestion-level.

---

## 10. Test duplication — `test_decawm_off_overwrites_last_column` vs `test_decawm_reenable_wraps`

**Question:** Do these two tests share enough setup to warrant a fixture?

**Method:** Read both tests (lines 547–577). Compared setup structure.

**Findings:**
- `test_decawm_off_overwrites_last_column`: 5×3 grid; applies 7 characters; checks row content string + cursor row.
- `test_decawm_reenable_wraps`: 3×2 grid; applies 5 chars off, then 1 on; checks cursor row before and after.
- The setup differs: grid size differs (5×3 vs 3×2), character sequence differs, assertions differ. The only common prefix is `ScreenModel(cols:rows:)` + `apply(.setMode(.autoWrap, false))`.
- A fixture saving 2 lines per test would obscure why each test uses a different grid size. The size choices are semantically important (e.g., 5-wide to clearly distinguish the overwrite cell).
- Codebase convention (confirmed by T2 tests) favors independent, fully self-contained tests over fixtures that save a few lines.

**Conclusion:** No fixture needed. The tests are appropriately independent. The setup duplication is intentional and correct.

---

## 11. `test_restore_preserves_modes_and_bell` — autoWrap not verified

**Question:** The restore test checks `cursorKeyApplication`, `bracketedPaste`, and `bellCount` but not `autoWrap`. Is this a gap?

**Method:** Read test at ScreenModelTests.swift lines 633–648.

**Findings:**
- The snapshot passed to `restored.restore(from: snap)` was built from a model that never changed `autoWrap` — so `snap.autoWrap == true` (the default), and after restore `restoredSnap.autoWrap` would also be `true`.
- Checking `restoredSnap.autoWrap == true` after restoring from a snapshot where it was never changed is not a meaningful assertion: it would pass even if `restore(from:)` completely ignored the `autoWrap` field (because the freshly constructed model also starts with `autoWrap == true`).
- The meaningful assertion would be: set `autoWrap = false` in the original model before building the snapshot, then verify `restoredSnap.autoWrap == false` after restore.
- The behavioral test `test_decawm_reenable_wraps` implicitly exercises `autoWrap` propagation but from `handleSetMode`, not from `restore(from:)`.
- This is the same gap noted in the prior empirical document (section 9, "autoWrap not tested in this restore test").

**Conclusion:** The restore test does not validate that `restore(from:)` correctly seeds `modes.autoWrap = false` when the snapshot has `autoWrap = false`. This is an Important gap — the restore path could silently ignore `autoWrap` and all existing tests would still pass.
