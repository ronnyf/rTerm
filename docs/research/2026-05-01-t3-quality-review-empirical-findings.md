# T3 Code-Quality Review — Empirical Findings

Date: 2026-05-01
Commit: 373364c
Reviewer: Claude Sonnet 4.6 (code-quality pass)

---

## 1. `@frozen` on `TerminalModes` — is it justified?

**Question:** Phase 3 adds DECNKM, DECCOLM, mouse modes, and more. Is `@frozen` safe for `TerminalModes`?

**Method:** Read `TermCore/TerminalModes.swift`, the project spec (`docs/superpowers/specs/2026-04-30-control-characters-design.md` lines 125–130), and the Phase 2 plan (`docs/superpowers/plans/2026-05-01-control-chars-phase2.md` lines 841–857). Cross-checked against existing `@frozen` annotations (rg search on repo).

**Findings:**
- `TerminalModes` is a `struct`, not an enum. For structs `@frozen` means "no stored properties will be added." Adding a new field (e.g., `mouseMode: MouseMode`) to a `@frozen public struct` in a module built with `BUILD_LIBRARY_FOR_DISTRIBUTION` is an ABI break.
- The spec's `@frozen` policy (`docs/superpowers/specs/…design.md:127`) lists only closed-by-VT-spec **enums** as `@frozen` candidates: `C0Control`, `EraseRegion`, `BufferKind`, `ColorRole`, `CellAttributes`. `TerminalModes` is not listed.
- The plan (`…phase2.md:841`) prescribes `@frozen public struct TerminalModes` verbatim — the struct was intentionally frozen by the plan author.
- However, Phase 3 and T9/T10 need DECNKM (keypad mode) at minimum, and mouse tracking modes add further fields. Freeze precludes those additions without an ABI break.
- Existing `@frozen struct` precedents: `CellAttributes` (OptionSet, VT-spec-closed), `CellStyle` (implicit: not `@frozen`). `TerminalModes` has no closed-set guarantee.

**Conclusion:** `@frozen` on `TerminalModes` conflicts with the project's own spec annotation policy and with the known Phase 3 roadmap. It should be removed. Since `BUILD_LIBRARY_FOR_DISTRIBUTION` is only enabled in Release, the cost of resilience overhead here is one extra indirection on 4 Bool reads — negligible.

---

## 2. `handleSetMode` — comment/code mismatch on `autoWrap` return value

**Question:** The doc-comment on `handleSetMode` (ScreenModel.swift:612–619) says it returns `false` for `autoWrap`; the implementation at line 625 returns `true`. Which is correct?

**Method:** Read `ScreenModel.swift` lines 612–625.

**Findings:**
- Doc-comment line 614–616: "Returns `false` when the change is invisible (autoWrap toggle — affects future handlePrintable behavior but not the current snapshot)."
- Implementation line 625: `return true   // snapshot.autoWrap reflects the change → bump version.`
- `ScreenSnapshot` does carry `autoWrap` as a field (line 65 of ScreenSnapshot.swift); `publishSnapshot()` reads `modes.autoWrap` (line 239). So `return true` is correct — the snapshot is affected.
- The doc-comment is stale/wrong; the inline comment on line 625 is correct.

**Conclusion:** The doc-comment is misleading. It describes the **pre-Phase-2** intent (where DECAWM wasn't reflected in the snapshot); the implementation was updated but the doc-comment wasn't. Issue severity: Important (misleads future maintainers about whether DECAWM changes bump the version).

---

## 3. `bellIsNoOp` test — name vs. behavior

**Question:** `ScreenModelTests.bellIsNoOp` (line 167) — does the name reflect what bell does in T3?

**Method:** Read the test at lines 167–175. Read `handleC0` in ScreenModel.swift at lines 278–281.

**Findings:**
- Test name: `bellIsNoOp`
- Test body: applies bell, then asserts that cursor and cell contents are unchanged ("A" and "B" at expected positions). It does not check `bellCount` at all.
- T3 wires `bellCount &+= 1` in `handleC0(.bell)` — bell is explicitly not a no-op; it increments the counter and bumps the version.
- A separate test `test_bell_increments_count` (line 599) correctly covers the bell counter.
- The `bellIsNoOp` name was accurate in Phase 1 when bell was a no-op; it is now a misnomer. The test's assertions are still valid (bell doesn't move the cursor) but the name misleads readers.

**Conclusion:** The test name is stale and actively misleading now that bell has semantics. Should be renamed (e.g., `bell_does_not_move_cursor_or_affect_grid`).

---

## 4. `BufferKind: String` — implicit vs. explicit raw values

**Question:** Is `case main` → `"main"`, `case alt` → `"alt"` safe to rely on without explicit raw value assignments?

**Method:** Read `ScreenSnapshot.swift` lines 42–45. Check Swift language spec behavior for `String` raw value enums.

**Findings:**
- Swift guarantees that for `enum Foo: String`, cases without an explicit raw value use the case name as the raw value. `case main` → `"main"`, `case alt` → `"alt"` is language-specified, not implementation-dependent.
- Existing test `test_snapshot_decodes_phase1_payload` (CodableTests.swift:266) encodes `"activeBuffer": "main"` and decodes successfully, confirming the mapping.
- Explicit raw values (`case main = "main"`) would add zero semantic value but would make the contract visible in a quick scan without knowing the Swift enum rule.
- The Phase 2 plan added `String` raw type to `BufferKind` specifically for cleaner JSON (`"main"`/`"alt"` vs integer indices). The implicit mapping is correct and idiomatic.

**Conclusion:** The implicit mapping is fine. Explicit raw values are a minor style preference only. No defect.

---

## 5. `decodeIfPresent ?? true` for `autoWrap` — correctness of default

**Question:** Phase 1 payloads didn't have `autoWrap`. The decoder defaults to `true`. Does this match VT power-on state?

**Method:** VT100/VT220 standards define DECAWM as enabled by default (power-on reset state). Confirmed by xterm source documentation.

**Findings:**
- VT power-on state: DECAWM = set (enabled). `?? true` is correct.
- A Phase 1 snapshot represents a session that never explicitly disabled DECAWM, so defaulting to `true` is the only safe interpretation — it prevents a client re-attaching to a Phase 1 session from incorrectly disabling auto-wrap for a shell that has it on.

**Conclusion:** `?? true` is correct and the commit message explains the rationale clearly.

---

## 6. `restore(from:)` — savedCursor not seeded

**Question:** Does `restore(from:)` correctly handle `savedCursor`? Does the snapshot carry it?

**Method:** Read `ScreenModel.swift` lines 473–508. Read `Buffer` struct (lines 119–131). Read `ScreenSnapshot` fields (ScreenSnapshot.swift lines 54–66).

**Findings:**
- `ScreenSnapshot` does not carry `savedCursor` — it is per-buffer state that is intentionally not serialized (Phase 2 plan notes this).
- `restore(from:)` creates a fresh `seeded = Buffer(...)` and sets `seeded.cursor = snapshot.cursor`. `savedCursor` on `seeded` is `nil` (default from `Buffer.init`), which is correct — a restored session starts with no saved cursor position.
- Nothing is dropped; the existing `savedCursor` on the pre-restore model is discarded by replacing the entire `Buffer`, which is the correct behavior.

**Conclusion:** `restore(from:)` is correct with respect to `savedCursor`.

---

## 7. Forward-signpost comments ("T4 wires this", "T6 will add")

**Question:** Are T4/T5/T6/T9 forward-signpost comments useful or noise?

**Method:** rg search for "T4\|T5\|T6\|T7\|T8\|T9" in ScreenModel.swift.

**Findings:** Comments appear at:
- `ScreenModel.swift:79` — "Persists across buffer swap (T4)"
- `ScreenModel.swift:384` — "// T5 wires .setScrollRegion."
- `ScreenModel.swift:619` — "in T4; in this task they fall through to `false` (no-op)."
- `ScreenModel.swift:597` — "T6 will add a history-feed path"
- `ScreenModel.swift:641` — "// T4 wires these."

These are useful because the task numbering matches the plan document in `docs/superpowers/plans/`; a developer reading the code can immediately cross-reference the plan to understand why a case no-ops. They are not noise in this codebase.

**Conclusion:** Signpost comments are valuable given the structured task plan. No action needed.

---

## 8. `handleSetMode` — 4 copy-paste guards vs. single helper

**Question:** Are the 4 idempotent `guard X != enabled; X = enabled; return true` blocks worth extracting?

**Method:** Read ScreenModel.swift lines 621–637. Count lines of repetition.

**Findings:**
- Each arm is 3 lines. The 4 arms total 12 lines of nearly identical code.
- A helper `mutateMode(_ kp: WritableKeyPath<TerminalModes, Bool>, enabled: Bool) -> Bool` would reduce that to 4 single-line call sites.
- However: (a) the `switch` structure is already clear; (b) the compiler inlines trivially; (c) alt-screen modes and `.unknown` need custom fall-through anyway; (d) Phase 3 will add new cases that may not fit the `Bool` pattern (e.g., mouse mode as an enum).
- The extraction is a legitimate refactor but is not a correctness or clarity problem at the current scale.

**Conclusion:** Suggestion-level. Not worth blocking on.

---

## 9. Test coverage gaps

**Question:** Do the 8 new mode tests cover sufficient cases?

**Method:** Read `ScreenModelModeTests` (ScreenModelTests.swift:545–634).

**Findings:**
- DECAWM-off: `test_decawm_off_overwrites_last_column` — good; tests actual render behavior, not just flag state.
- DECTCEM-off: `test_dectcem_off` — tests snapshot field only. No test for re-enable (toggle back on).
- DECCKM-on: `test_decckm_on` — tests snapshot field only. No test for DECCKM-off.
- Bracketed paste on: `test_bracketed_paste_on` — tests snapshot field only. No test for off.
- Idempotent toggle: `test_mode_toggle_idempotent` — covered with DECCKM. Good.
- Bell single: `test_bell_increments_count` — covered.
- Bell batch: `test_bell_batch_count` — covered.
- restore preserves modes + bell: `test_restore_preserves_modes_and_bell` — covered for cursorKeyApplication + bracketedPaste + bellCount. autoWrap not tested in this restore test.
- Missing: no test for DECAWM re-enable after DECAWM-off (verify wrap resumes). No test for version bump on autoWrap toggle specifically.

**Conclusion:** Coverage is adequate for the happy path; toggle-back tests are absent. Important-level gap for DECAWM re-enable; the others are suggestions.
