# T4 Simplify Pass — Quality Review Empirical Findings

**Date:** 2026-05-01
**Commit:** bf0f066 (Phase 2 T4 — alt-screen modes 1049/1047/47 + saveCursor 1048)
**Reviewer pass:** /simplify — quality focus (not efficiency/reuse)

---

## Q1: handleAltScreen switch length — is each case still readable?

**Question:** The new `handleAltScreen` function is ~70 lines. Is the switch too long? Should helper methods be extracted (`enter1049()`, `exit1049()`, etc.)?

**Method:** Read `TermCore/ScreenModel.swift` lines 641–708. Counted cases and nesting depth.

**Findings:**
- 4 cases: `.saveCursor1048`, `.alternateScreen47`, `.alternateScreen1047`, `.alternateScreen1049`.
- Each case body is 6–16 lines. The longest (`alternateScreen1049`) is 15 lines split across two `if/else` branches.
- Maximum nesting inside any arm: 2 levels (switch → if → guard/body).
- The `default:` arm is a one-liner.
- Total is 68 actual code lines in the function body. The inline comments (which are load-bearing xterm rationale) account for roughly 14 of those.

**Conclusions:** Readable as-is. Helper extraction (`enter1049()`, etc.) would spread 4 tightly related operations across 4 private methods with no reduction in total code; it buys nothing here. The switch is below the extraction threshold. No issue.

---

## Q2: Repeated guard patterns — worth extracting `switchTo(.alt)` helper?

**Question:** Lines 669, 686 both guard `activeKind != .alt` on enter. Lines 674, 693 both guard `activeKind == .alt` on exit. Are these worth a `guard switchTo(.alt)` helper?

**Method:** Read all 5 guard sites in `handleAltScreen`. Traced what each does after the guard.

**Findings:**
- The two enter guards (`!= .alt`) both return `false`. The two exit guards (`== .alt`) both return `false`.
- However, after passing the guard, every case does something semantically distinct:
  - 1047 enter: no cursor save, just `activeKind = .alt` + clear.
  - 1049 enter: `main.savedCursor = main.cursor` first, then switch + clear + cursor reset.
  - 1047 exit: clear-then-switch, no cursor restore.
  - 1049 exit: clear-then-switch + conditional cursor restore.
- The idempotency guard is one line with an obvious invariant. Extracting it buys no clarity and adds indirection.
- `.alternateScreen47` uses a different pattern (target variable) — it would not share any helper anyway.

**Conclusions:** The repeated guard is an acceptable 1-line idiom repeated 4 times. A helper would save 4 lines at the cost of 1 extracted function and a less-obvious call site. Not worth it at this scale. No issue.

---

## Q3: `Self.clearGrid(in: &alt, cols: cols, rows: rows)` repetition (4 call sites)

**Question:** Four identical call sites with `cols: cols, rows: rows` always forwarding `self.cols`/`self.rows`. Is parameterization too eager? Would an instance method `clearAlt()` be cleaner?

**Method:** Read all 4 call sites (lines 671, 678, 689, 696). Checked whether any call site uses different col/row values.

**Findings:**
- All 4 call sites pass `cols: cols, rows: rows` (capturing `self.cols` / `self.rows`).
- None pass a different dimension.
- The `static` design exists to let the function take `inout Buffer` without re-entering `mutateActive`. That rationale is sound.
- An instance method `func clearAlt()` would be equally valid: `alt.grid` is directly accessible on `self`, and `cols`/`rows` are actor-isolated properties. It would shorten each call to `clearAlt()` and eliminate the repeated `cols:rows:` argument noise.
- The `clearGrid(in:cols:rows:)` parameterization also serves `scrollUp(in:cols:rows:)` precedent, so the static+inout pattern is intentionally consistent across helpers in this file.
- `clearGrid` is called exclusively on `alt` — never `main`, never inside `mutateActive`.

**Conclusions:** Mild suggestion: an `private func clearAlt()` would shorten call sites and make the intent (always clearing the alt buffer) structurally clear. The current design is not wrong — it follows existing precedent in this file. Flagged as Suggestion only.

---

## Q4: `Cursor(row: 0, col: 0)` — does `Cursor` have `.zero` or `.origin`?

**Question:** Line 690 uses `alt.cursor = Cursor(row: 0, col: 0)`. Does `Cursor` have a `.zero` / `.origin` static?

**Method:** Read `TermCore/ScreenSnapshot.swift` (contains the `Cursor` struct). Searched for `static.*zero|origin|home` across all TermCore Swift files.

**Findings:**
- `Cursor` has no static `.zero`, `.origin`, or `.home`.
- `Cursor(row: 0, col: 0)` appears at 2 production code sites: `Buffer.init` (line 127) and the 1049-enter path (line 690). It appears at ~25 test/doc sites.

**Conclusions:** The absence of `Cursor.zero` is a mild friction. Adding `public static let zero = Cursor(row: 0, col: 0)` to `Cursor` would make origin-semantics clear at all call sites (both production and test). Flagged as Suggestion. Not a bug.

---

## Q5: Stringly-typed code

**Question:** Is there any stringly-typed code in the diff?

**Method:** Read the full diff. Searched for string literals in switch/case, magic strings, raw string comparisons in non-OSC handlers.

**Findings:**
- No stringly-typed code. All mode dispatch uses the typed `DECPrivateMode` enum. The commit message comment markers ("1049 enter", etc.) are comments, not code.

**Conclusions:** Clean. No issue.

---

## Q6: Nested conditionals — any 3+-level nesting?

**Question:** Does any code path in the new diff have 3+ levels of nesting?

**Method:** Read `handleAltScreen` and `clearGrid`. Counted braces.

**Findings:**
- `handleAltScreen`: switch → if/else → (guard, body). Max depth = 2. No 3-level nesting.
- `clearGrid`: flat loop. Depth = 1.
- 1048 disabled path: mutateActive closure → guard → body. Depth = 2 inside the closure.

**Conclusions:** No excessive nesting. No issue.

---

## Q7: Comments — "what" narration and forward-reference noise

**Question:** Do any inline comments narrate WHAT rather than WHY? Are T4/T5/T6 forward references now stale noise?

**Method:** Read all comments in the new `handleAltScreen` and `clearGrid` additions. Read existing T-reference comments elsewhere in `ScreenModel.swift`.

**Findings (new code):**
- `// no visible change` — narrates the return value. Low value.
- `// matches xterm.` — explains WHY. Good.
- `// Do NOT touch alt.cursor — xterm leaves it where it is so re-entry keeps the prior position even though grid was cleared.` — explains non-obvious xterm behavior. Good, load-bearing.
- `// Not an alt-screen mode.` on the `default:` — mildly redundant. The compiler enforces the switch; a reader who reaches `default` in a function named `handleAltScreen` understands the situation.

**Findings (existing code — outside the diff):**
- Line 60: `// Phase 2 T4` — T4 is now landed. This is a minor historical marker, not noise; it tells a future reader when dual-buffer was wired without requiring a git-log lookup. Acceptable.
- Line 79: `// (T4)` — same category: historical marker. Acceptable.
- Line 393: `// T5 wires .setScrollRegion.` — forward reference to a not-yet-done task. **This is the only genuinely noise-forward reference**: it tells the reader T5 is coming but doesn't explain current behavior. Useful for navigation during development.
- Line 445: `// .scrollback is handled in T6` — same: informative forward ref. Low noise.
- Line 589: `// T6 will add a history-feed path` — same.
- Line 610: `// no-ops, alt-screen modes (T4)` — T4 is done; the doc-comment accurately describes current behavior. `(T4)` here is historical noise now. Mild.

**Conclusions:** The forward references to T5/T6 are "useful scaffolding" — they explain current stubs and will be cleaned up when those tasks land. The one weak comment is `// no visible change` which narrates the return value rather than explaining why a save is not visible. The `// Not an alt-screen mode.` default comment is mildly redundant. Flagged as low-priority Suggestions.

---

## Q8: Test naming — behavior-focused vs. implementation-focused?

**Question:** Are the 9 new alt-screen test names behavior-focused or mode-number-focused?

**Method:** Read all 9 `@Test` string labels in `ScreenModelAltScreenTests`.

**Findings:**
1. `"Mode 1049 enter saves main cursor, switches to alt (cleared), pen persists"` — mode-number + behavior. The mode number is useful since this is a low-level protocol test; behavior is also stated.
2. `"Mode 1049 exit returns to main with cursor restored, alt cleared"` — same pattern.
3. `"Mode 1047 enter switches + clears alt; exit clears alt + switches back; alt cursor persists across re-entry"` — covers two behaviors in one name. Slightly long but accurate.
4. `"Mode 47 toggles buffer without clear or cursor save (legacy)"` — descriptive.
5. `"Mode 1048 saves cursor without buffer switch"` — clear.
6. `"Mode 1048 save/restore is per-buffer (alt and main keep independent slots)"` — clear.
7. `"CSI s + writes + CSI u restores cursor (per active buffer)"` — clear.
8. `"ESC 7 / ESC 8 (DECSC / DECRC) behave the same as CSI s / CSI u"` — clear.
9. `"Save/restore is per-buffer: alt and main keep separate saved cursors"` — overlaps with #6.

**Observations:**
- Tests 6 and 9 both describe per-buffer save/restore independence (1048 and CSI-s/u respectively). The names distinguish them by mechanism, which is appropriate.
- All names are behavior-focused enough. The mode numbers are identifying information, not "test implementation details".

**Conclusions:** Test naming is good. Test 3's name is long (covers 3 behaviors) but the behaviors tested are genuinely coupled so collapsing them is justified. No issue.

---

## Q9: Test fixture duplication — shared setup opportunity?

**Question:** Do the 9 new tests share enough setup (e.g., 4-col 3-row models, alt-enter sequences) to merit a fixture extension?

**Method:** Read all 9 test functions. Noted ScreenModel dimensions and setup sequences.

**Findings:**
- Model sizes: 9 tests use 6 different dimension combinations: (5,3)×6, (4,2)×1, (3,2)×1, (5,3)×1, (80,24)×0, (5,3)×1. Six of nine tests use `ScreenModel(cols: 5, rows: 3)`.
- No test uses a pre-shared fixture (Swift Testing does not have `setUp`/`tearDown`; each test body is independent).
- The `(5,3)` model is just `ScreenModel(cols: 5, rows: 3)` — one line. Extracting it to a helper would buy 6 × 0 lines saved (replacing `let model = ScreenModel(cols: 5, rows: 3)` with e.g. `let model = makeAltScreenModel()`).
- There is no repeated multi-step setup sequence common to multiple tests. Some tests share "enter alt via 1049" but they enter at different cursor positions so they are not identical.

**Conclusions:** No fixture extraction is warranted. The `let model = ScreenModel(cols:rows:)` line is already the minimal fixture. A helper would add indirection for no readability gain. No issue.

---

## Q10: Integration test regression — was the full-grid assertion removal safe?

**Question:** The integration test `vim_startup_lands_in_alt_buffer_with_homed_cursor` removed the O(80×24) cell-by-cell blank assertion and replaced it with just `snap.activeBuffer == .alt` + `snap.cursor == Cursor(row:0,col:0)`. Does this lose meaningful coverage?

**Method:** Read old and new test bodies from the diff. Read `ScreenModelAltScreenTests` to see if blanking is already covered.

**Findings:**
- The removed assertion was `for r in 0..<snap.rows { for c in 0..<snap.cols { #expect(snap[r,c].character == " ") } }` — 1920 cell checks.
- That check validated that `CSI 2 J` (erase display) clears the alt grid. `CSI 2 J` is already covered in `ScreenModelCSITests` (pre-existing, not new to T4).
- `test_alt_screen_1049_enter` explicitly checks all cells in a 5×3 alt grid are blank after 1049-enter.
- The integration test now asserts `activeBuffer == .alt` — the key T4 behavioral change.
- The 80×24 blank-grid check was a de-facto erase test inside an integration test; it is adequately replaced by the unit-level coverage.

**Conclusions:** The reduction is safe. The test now tests its actual subject (does vim's startup sequence land in alt buffer?). No coverage gap.

---

## Q11: Commit message vs. code — 1047 enter "cursor origin" discrepancy

**Question:** The commit message header says `1047 enter: switch to alt → clear alt → cursor origin`. But the code does NOT reset the cursor on 1047 enter. Is this a bug or a documentation error?

**Method:** Read lines 665–672 in ScreenModel.swift. Compared to the commit message body.

**Findings:**
- Code at lines 665–672: `activeKind = .alt; Self.clearGrid(in: &alt, ...)`. No cursor reset.
- Commit message body (not header) says `1047 enter: switch to alt → clear alt → cursor origin (no main-cursor save)`.
- The comment at line 666 says `alt's cursor persists across re-entry within a session`.
- Test `test_alt_screen_1047_cursor_persists_across_re_entry` explicitly verifies that after re-entry, cursor is at `(1, 3)` — NOT at origin.
- The first entry (before any alt-cursor movement) sees alt at `(0,0)` because that is the initial `Buffer.init` value, not because 1047 resets it.
- The commit message header description is misleading: it implies cursor is homed on 1047 enter, but the implementation (correctly, per xterm) does not home the cursor.

**Conclusions:** The commit message body contains a misdescription for 1047. The code and test are correct and consistent with xterm behavior. This is a documentation issue in the commit message only (immutable post-merge). Not a code bug.

---

## Q12: `Self.clearGrid` — memory exclusivity with alt buffer

**Question:** `clearGrid(in: &alt, ...)` is called directly on `self.alt` outside `mutateActive`. When alt is the active buffer, is there a potential Swift exclusivity violation?

**Method:** Read the actor's isolation model. Checked whether any concurrent borrow of `alt` could overlap.

**Findings:**
- `ScreenModel` is an actor. All instance method calls are serialized on the actor's executor.
- `handleAltScreen` is a private actor-isolated method; it cannot be reentered.
- `clearGrid` takes `inout Buffer`. The borrow is exclusive but within a single synchronous frame — no `await` between the borrow start and its release.
- `mutateActive` borrows whichever buffer is active; it is not called concurrently with `clearGrid` in the same turn.
- Swift's exclusive access is enforced at the point of borrow, not across turns. No exclusivity conflict.

**Conclusions:** No exclusivity issue. The design is correct.
