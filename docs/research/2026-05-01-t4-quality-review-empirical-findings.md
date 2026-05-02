# T4 Quality Review: Empirical Findings

Date: 2026-05-01

## 1. Does `handleAltScreen`'s `default` arm constitute dead code?

**Question:** `handleSetMode` routes only `.alternateScreen47`, `.alternateScreen1047`,
`.alternateScreen1049`, and `.saveCursor1048` to `handleAltScreen`. Can the `default: return false`
arm ever execute?

**Method:** Read `ScreenModel.swift` lines 629–634 (routing in `handleSetMode`) and lines 639–706
(`handleAltScreen` switch). Verified that all four cases are exhaustive against the routed set.
Checked whether `DECPrivateMode` is a frozen enum using `grep -n "DECPrivateMode" TermCore/*.swift`.

**Findings:**
- `handleSetMode` routes exactly four cases to `handleAltScreen`. The switch in `handleAltScreen`
  enumerates the same four cases. Swift will compile this without warning on a non-exhaustive switch
  only if there is a `default` (or equivalent).
- `DECPrivateMode` is not declared `@frozen`. It is defined in `TermCore`, which has
  `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` — meaning SourceKit/Swift emit exhaustiveness diagnostics
  treating non-frozen public enums as non-exhaustive. If the enum gains a new case in a future task
  (e.g. a mode-save stack in T5 or beyond), the `default` arm catches it safely.
- Practically speaking, the `default` is dead code today — `handleAltScreen` is private and only
  called from the four-case branch. But it is defensive, not harmful, and required to compile
  without exhaustiveness warnings.

**Conclusions:** The `default` arm is today-dead but defensively correct. It is the right pattern
for a non-frozen enum routed through a private helper. Not an issue.

---

## 2. Is the `mutateActive` return value from the `saveCursor1048` enabled branch discarded silently?

**Question:** `mutateActive { buf in buf.savedCursor = buf.cursor }` at line 646 returns `Void`
(via `mutateActive<R>` where R is inferred as `Void`). Is the return value discarded?

**Method:** Read `mutateActive` signature (line 137) and the call at line 646. `mutateActive` is
generic over `R`. The closure `{ buf in buf.savedCursor = buf.cursor }` has return type `Void`.
So `mutateActive` returns `Void`. The call site does not assign the result, which is standard Swift
practice for Void-returning functions. There is no `@discardableResult` annotation needed for this
case because `Void` is not a "discardable result" — it carries no information.

**Findings:** The pattern is correct. No warning and no logic error.

**Conclusions:** Not an issue.

---

## 3. Does 1049 enter correctly write `main.savedCursor` directly rather than via `mutateActive`?

**Question:** The 1049 enter path at lines 685–690 writes `main.savedCursor = main.cursor` directly.
Is this safe? Could it write the wrong buffer if `activeKind` were somehow `.alt` already?

**Method:** Read lines 684–690. The `guard activeKind != .alt else { return false }` fires before
the write, so execution only continues when `activeKind == .main`. Therefore `main.cursor` is the
active buffer's cursor at this point and the direct write is correct.

**Findings:** The guard before the direct `main.savedCursor` write makes the logic safe. If the
guard were absent, a second `1049 enter` while already on alt would still be prevented by the guard
(it returns false), so in practice this path is unreachable from alt. The implementation is
correct but marginally harder to reason about than using `mutateActive` — because the caller must
mentally note "at this point activeKind == .main is guaranteed by the guard."

**Conclusions:** Correct. Mildly surprising (not using `mutateActive` for a per-buffer property) but
the guard makes it safe. A comment noting the guard is what makes the direct access safe would
improve readability; the existing comment does not call this out explicitly.

---

## 4. Would `clearAltGrid()` be correct if called while alt is active?

**Question:** `clearAltGrid` writes `alt.grid` directly. If the caller has already switched
`activeKind = .alt`, does this still clear the visible buffer?

**Method:** Trace the 1047 enter path (lines 667–671): `activeKind = .alt` then `clearAltGrid()`.
After the switch, `alt` IS the active buffer. `clearAltGrid` writes `alt.grid` directly —
the same buffer that `mutateActive` would route to. The result is identical.

For 1049 enter (lines 684–690): `activeKind = .alt` then `clearAltGrid()` then `alt.cursor = ...`.
Same result: directly writing `alt.grid` is the active buffer.

**Findings:** Calling `clearAltGrid()` after `activeKind = .alt` is consistent. It clears the
visible (alt) buffer. The implementation is correct in both orderings used in the code.

**Conclusions:** Not an issue. The specialization to `alt` is intentional and correct: alt-grid
clearing always targets the alt buffer by design (no mode clears main via this path).

---

## 5. Test structure: table-of-similar-shape risk in the 9 alt-screen tests?

**Method:** Read `ScreenModelAltScreenTests` lines 656–893. Categorized each test by the thing
it proves:
1. `test_alt_screen_1049_enter` — enter semantics + grid clear + pen persistence
2. `test_alt_screen_1049_exit_restores_main` — exit semantics + cursor restore + re-entry clear
3. `test_alt_screen_1047_cursor_persists_across_re_entry` — 1047 cursor-persistence invariant
4. `test_alt_screen_47_legacy` — 47 no-clear legacy behavior
5. `test_save_cursor_1048` — 1048 save/restore basic
6. `test_save_cursor_1048_per_buffer` — 1048 per-buffer isolation
7. `test_save_restore_cursor_csi_s_u` — CSI s/u via `.csi(.saveCursor)` events
8. `test_esc_7_8_save_restore` — ESC 7/8 byte-level path
9. `test_save_restore_per_buffer` — combined save slot clobber semantics

**Findings:** Each test covers a distinct behavioral dimension. No two tests assert the same thing.
Tests 5+6 are the closest pair (both about 1048) but test 6 specifically targets the per-buffer
isolation property that test 5 doesn't cover. Tests 7+8 both test save/restore but via different
event-delivery paths (CSI event vs. raw bytes), which is meaningful (parser integration). Tests 2
and 9 overlap slightly on 1049 exit cursor restoration but test 9 also covers the slot-clobber
semantic that test 2 doesn't.

**Conclusions:** No redundant tests. Test count is proportional to behavioral surface. No "table of
similar shape" smell.

---

## 6. Do any tests share enough setup to merit extraction into a helper?

**Method:** Compare initialization patterns across the 9 tests. Most tests create a fresh
`ScreenModel(cols: N, rows: M)` with small dimensions, apply a short preamble, then assert.
Dimensions vary: (5,3), (4,2), (3,2), (80,24). No shared preamble state.

**Findings:** The setup is minimal (one `ScreenModel` init + 0–2 `apply` calls). Extracting a
helper would save 1–2 lines per test at the cost of indirection. Given Swift Testing's design
philosophy (each `@Test` is independent and readable in isolation), the current pattern is
preferable.

**Conclusions:** No shared helper needed or beneficial.

---

## 7. Integration test: is the `vimStartupSequence` comment still stale after the T4 rename commit?

**Method:** Read `TerminalIntegrationTests.swift` lines 44–54 and 104–115.

**Findings:**
- Lines 44–54: `vimStartupSequence` doc-comment was updated in the stale-comment amend to describe
  post-T4 behavior. The comment accurately describes what the sequence does in T4.
- Lines 104–115: `vim_startup_lands_in_alt_buffer_with_homed_cursor` body comment was also updated.
  The body comment now correctly describes Phase 2 semantics.

**Conclusions:** Both comments are accurate post-amend. No stale Phase 1 language remains in the
integration test file.

---

## 8. Does `handleAltScreen` miss a `clampCursor` call on 1049 exit?

**Question:** 1049 exit at lines 691–702 restores `main.cursor = main.savedCursor` and then calls
`clampCursor(in: &main)`. Is `clampCursor` called correctly here (directly on `main` vs. via
`mutateActive`)?

**Method:** Read lines 696–701. `clampCursor(in: &main)` is called directly. The call site is
outside `mutateActive`. Verified `clampCursor` signature in `ScreenModel.swift` to confirm it
takes an `inout Buffer` and operates purely on that buffer.

**Findings:** `clampCursor` is a pure function over `inout Buffer`. Calling it on `&main` directly
is equivalent to calling it inside a `mutateActive` closure when `activeKind == .main`. At this
point in the 1049 exit path, `activeKind = .main` has just been set (line 696), so the direct call
is correct.

**Conclusions:** Correct. Direct call mirrors the same pattern used in `test_alt_screen_1049_exit_restores_main`.
