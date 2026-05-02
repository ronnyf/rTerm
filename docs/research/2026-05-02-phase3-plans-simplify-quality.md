# Phase 3 Plans — Simplify-Quality Review

**Scope.** Narrative quality pass of the two Phase 3 plans after the 5-pass remediation.
Phase 1 (`2026-04-30-control-chars-phase1.md`) is the style benchmark.

**Reviewed files (absolute paths):**
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md` (1810 lines)
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` (2363 lines)

**Baseline:** `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-04-30-control-chars-phase1.md` (2971 lines).

**Reference terminals consulted:**
- `~/dev/public/wezterm/term/src/terminalstate/mod.rs` (DA1/DA2)
- `~/dev/public/wezterm/wezterm-escape-parser/src/osc.rs` (OSC 52 `Selection` bitflags, OSC 8)
- `~/dev/public/wezterm/wezterm-escape-parser/src/hyperlink.rs` (OSC 8 parse)
- `~/dev/public/wezterm/termwiz/src/render/terminfo.rs` (DECSCUSR `Ps` mapping)
- `~/rdev/iTerm2/sources/VT100Output.m` (DA2 response, vim/emacs detection rules)
- `~/rdev/iTerm2/sources/VT100Terminal.m` (DA1/DA2 dispatch)

---

## 1. Quality defects per plan

### 1a. Track B — `2026-05-02-control-chars-phase3-hygiene.md`

| # | Category | Task / Line | Issue | Suggested fix |
|---|---|---|---|---|
| B01 | Narrative-voice leak ("earlier draft") | T2 / 235 | "Assertion design note: the earlier draft of this fixture applied the entire byte stream … The rewritten test splits …" — author's reasoning from remediation. | Replace with prescriptive framing ("Split the byte stream into enter + exit halves so we can assert alt was entered AND alt grid holds shell content, THEN exit restores main"). Move retrospective to remediation-summary doc. |
| B02 | Redundant rationale | T2 / 235 vs 322-328 | Step 2 explains the rationale for splitting the stream; commit message re-explains the same (fourth integration fixture, capping deferred corpus). | Pick one. Suggest: keep single-line commit summary; drop the "assertion design note" or slim to one sentence. |
| B03 | Narrative-voice leak ("Design decision") | T6 / 794 | "An earlier draft of this plan kept BOTH inits … The rewrite below drops the untyped init entirely rather than keeping both." | Recast as prescriptive: "A single typed init, no deprecated overload — overload resolution of `nil` against `DispatchQueue?` vs `DispatchSerialQueue?` is ambiguous." |
| B04 | Low-signal filler | T7 / 926 | "Pattern used: `os.signpost` instrumentation added first to establish a measurement baseline (count of allocations observed via `OSSignposter.beginInterval` inside the arrays' allocation points is infeasible without an allocator hook; instead, count `reserveCapacity` sites and instrument the draw loop to record the per-frame interval duration — the metric is frame time, not allocation count)." | Trim to one sentence: "Instrument per-frame draw interval via `OSSignposter`; verify no allocation regression via XCTest `measure`." The "infeasible without an allocator hook" elaboration belongs in a research doc. |
| B05 | Narrative-voice leak ("we factor") | T7 / 1028 | "Test design note: rather than faking the full Metal pipeline, we factor the bookkeeping preamble of `draw(in:)` into a standalone helper that can run without a drawable." | Imperative: "Extract the capacity-reserve + clear preamble of `draw(in:)` into an internal helper so the test can call it without a drawable." |
| B06 | Swift-6 isolation note meta-commentary | T7 / 1170, T10 / 1639 | Two Swift-6 isolation notes narrate the author's thinking ("`nonisolated(unsafe)` tells the compiler 'I take responsibility for the races.' In this test counter's case the invariant we rely on is …"). | Compress: "The counter is `nonisolated(unsafe)` — writes from `draw(in:)` on MainActor, reads from the test which is `@MainActor`. Reading the counter without an `await` would race." |
| B07 | Redundant sub-section | T8 / 1202 & 1313 | `GPU-sync design — verified against Apple docs` quotes Apple doc inline, then a second `Note on nonisolated(unsafe) for the semaphore` re-explains the same concurrency reasoning. | Collapse into one design paragraph above the code block. |
| B08 | Under-specified step | T9 / 1591 | Step 3 says "If `cellAt` has no remaining callers after the restructure, remove it. If it is still used elsewhere (e.g., cursor rendering), leave it in place" — implementer must guess. | Pre-verify and state directly whether `cellAt` remains a caller or not. Or run the grep at plan time and record the answer. |
| B09 | Punted verification | T9 / 1595-1597 | "The existing integration tests don't cover this path. Because manual verification is the practical check, flag to the user for confirmation." | Add a ScreenModel-level unit test that asserts the correct `Cell` is produced at `(scrollOffset>0, row, col)` for a known history — exercises the `history[row][col]` path without Metal. Pure correctness, no rendering needed. |
| B10 | Narrative-voice leak ("we factor / we meet") | T10 / 1718-1720, 1744, 1768 | Body uses "we meet the gate", "Passing pins that we are NOT regressing", "we collapse to .select". | Imperative / factual: "The test passes iff the 60 MB/s gate is met." |
| B11 | Conditional branch in plan narrative | T10 / 1742-1794 | Step 5 is a *branching* decision point inside the plan ("If Step 4 passed … If Step 4 failed …"). Controller workflow assumes linear task execution. | Split into two alternative commits described up-front, or move the branching decision to a small "choose one" bullet list. Phase 1 convention is linear tasks. |
| B12 | Broken/ambiguous cross-reference | T2 / 316 | "If the active-buffer assertion fails on exit, inspect `handleAltScreen(.alternateScreen1049, enabled: false)` — **the T4 correction should restore main.**" — "T4" is undefined in Phase 3 (hygiene Task 4 is `TerminalStateSnapshot`). | Disambiguate: "the Phase 2 T4 alt-screen handler correction". Or drop the orphan reference. |
| B13 | Commit-message drift | T8 / 1516-1535 | Commit message claims "Steady-state makeBuffer count drops from 4-6/frame to 0" — but Step 6's test only exercises `ensureRings` path, not actual `draw(in:)` frames. The steady-state claim is not demonstrated in the test. | Either strengthen the test (drive actual draw frames) or qualify the commit claim ("steady-state `ensureRings` path allocates no new MTLBuffers"). |
| B14 | Over-specified code block | T7 / 1056-1103 | Full test file laid out in 48 lines where the load-bearing signal is "call `beginFrameCleanup` twice, compare capacities" — 4 lines. | Diff-style: show the assertion and skip the XCTest boilerplate the project already has conventions for. |
| B15 | Self-review note at end-of-file | 1810 | Mixed content: "this plan covers items 1–10, 12" is load-bearing; "CLAUDE.md does not need a new 'Key Conventions' bullet" is stale reviewer correspondence. | Keep the coverage statement; drop the reviewer-correspondence lines. |

### 1b. Track A — `2026-05-02-control-chars-phase3-features.md`

| # | Category | Task / Line | Issue | Suggested fix |
|---|---|---|---|---|
| A01 | Inconsistent voice ("We adopt" / "we surface") | T2 / 220-221 | DA1 bullet: "We adopt the `1 ; 2` pair." DA2 bullet: "we cite a specific xterm patch". | Imperative/factual: "Emit `1 ; 2` (xterm default)." / "Cite xterm patch 322 as a concrete credible value." |
| A02 | Narrative-voice leak ("earlier draft") | T2 / 223 | "(The earlier draft's `65 ; 22` DA1 and `> 1 ; 95 ; 0` DA2 were speculative. `65` in DA1 means VT525…)" | Delete — this is remediation history. If a reader needs to know why these specific bytes were chosen, a single sentence suffices: "Byte choice grounded in xterm default + a concrete xterm patch number." |
| A03 | Narrative-voice leak ("earlier draft") | T7 / 1012 | "The earlier draft of this plan covered (1) and (2) only. tmux and vim use DECCOLM on entry and rely on the post-toggle state being 'full-screen region, origin off'" | Drop "earlier draft". Start at "Side effects 3 and 4 are load-bearing — tmux/vim rely on the post-toggle state being 'full-screen region, origin off'." |
| A04 | Narrative-voice leak ("earlier draft") | T8 / 1213 | "The earlier draft of this plan split `<params>` on `;` — that would never find multiple entries because the outer split already consumed them. Correct separator is `:`." | Factual: "Inner separator is `:` per OSC 8 grammar." Cite iTerm2/wezterm/kitty as concordant. |
| A05 | Redundant rationale | T8 / 1296-1298 | The "Why hand-coded Codable" paragraph duplicates much of the spec §6 rationale + re-explains the project's Codable convention that Phase 1 already established. | Compress to one line: "Hand-coded Codable with `decodeIfPresent` per project convention — a synthesized init cannot ignore a missing key (legacy Phase 1/2 payloads)." |
| A06 | Narrative commentary ("we surface") | T10 / 1686 | Goal prose: "the app stays sandbox-safe because `NSPasteboard` write permissions do not require entitlements for user-triggered flows — but remote shell write via escape sequence is not user-triggered, so we surface a prompt the first time". | Factual: "Surface a consent prompt: OSC 52 is not user-triggered, so an unprompted pasteboard write is unexpected." |
| A07 | Spec/impl drift inside one task | T10 / 1686 vs 1769 | Goal says "`OSCCommand.setClipboard(target: ClipboardTarget, payload: ClipboardPayload)`" — **singular** `target`, and a `ClipboardPayload` type that doesn't exist. Step 2 shows actual case `setClipboard(targets: ClipboardTargets, base64Payload: String)` — **plural, String.** | Align Goal with the real signature: `setClipboard(targets: ClipboardTargets, base64Payload: String)`. |
| A08 | File-name inconsistency | T10 / 1690, 1714, 1718 | Files list + Step 1 both call the file `ClipboardTarget.swift` (singular) but the type is `ClipboardTargets` (plural). | Rename file to `ClipboardTargets.swift` or make type singular. Pick one. |
| A09 | Under-specified step | T5 / 801-813 | Step 4 is literally "Launch the app, run `printf '\033[5mHELLO\033[0m\n'`. The 'HELLO' text should blink at 1 Hz." Then "Flag manual verification required — unit tests cannot observe Metal pixel output." | Phase 1's equivalent (blink attribute) had a unit-level assertion against `snapshot[0, 0].style.attributes.contains(.blink)` combined with a fragment-shader uniform test. Adopt the same — assert the blink uniform is computed correctly in a `@MainActor` test; don't defer the entire task to manual. |
| A10 | Punted verification accumulation | T5 / 813, T9 / 1655-1661, T12 / 2314 | Three tasks in sequence (Blink, OSC 8 renderer, Palette chooser) all defer to manual visual test. Blink + palette switch *could* be unit-tested at the uniform/binding level. | Tighten at least Blink (uniform computation) and Palette (AppStorage/observer binding) to automated tests. OSC 8 hover/click legitimately requires `NSEvent` simulation, so it's the one genuine manual case. |
| A11 | Low-signal "Swift 6 isolation note" / "API note" repetition | T1 / 58, 93; T6 / 858, 880; T8 / 1296; T9 / 1551; T10 / 1834; T12 / 2133, 2275 | Nine `**API note — verified against …:**` / `**Isolation note — verified against …:**` blocks. They aren't cross-referenced; each duplicates the "verified during plan remediation" framing. | Consolidate per-file API facts into a single "Source-tree snapshot as of plan time" appendix, and reference by file:line from steps. Matches Phase 1's "verified toolchain" block idiom. |
| A12 | Over-specified code block | T8 / 1316-1426 | 111-line `HyperlinkTests.swift` scaffold, 8 `@Test` bodies laid out in full. The load-bearing invariants are: id extraction, terminator, multi-param colon-separator, pen stamps, round-trip, legacy decodes to nil, encode omits nil. | Keep test **names** + one-line assertion summaries; the implementer can write the XCTest scaffolding. Matches Phase 1 which usually shows 2-3 illustrative `@Test` bodies + a list of additional ones. |
| A13 | Design/reality mismatch — empty target default | T10 / 1743-1747 + 1938-1946 | Plan says "An empty string yields the xterm default of `.select`". wezterm (reference) emits `SELECT | CUT0` for empty target (grep: `~/dev/public/wezterm/wezterm-escape-parser/src/osc.rs:101`). | On macOS every target collapses to `NSPasteboard.general`, so the distinction is moot for behavior — but the test at 1938 locks in the wrong semantics compared to reference terminals. Either match wezterm or note the simplification explicitly in the commit. |
| A14 | Over-reach — `ClipboardTargets` includes `.secondary` ('q') | T10 / 1738 | wezterm's `Selection` does not define `q` (only `c/p/s/0-9`). The OSC 8 ecosystem consensus wezterm cites doesn't treat 'q' as standard. | Drop `.secondary`, or mark it as extension. (Minor — the blast radius is doc-level only.) |
| A15 | Commit-message drift | T8 / 1439-1457 | 18-line commit message re-explains OSC 8 grammar, separator rationale, Codable compat story — the "why", "how", and "what if". | Trim to ~6 lines following Phase 1 convention: action + load-bearing design decision + test summary. |
| A16 | Commit-message drift | T7 / 1129-1145 | Commit message lists all four VT510 side effects again verbatim from the VT semantics block above. | Keep the list once; commit says "per the VT510-spec four side effects described in the Goal block". |
| A17 | Inline `git add` parameter lists | all tasks | Every task ends with `git add <file list>` spelled out. Phase 1 has this pattern too, so consistent — but Phase 3's file lists are sometimes stale (e.g. T11 commit `git add … TermCoreTests/` without a specific file). | Either specify the test file by name or drop the `TermCoreTests/` wildcard. The wildcard pattern is a Phase 3-only regression. |
| A18 | Task 5 cross-reference to "Task 4" | T5 / 809 | "phase-aligned with cursor blink from Task 4" — T4 is DECSCUSR. Fine *now*, but if Tasks are reordered this comment breaks silently. | Use absolute title reference: "phase-aligned with the cursor blink uniform introduced in Task 4 (DECSCUSR)" or "the cursor blink uniform added earlier in this plan". |
| A19 | Self-review note end-of-file | 2356-2363 | Mixed content (`DECOM (Task 6) and DECCOLM (Task 7) both route through handleSetMode — confirm DECPrivateMode.init(rawParam:) has both entries after Task 7 lands.`) is a pre-flight checklist, not reviewer note. | Move actionable checks into the Track A completion checklist (already exists at 2338). Drop reviewer-meta lines. |
| A20 | Goal sentences exceed Phase 1 norm | Many | Phase 1 Goal sentences run 1-3 sentences, ~30 words. Phase 3 Goals range up to 5 sentences / 100+ words (T1 / 26-31, T10 / 1686 runs ~80 words as a single sentence). | Tighten to Phase 1's 1-3 sentence goal format; split detailed reasoning into a one-line "Design" sub-section only when needed. |

---

## 2. Structural inconsistencies

### 2a. Section-header drift from Phase 1

Phase 1's per-task shape:

```
## Task N: <title>
**Spec reference:** ...
**Goal:** 1-3 sentences.
**Files:**
### Steps
- [ ] Step 1: ...
```

Phase 3 tasks add **additional bold headers between `Goal` and `Files`** that are not present in Phase 1:

| Extra header | Appears in | Count |
|---|---|---|
| `**Architecture:**` | Plan preamble (both) | 2 |
| `**Design decision — …:**` | hygiene T6 | 1 |
| `**Binary-compat note for BUILD_LIBRARY_FOR_DISTRIBUTION:**` | hygiene T6 | 1 |
| `**Pattern used:**` | hygiene T7 | 1 |
| `**Design:**` | hygiene T8 | 1 |
| `**GPU-sync design — verified against Apple docs:**` | hygiene T8 | 1 |
| `**Ownership:**` | hygiene T8 | 1 |
| `**Note on `nonisolated(unsafe)` for the semaphore:**` | hygiene T8 | 1 |
| `**VT semantics — verified against …:**` | features T2, T7, T10 | 3 |
| `**VT semantics — grounded against xterm's documented behavior:**` | features T2 | 1 |
| `**Isolation note — verified against …:**` | features T1 | 1 |
| `**API note/s — verified against …:**` | features T1, T6, T6, T8, T9, T10, T12, T12 | 8 |
| `**Why hand-coded Codable, not auto-derived?**` | features T8 | 1 |
| `**Coalescing:**` | features T10 | 1 |
| `**Swift 6 isolation note:**` | hygiene T7, T10 | 2 |
| `**Test design note:**` | hygiene T7 | 1 |
| `**Access-control rules (single prescription — no mid-plan revisions):**` | hygiene T3 | 1 |
| `**File layout:**` | hygiene T3 | 1 |
| `**Assertion design note:**` | hygiene T2 | 1 |
| `**Self-review note:**` | both, end-of-file | 2 |

Phase 1 *does* use similar inline bold labels occasionally (`**Parser limits per spec §2:**`, `**Ownership docstring:**`), but restrained — at most one or two per task. Phase 3 routinely uses 3-4 per task, some of them carrying retrospective rationale that belongs elsewhere.

### 2b. `**Files:**` list completeness

- hygiene T9 lists only `rTerm/RenderCoordinator.swift` but Step 4 says "flag to the user" — no test file is listed, reflecting the punt.
- features T11 / 2017-2020 lists `TermCore/ScreenSnapshot.swift`, `TermCore/ScreenModel.swift`, `rTerm/ContentView.swift (optional)` but no test file, though Step 3 adds tests to `TermCoreTests/ScreenModelTests.swift`. Missing from Files list.
- features T5 / 753-755 lists `rTerm/Shaders.metal` + `rTerm/RenderCoordinator.swift` but no test file. Step 4 is "manual visual test". Consistent with the punt, but Phase 1 would still specify a structural test file for the uniform binding.
- features T12 / 2110-2116 modifies `rTerm/AppSettings.swift` (plan assumes it exists; API note at 2128 confirms via grep) — but doesn't **create** `rTerm/AppSettings.swift`. Assumes prior existence. No issue, just worth noting as a pre-condition for Track A.

### 2c. Execution-contract preamble duplication

Both plans repeat the Phase 1 execution contract nearly verbatim (`~6` bullet points each). Phase 1 already describes this; Phase 3's preamble says "Execution contract: Identical to Phase 1 + Phase 2 plans" on line 11/13 then re-enumerates all six bullets. Pick one — either reference Phase 1 and drop the bullets, or drop the "identical to …" and keep the bullets. Current form is duplicated.

### 2d. Self-review notes

Both plans end with a `**Self-review note:**` block (hygiene 1810, features 2356) that mixes actionable completion checks with reviewer-correspondence notes. The reviewer notes are stale artifacts.

---

## 3. Reference terminal comparisons (deltas where rTerm plans are less precise)

### 3a. DA1 response — plan adopts `?1;2c`, reference terminals emit richer

- **Plan (T2 / 311):** `ESC [ ? 1 ; 2 c` — "VT102 + advanced video".
- **wezterm (reference):** `ESC [ ? 65 ; 4 ; 6 ; 18 ; 22 ; 52 c` — VT500 base + sixel + selective erase + windowing + ANSI color + clipboard (`~/dev/public/wezterm/term/src/terminalstate/mod.rs:1288-1294`).
- **iTerm2 (reference):** dynamically builds from feature list including `VT100OutputPrimaryDAFeatureOSC52` (OSC 52 / clipboard bit). See `~/rdev/iTerm2/sources/VT100Output.m:1090-1103`.

**Delta:** The plan cites tmux/vim detection heuristics as the motivation for `1;2c`, but both iTerm2 and wezterm use richer feature bits *without* breaking those detection heuristics. Worth a one-line plan note: "Reference terminals advertise additional capabilities in DA1 (OSC 52, sixel, etc.); rTerm Phase 3 starts minimal and extends as those capabilities land."

### 3b. DA2 response — plan chose `322`; iTerm2 documents why the specific number matters

- **Plan (T2 / 221):** "We emit `Pv = 322` — a concrete, credible xterm patch level … tmux mostly ignores the patch number".
- **iTerm2 (`VT100Output.m:1127-1164`):** 38-line comment block listing the detection rules of vim (`check_termcode()`) and emacs (`xterm.el`) with specific thresholds: `< 95 → underline_rgb`, `>= 95 → mouse_xterm2`, `>= 277 → mouse_sgr`, `>= 2500 → underline_rgb`.
- **wezterm (`mod.rs:1311`):** `\x1b[>1;277;0c` — chosen to cross the `>= 277 mouse_sgr` threshold.

**Delta:** rTerm's choice of `322` *does* clear the `>= 277 mouse_sgr` threshold, so it's functionally correct — but the plan doesn't explain why that threshold matters. Adding a one-line justification keyed to the vim/emacs threshold (like iTerm2's comment) gives a durable reason that outlives remediation history.

### 3c. OSC 52 target parsing — plan omits xterm-default semantics

- **Plan (T10 / 1747):** "An empty string yields the xterm default of `.select`".
- **wezterm (`osc.rs:101`):** `Ok(Selection::SELECT | Selection::CUT0)` — empty target is `SELECT | CUT0`, not just `SELECT`.
- **xterm ctlseqs:** empty selects `s0`, per documented behavior.

**Delta:** Plan is slightly wrong on the default. Likely benign on macOS (both collapse to `NSPasteboard.general`), but the test at features line 1938-1946 pins the wrong default.

### 3d. OSC 52 target set — plan includes `.secondary` for `q`; wezterm doesn't

- **Plan (T10 / 1738):** `case secondary = 'q'`.
- **wezterm (`osc.rs:80-95`):** Only `CLIPBOARD`/`PRIMARY`/`SELECT`/`CUT0-CUT9`. No `q`.

**Delta:** Minor. `q` (secondary X11 selection) is mentioned in xterm ctlseqs but rarely used; wezterm dropped it. Plan's inclusion is defensible but noteworthy.

### 3e. OSC 8 grammar — plan matches wezterm precisely. No delta.

- **Plan (T8 / 1203-1214):** Inner separator is `:`.
- **wezterm (`hyperlink.rs:87`):** `param_str.split(':')`. Same.

Plan correctly cites wezterm + iTerm2 + kitty + Alacritty concordance.

### 3f. DECSCUSR Ps mapping — plan matches wezterm precisely. No delta.

- **Plan (T4 / 518-524):** 0/1 blinking block, 2 steady block, 3 blinking underline, 4 steady underline, 5 blinking bar, 6 steady bar.
- **wezterm (`terminfo.rs:562-567`):** Same mapping.

---

## 4. Recommendations (ordered, highest-signal first)

### R1. Excise narrative-voice leaks — "earlier draft" / "we chose" / "we adopt"

Six occurrences (hygiene 235, 794, 1028, 1718, 1744, 1768; features 220-221, 223, 1012, 1213, 1686, 1712, 1940). All are remediation artifacts. Replace with imperative/factual statements; move the "why this rewrite" reasoning to a `docs/research/2026-05-02-phase3-plans-remediation-summary.md`-style document. Estimated plan shrinkage: 150-250 lines.

### R2. Compress the eight `**API note — verified against …:**` blocks into a single "Source-tree snapshot" appendix

Eight blocks in features plan duplicate the "verified during plan remediation" framing. Phase 1 uses a single `**Verified toolchain**` block in its preamble. Adopt the same — one appendix listing file:line facts the plan relies on, referenced by step. Saves ~80 lines and makes individual steps read faster.

### R3. Tighten the three manual-verification punts (T5 Blink, T9 Scrolled Hoist, T12 Palette)

Features T5 (Blink) defers entirely to `printf '\033[5mHELLO\033[0m\n'`; features T12 (Palette) defers to manual Settings toggle. Both can be tested at the uniform-binding / observer-binding level:

- Blink: unit test that `RenderCoordinator.draw(in:)` computes the blink uniform correctly as a function of `CACurrentMediaTime()`. Extract the phase calc into a pure function.
- Palette: unit test that setting `AppSettings.paletteName` triggers `AppSettings.palette` mutation and that `@Observable` fires. No Metal needed.
- Hygiene T9: add a `ScreenModel` unit test asserting `snapshot[row, col]` returns the expected cell when `scrollOffset > 0` — tests the history-row-load correctness independently of the renderer.

### R4. Fix features T10 spec/impl drift + file-name mismatch + wezterm-divergent empty-target semantics (A07, A08, A13, A14)

Four related defects in one task. The Goal signature does not match the code in Step 2. The filename `ClipboardTarget.swift` does not match the type `ClipboardTargets`. The empty-target default in the test pins semantics that diverge from wezterm. Decide all four before implementer starts.

### R5. Resolve broken cross-reference "T4 correction" in hygiene T2 / 316

One orphan reference. Either disambiguate ("Phase 2 T4") or drop.

### R6. Replace conditional branch in hygiene T10 with two alternative commits

Hygiene T10 Step 5 says "If Step 4 passed, do A; if Step 4 failed, do B" — this is a branch inside a plan step. Phase 1 convention is linear tasks. Re-shape as: "commit the measurement + deferral by default; if the throughput gate fails, spin a T10.5 implementer commit."

### R7. Trim commit-message blocks to Phase 1 norm (~6 lines)

Phase 3 commit-message blocks run 10-18 lines, re-explaining design rationale that's already in the Goal. Phase 1 commit messages are consistently 4-8 lines: action + key decision + test. Trim for consistency.

### R8. Reconcile DA1 response with reference-terminal feature-advertisement practice

Neither wezterm (`?65;4;6;18;22;52c`) nor iTerm2 (dynamically built) emits the bare `?1;2c` that the plan proposes. Consider extending DA1 with feature bits `;52` (OSC 52 since we're landing it in Phase 3) and add a one-line plan note pointing at the wezterm reference. Or keep `?1;2c` and add a `// Phase 4: extend with OSC 52 / sixel bits` comment at the emit site.

### R9. Drop / merge the `**Self-review note:**` blocks at end-of-file

Both plans end with a `Self-review note:` block. The actionable content (coverage statement, DECOM/DECCOLM cross-check) belongs in the preceding completion checklist; the reviewer-correspondence content (`CLAUDE.md does not need a new …`) can be deleted.

### R10. Collapse repeated execution-contract preamble

Plan preambles duplicate Phase 1's execution contract verbatim after saying "Identical to Phase 1 + Phase 2 plans". Pick one; drop the other.
