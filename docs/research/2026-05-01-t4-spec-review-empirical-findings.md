# T4 Spec Review: Empirical Findings

Date: 2026-05-01

## 1. handleAltScreen logic — does it match spec lines 1530–1604?

**Method:** Read `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift` lines 600–714. Cross-referenced against plan lines 1530–1611.

**Findings:**

- `.saveCursor1048` enabled: `mutateActive { buf.savedCursor = buf.cursor }`, returns `false`. Matches spec exactly.
- `.saveCursor1048` disabled: `mutateActive { guard let saved = buf.savedCursor else { return false }; buf.cursor = saved; clampCursor(in: &buf); return true }`. Matches spec exactly.
- `.alternateScreen47`: bare `activeKind` toggle, no clear, no cursor save/restore, idempotency guard. Matches spec exactly.
- `.alternateScreen1047` enter: guard `activeKind != .alt`, switch, `clearAltGrid()`, return true. Cursor untouched. Matches spec exactly.
- `.alternateScreen1047` exit: guard `activeKind == .alt`, `clearAltGrid()` BEFORE switch (correct order per spec comment), switch to main, return true. Alt cursor NOT touched — persists across re-entry. Matches spec exactly.
- `.alternateScreen1049` enter: guard `activeKind != .alt`, `main.savedCursor = main.cursor`, switch, `clearAltGrid()`, `alt.cursor = Cursor(row:0, col:0)`, return true. Matches spec exactly.
- `.alternateScreen1049` exit: guard `activeKind == .alt`, `clearAltGrid()`, switch, restore `main.cursor = main.savedCursor` with clamp. Matches spec exactly.
- `default`: return false. Matches spec exactly.

**Conclusions:** `handleAltScreen` is a line-for-line match with the plan spec pseudo-code.

---

## 2. clearAltGrid — spec compliance

**Method:** Read `ScreenModel.swift` lines 709–713.

**Findings:** Only touches `alt.grid`. Does NOT touch `alt.cursor`.

**Conclusions:** Matches spec requirement "Cursor is left untouched (callers reset)."

---

## 3. handleSetMode hook — is routing correct?

**Method:** Read `ScreenModel.swift` lines 629–631.

**Findings:**

```swift
case .alternateScreen47, .alternateScreen1047,
     .alternateScreen1049, .saveCursor1048:
    return handleAltScreen(mode, enabled: enabled)
```

All four modes route through `handleAltScreen`. Matches spec step 4 exactly.

---

## 4. cursorPosition event indexing — pre-requisite for deviation 1 analysis

**Method:** `grep -n "cursorPos\|case n\|0-index\|HVP\|row.*col" /Users/ronny/rdev/rTerm/TermCore/CSICommand.swift`; then read ScreenModel.swift `case .cursorPosition` handler at line 349.

**Findings:**

`CSICommand.swift` line 41–42: "cursorPosition (CSI H / HVP) is pre-normalized to 0-indexed at parse time — the row/col values already sit in `[0, dim)` bounds."

`ScreenModel.swift` line 349–355: handler assigns `buf.cursor.row = r; buf.cursor.col = c` directly with no subtraction.

**Conclusions:** `.csi(.cursorPosition(row: N, col: M))` in test code means 0-indexed row=N, col=M directly.

---

## 5. Test deviation 1 — test_alt_screen_1047_cursor_persists_across_re_entry

**Method:** Compare plan spec (lines 1364–1387) with implementation (ScreenModelTests.swift lines 733–756). Apply cursorPosition 0-indexed semantics from section 4.

**Plan spec:** `cursorPosition(row:1, col:3)` → 0-indexed (1, 3). Write 'Z' at col=3, advance to col=4. Grid is 4 columns (cols=4). col=4 >= cols=4 → `snapshotCursor` fires deferred-wrap and returns `(row+1, 0) = (2, 0)`. Final assertion checks `reentered.cursor.col == 3` — this would FAIL because snapshotCursor returns col=0.

**Implementation:** `cursorPosition(row:1, col:2)` → 0-indexed (1, 2). Write 'Z' at col=2, advance to col=3. col=3 < cols=4, no deferred wrap. `snapshotCursor` returns (1, 3). Assertion `reentered.cursor.col == 3` passes.

**Conclusions:** The plan spec test had a deferred-wrap bug (cursor lands off the right edge triggering wrap reporting). The implementation's fix to `col:2` keeps the cursor in-bounds and the persistence semantic is still correctly proven. Deviation is legitimate and correctly applied.

---

## 6. Test deviation 2 — test_save_restore_per_buffer

**Method:** Compare plan spec (lines 1495–1520) with implementation (ScreenModelTests.swift lines 864–892). Trace through `handleAltScreen` 1049 logic.

**Trace:**
1. `CSI s` at (0,0) → `main.savedCursor = (0,0)`
2. Move main to (1,2)
3. `1049 enter`: `main.savedCursor = main.cursor = (1,2)` — OVERWRITES the (0,0) save (both DECSC and 1049 share one slot per buffer, per xterm)
4. On alt: `CSI s` saves alt.cursor = (0,0) (alt starts at origin after 1049 enter)
5. Move alt to (2,3)
6. `CSI u` on alt: restores to (0,0). Assert (0,0) passes.
7. `1049 exit`: `main.cursor = main.savedCursor = (1,2)`. Assert (1,2) passes.
8. `CSI u` on main: `main.cursor = main.savedCursor = (1,2)` — still (1,2), origin save was clobbered.

Plan spec expected (0,0) at step 8. This was a plan spec bug: it did not account for 1049 enter clobbering the prior DECSC save. The implementation correctly asserts (1,2) with a well-documented comment explaining xterm semantics.

**Conclusions:** Deviation 2 is a genuine plan spec bug correctly fixed in the implementation. Comment at lines 882–889 documents the xterm "DECSC and 1049 share one slot per buffer" rationale.

---

## 7. test_save_cursor_1048_per_buffer — was this modified from plan spec?

**Method:** Compare plan spec (lines 1424–1461) with implementation (ScreenModelTests.swift lines 793–830).

**Findings:** Plan spec final assertion (line 1459): `Cursor(row: 0, col: 2)`. Implementation final assertion (line 828): `Cursor(row: 0, col: 2)`. Identical.

Trace confirms no clobber: `1048 set` saves (0,2) to `main.savedCursor`. Then `1049 enter` executes `main.savedCursor = main.cursor = (0,2)` — same value, no effective overwrite. After exit and `1048 restore`, cursor returns to (0,2).

**Conclusions:** `test_save_cursor_1048_per_buffer` was NOT modified from the plan spec. The implementer's DONE_WITH_CONCERNS report mis-identified this test as having a changed expectation. The plan value and implementation value are identical: `Cursor(row: 0, col: 2)`.

---

## 8. All 9 tests present?

**Method:** `grep -n "func test_" TermCoreTests/ScreenModelTests.swift` filtered to ScreenModelAltScreenTests struct.

**Findings:** All 9 required tests present:
- test_alt_screen_1049_enter (line 659)
- test_alt_screen_1049_exit_restores_main (line 689)
- test_alt_screen_1047_cursor_persists_across_re_entry (line 719)
- test_alt_screen_47_legacy (line 760)
- test_save_cursor_1048 (line 777)
- test_save_cursor_1048_per_buffer (line 794)
- test_save_restore_cursor_csi_s_u (line 833)
- test_esc_7_8_save_restore (line 848)
- test_save_restore_per_buffer (line 865)

**Conclusions:** All 9 required tests are present and structurally complete.

---

## 9. Integration test extension

**Method:** Read `TermCoreTests/TerminalIntegrationTests.swift` lines 47–54, 103–115.

**Findings:** `unhandled_alt_screen_does_not_corrupt_subsequent_erase_and_home` is the correct test — it uses `vimStartupSequence`. The new assertion at line 114:
```swift
#expect(snap.activeBuffer == .alt, "vim startup should land in alt buffer (mode 1049)")
```
matches the plan spec line 1637 exactly.

**Issue identified:** The test comment block at lines 104–107 still reads:
> "Phase 1: alt-screen mode is parsed but unhandled; [...] since alt is ignored."

This comment describes Phase 1 semantics that are no longer accurate post-T4. Similarly, the `vimStartupSequence` fixture comment at lines 47–49 says:
> "Phase 1 ScreenModel ignores the mode event."

Both comments are stale documentation.

**Conclusions:** The `.alt` buffer assertion was correctly added. Two comment blocks retain stale Phase 1 language and should be updated to reflect Phase 2 behavior.
