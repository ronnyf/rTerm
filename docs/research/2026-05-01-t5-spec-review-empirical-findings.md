# T5 Spec Review: Empirical Findings

**Date:** 2026-05-01
**Reviewer:** Code Review (claude-sonnet-4-6)
**Commit reviewed:** cd72ffd

---

## Question 1: Is the plan's Step 4 `scrollWithinActiveBounds` code internally inconsistent with test `test_decstbm_lf_below_region_does_full_screen_scroll`?

### Method

Traced the plan's Step 4 `scrollWithinActiveBounds` code against the `test_decstbm_lf_below_region_does_full_screen_scroll` test manually.

### Findings

**Plan Step 4 trigger (unchanged from original):**

```swift
if buf.cursor.row >= rows {
    Self.scrollWithinActiveBounds(in: &buf, cols: cols, rows: rows)
}
```

The trigger only fires when `cursor.row >= rows` (i.e., cursor stepped off the bottom of the screen entirely). It does NOT fire when the cursor is inside the screen but past `region.bottom`.

**Plan Step 4 `scrollWithinActiveBounds` code (from plan lines 1885-1900):**

```swift
static func scrollWithinActiveBounds(in buf: inout Buffer, cols: Int, rows: Int) {
    if let region = buf.scrollRegion {
        if buf.cursor.row - 1 == region.bottom {
            scrollRegionUp(in: &buf, cols: cols, region: region)
            buf.cursor.row = region.bottom
        } else {
            // Clamp without scrolling (preserves region content).
            buf.cursor.row = rows - 1
        }
    } else {
        scrollUp(in: &buf, cols: cols, rows: rows)
    }
}
```

The `else` branch says "Clamp without scrolling" with the comment "Cursor went past last screen row but the LF was outside the region."

**The contradiction:**

`test_decstbm_lf_below_region_does_full_screen_scroll` uses a 5-row screen, region=[1,3] (0-indexed), cursor at row 4. LF moves cursor to row 5 (`>= rows`). In `scrollWithinActiveBounds`, `cursor.row == 5`, `region.bottom == 3`. The condition `cursor.row - 1 == region.bottom` → `4 == 3` is false. So the plan's else branch executes: clamp to `rows - 1` (row 4), no scroll.

But the test expects:
1. `snap[0, 0].character == "X"` — "X" was at row 1 and moved to row 0. This requires a full-screen scroll.
2. `snap.cursor.row == 4` — cursor at last row.

Under the plan's else branch, no scroll happens and "X" stays at row 1 (not row 0). The test would FAIL against the plan's code.

**Conclusion: The plan's Step 4 code is internally inconsistent with its own test.** The comment in the else branch says "clamp without scrolling" but the test demands "full-screen scroll." This is a genuine contradiction in the plan document.

---

## Question 2: Does the implementation's deviation correctly resolve the contradiction?

### Method

Read the implemented `scrollWithinActiveBounds` and compared its else branch to what the test requires.

### Findings

The implementation changes the else branch to call `scrollUp(in: &buf, cols: cols, rows: rows)` instead of clamping. For the same test scenario (cursor.row=5, region.bottom=3, condition false):

- `scrollUp` shifts all rows up by one: "X" at row 1 moves to row 0. Check.
- `scrollUp` sets `cursor.row = rows - 1 = 4`. Check.

Both test assertions pass. The deviation is correct.

---

## Question 3: Is the trigger broadening in `handlePrintable` / `handleC0` necessary?

### Method

Traced `test_decstbm_set_region` through the code both with and without the broadened trigger.

### Findings

**Test setup:** 6-row model, region=[1,3] (0-indexed from `setScrollRegion(top:2, bottom:4)`). Cursor placed at row 3 (inside region, at its bottom), then LF.

**After LF:** `cursor.row = 4`. Screen has 6 rows, so `cursor.row < rows` (4 < 6). The original plan trigger `if cursor.row >= rows` would NOT fire.

Without the broadening, `scrollWithinActiveBounds` is never called, no scroll occurs, and the test's expectations about rows 1-3 shifting would fail.

**The broadened trigger:**
```swift
if buf.cursor.row >= rows || (buf.scrollRegion != nil && buf.cursor.row > buf.scrollRegion!.bottom)
```

For this scenario: `4 >= 6` is false, but `buf.scrollRegion != nil && 4 > 3` is true. Dispatcher fires.

Inside `scrollWithinActiveBounds`: `cursor.row == region.bottom + 1` → `4 == 3 + 1` → true. `scrollRegionUp` is called; cursor clamped to `region.bottom = 3`. Correct.

**Conclusion:** The trigger broadening is necessary and correct. Without it, region-internal LFs would never scroll the region when the screen has more rows below the region bottom. The plan's Step 4 text only replaces `>= rows` with a call to `scrollWithinActiveBounds` but leaves the trigger condition unchanged, which means region-internal overflow can only be detected once the cursor goes off-screen entirely — which does not happen when the region ends above the last screen row.

---

## Question 4: Does the `handleSetScrollRegion` implementation match the plan spec?

### Method

Compared plan Step 3 code block against the implemented function line by line.

### Findings

Plan (lines 1822-1836):

```swift
private func handleSetScrollRegion(top: Int?, bottom: Int?) -> Bool {
    let topZero  = (top ?? 1)    - 1
    let botZero  = (bottom ?? rows) - 1
    // nil/nil = reset to full screen.
    if top == nil && bottom == nil {
        mutateActive { $0.scrollRegion = nil }
        return false
    }
    // Validate.
    guard topZero >= 0, botZero < rows, topZero < botZero else {
        return false
    }
    mutateActive { $0.scrollRegion = ScrollRegion(top: topZero, bottom: botZero) }
    return false
}
```

Implementation (lines 709-723):

```swift
private func handleSetScrollRegion(top: Int?, bottom: Int?) -> Bool {
    // nil/nil = reset to full screen.
    if top == nil && bottom == nil {
        mutateActive { $0.scrollRegion = nil }
        return false
    }
    let topZero = (top ?? 1) - 1          // VT 1-indexed → 0-indexed
    let botZero = (bottom ?? rows) - 1
    // Validate.
    guard topZero >= 0, botZero < rows, topZero < botZero else {
        return false
    }
    mutateActive { $0.scrollRegion = ScrollRegion(top: topZero, bottom: botZero) }
    return false
}
```

The implementation moves the nil/nil guard before the `let` assignments. This is strictly equivalent (and slightly better: avoids computing topZero/botZero on the reset path). All logic matches.

---

## Question 5: Does `scrollRegionUp` match the plan spec?

### Method

Compared plan Step 4 `scrollRegionUp` against the implementation.

### Findings

Plan uses `let stride = cols` as a named variable; implementation uses `cols` directly. Algorithmically identical. Loop range `region.top ..< region.bottom`, copy direction, bottom-row clear: all identical. No `buf.cursor.row` mutation inside `scrollRegionUp` in either version (cursor is set by the caller). Correct: region scrolls must not reset cursor.

---

## Question 6: Do the 5 tests in the implementation match the plan verbatim?

### Method

Read plan tests (lines 1696-1791) and implementation tests side by side.

### Findings

All 5 tests are byte-for-byte identical to the plan. The test names, assertions, logic, comments, and structure match exactly. No test was added, removed, or modified.

---

## Summary

- Plan contradiction confirmed: Step 4 `scrollWithinActiveBounds` else branch ("clamp without scrolling") is incompatible with `test_decstbm_lf_below_region_does_full_screen_scroll`, which expects a full-screen scroll.
- Implementer's deviations: both are correct responses to the contradiction.
  - Else branch changed to `scrollUp` (correct for xterm behavior and for the test).
  - Trigger broadened to `|| (buf.scrollRegion != nil && buf.cursor.row > buf.scrollRegion!.bottom)` (necessary for region-internal LFs to fire on screens where the region does not extend to the last row).
- All named functions match the plan's algorithm.
- All 5 tests match the plan verbatim.
- Only the two spec-mandated files were touched.
