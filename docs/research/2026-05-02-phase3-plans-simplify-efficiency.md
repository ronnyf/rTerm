# Phase 3 Plans — Simplify-Efficiency Review

Date: 2026-05-02
Scope: post-remediation efficiency pass on the Track A (features) and Track B (hygiene) plans.
Files reviewed:

- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md` (10 tasks, 69 implementer checkboxes)
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` (12 tasks, 82 implementer checkboxes)

Reference terminals consulted: wezterm (`term/src/terminalstate/mod.rs`), iTerm2 (`sources/VT100Terminal.m`).

All file paths below are absolute. Research only — no plan edits made.

---

## 1. Scope efficiency

| Track / Task | Issue | Recommendation |
|---|---|---|
| B Task 5 (`publishHistoryTail()` ordering doc comment) — 5 checkboxes, pure doc | Too little work for its own task; the commit is one comment + a sanity re-grep that Task 3 already implies. | **Merge into Task 3** ("ScreenModel file split"). The split already lands `ScreenModel+History.swift`; attach the doc comment in the same commit. Saves one commit + one build-reporter pass + one simplify round. |
| B Task 4 (`TerminalStateSnapshot` + `Cursor.zero`) — 7 checkboxes, 2 migration sites | Only **two** `Cursor(row: 0, col: 0)` sites actually exist (verified: `ScreenModel.swift:162` and `:922`), not the "3–4" the plan hedges to, and neither is in `ScreenModel+Buffer.swift` (that file does not yet exist). Also, `Cursor.zero` is free-standing and lands cleanly without the `TerminalStateSnapshot` extraction. | **Split** `Cursor.zero` into a 2-line amendment folded into Task 3 (the file split). Keep `TerminalState` as its own task — it's the part that reshapes a public init. |
| B Task 7 + Task 8 (vertex-array reuse + Metal buffer ring) | Two tasks touch the same five `device.makeBuffer` call sites in the same draw-pass block of `RenderCoordinator.draw(in:)` (verified at `rTerm/RenderCoordinator.swift:326,343,360,377,521`). Task 7 adds `#if DEBUG makeBufferCountForTesting` at each site; Task 8 replaces those same sites with `nextBuffer(copying:...)` and Step 5 then tells implementer to "remove the `#if DEBUG makeBufferCountForTesting += 1` from these sites". | **Fold Task 7 Steps 1–4 into Task 8**. Task 7 as written churns five sites twice (add counter, then remove counter). Merging saves the intermediate commit (Task 7 Step 2 + Task 8 Step 1 both make commits that touch the same file). Keep Task 7's `reserveVertexCapacity` + `beginFrameCleanup` refactor — that lands in Task 7 and stays. |
| B Task 8 (Metal buffer ring) — 8 checkboxes with a mid-task intermediate commit | Step 1 commits a DEBUG counter + signposter as a "baseline measurement" independent of the implementation. The commit is pure instrumentation that gets partly removed in Step 5. | **Drop the Step 1 intermediate commit.** The counter scaffolding can live in the same commit as the ring implementation; the baseline number is captured by running Step 1 locally before committing anything. Saves one commit boundary. |
| B Task 10 (`ScrollbackHistory.Row` pool) — 12 checkboxes with conditional implementation | Now correctly measurement-gated. But the plan defines two git-commit commands (Step 5 "defer" OR Step 5 "implement"). Both are spelled out as if they run. | **Leave as-is** — the branching is explicit and each branch is one commit. Not scope bloat, just a flow diagram. |
| A Task 11 (`iconName` on snapshot) — 4 checkboxes | `ScreenModel` already stores `iconName` (verified at `TermCore/ScreenModel.swift:76`, `:523-525`) AND already exposes it via `currentWindowTitle()` / `currentIconName()` (line 660). The plan "exposes" something that is already exposed — only the snapshot field is new. | **Merge into Task 4** (DECSCUSR). Both tasks (A4 + A11) mutate the exact same `ScreenSnapshot.TerminalState` struct the Track B Task 4 convenience init introduces. Landing `cursorShape` and `iconName` in one extension pass saves a complete TerminalState rev + Codable migration round-trip. See structural-efficiency §3.1 below for the cross-plan hazard this also fixes. |
| A Task 2 (DA1 + DA2) and A Task 3 (CPR) | Both add a CSI case, parse a `c`/`n` final byte, and handle in `ScreenModel.handleCSI` with `emitWriteback`. Total substantive work per task is ~40 LOC. Commits are 4+6 checkbox steps each. | **Merge Task 2 + Task 3 into a single "DA1 + DA2 + CPR" task.** Saves one commit + one reviewer round. Wezterm handles all three (plus DA3, DSR, terminal-name, terminal-parameters, XtSmGraphics) in ONE match arm in `terminalstate/mod.rs:1254–1356` — see §4.1. |
| A Task 12 (palette chooser) — **13 checkboxes**, over the 12 threshold | Crosses three targets (TermCore palette presets, AppSettings paletteName binding, SwiftUI Settings scene + rTermApp + ContentView + RenderCoordinator). Step 1 is an investigative grep that belongs in the implementer's pre-flight, not a checkbox. Steps 5 and 6 both edit `RenderCoordinator.draw(in:)`. | **Split** into A12a (add `solarizedDark`/`solarizedLight` presets + `preset(named:)` + `allPresetNames` in TerminalPalette; this is pure TermCore — except it isn't, see §3.2 below) and A12b (SettingsView + AppStorage binding + rTermApp Settings scene). Independent review-wise. |

Total savings from scope consolidation: **3 merged commits, 1 dropped intermediate commit, 1 split = net 3 fewer implementer-controller review round-trips.**

---

## 2. Execution efficiency

### 2.1 Low-value steps

| Task | Step | Why it's low-value |
|---|---|---|
| B Task 3 | Step 8 ("Verify line counts with `wc -l`") | The controller's build-reporter already runs after Step 9's commit; a line-count check is not a correctness signal. A diff-sanity comment in the commit message is sufficient. |
| B Task 5 | Step 4 ("Build + test") + Step 3 ("Verify ordering at the two call sites") | No code change; this is a doc-only task. The build reporter runs automatically. Step 3's re-grep is the controller's job — it's implicit in /simplify's scope. |
| B Task 9 | Step 4 ("flag to the user for confirmation") | Manual-verification hand-off is listed as a task step but produces no artifact. Keep as a comment in the commit message ("Manual verify: scroll back via wheel; content renders correctly") rather than its own checkbox. |
| A Task 5 | Step 4 + Step 3 — "If the renderer is on-demand, add a timer; otherwise the 60 fps loop handles it" | The plan hedges on whether a timer is needed, and instructs the implementer to grep to find out. **Verified: `rTerm/TermView.swift:148` sets `preferredFramesPerSecond = 60`** — it is NOT on-demand. Rewrite the checklist to "60 Hz is already configured; verify blinkPhase uniform drives correct visuals" instead of making the implementer investigate. Saves ~5 minutes of grep-and-think. |
| A Task 12 | Step 1 ("Inspect current palette infrastructure") | This is the plan remediator's job, not the implementer's. Hoist the findings into the task's prose (which it already partly does) and drop the standalone investigation step. |

### 2.2 Tool-priority misses

- B Task 3 Step 1: `rg -n "\\bScrollRegion\\b" TermCore/ScreenModel.swift` — **correct**.
- B Task 10 Step 1: uses `#if DEBUG` + `nonisolated(unsafe) static var` — correct; but Step 3's `xcodebuild -only-testing` single-test invocation is a 10-second build-and-test round per run; implementers should NOT be running this per memory rules (controller-only builds). Rewrite as "commit; the controller will run the test."
- A Task 7 Step 2: the plan prose instructs implementer to grep `"maxBuffersInFlight" or "semaphore"` in `RenderCoordinator.swift`. **Verified: there is no existing `maxBuffersInFlight` or `DispatchSemaphore` in `rTerm/RenderCoordinator.swift`.** Drop the grep; just set `maxBuffersInFlight = 3` directly.
- A Task 8 Step 3: instructs `rg -n "intermediates" TermCore/TerminalParser.swift | head -20` — can be pre-resolved in the plan text. The implementer should not be discovering parser APIs during Phase 3.

### 2.3 Fabricated byte-level code duplication

Every test in Tracks A & B that exercises parser → model → writeback uses hand-coded `[UInt8]` arrays. Count of duplicated escape-sequence byte arrays across both plans:

- `[0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]` (ESC [ ? 1049 h) — Track B Task 2.
- `[0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x63]` (DA1 response) — Track A Task 2 × 2 places.
- `[0x1B, 0x5B, 0x3E, 0x30, 0x3B, 0x33, 0x32, 0x32, 0x3B, 0x30, 0x63]` (DA2) — Track A Task 2.
- `[0x1B, 0x5B, 0x31, 0x3B, 0x31, 0x52]`, `[0x1B, 0x5B, 0x35, 0x3B, 0x31, 0x30, 0x52]` — Track A Task 3 CPR tests.
- `[0x1B, 0x5B, 0x30, 0x20, 0x71]`, `[0x1B, 0x5B, 0x32, 0x20, 0x71]`, `[0x1B, 0x5B, 0x36, 0x20, 0x71]` — Track A Task 4 DECSCUSR × 4.
- Multiple OSC 8 / OSC 52 byte-sequences spliced via `+ Array("payload".utf8) +` in Track A Tasks 8, 10.

Recommendation: **add a test-only helper** `extension Data { static func csi(_ body: String) -> Data; static func osc(_ ps: Int, _ pt: String) -> Data; static func dcs(...) -> Data }` to `TermCoreTests/TestHelpers.swift` (one new file, ~30 LOC, one commit folded into Track B Task 1). All six later test files then read as:

```swift
let events = parser.parse(.csi("?1;2c"))  // DA1 response
```

vs. the current:
```swift
let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x32, 0x63]))
```

Estimated savings: **20+ byte arrays eliminated**, off-by-one risk (the OSC 52 byte arrays with mid-sequence `.utf8` splices are particularly prone to human arithmetic errors) eliminated, tests read as intent rather than as bytes. One-time cost: ~30 lines of helper added in Track B Task 1.

---

## 3. Structural efficiency

### 3.1 Cross-plan sync hazards

**TerminalState Codable evolution across Tracks.** Three tasks all extend the same nested struct:

- Track B Task 4 — adds `TerminalState` to `ScreenSnapshot` with 7 fields + convenience init + Codable flat-wire guarantee.
- Track A Task 4 — adds `cursorShape: CursorShape` as an 8th field of `TerminalState` and extends CodingKeys.
- Track A Task 11 — adds `iconName: String?` as a 9th field of `TerminalState` and extends CodingKeys.

Each lands Codable `decodeIfPresent` + default + encode-when-present boilerplate at the `ScreenSnapshot` level. Three separate rewrites of `CodingKeys`, three rewrites of `init(from:)`, three rewrites of `makeSnapshot(from:)` — each one is a full round-trip test with back-compat assertions.

**Recommendation:** merge Track A Tasks 4 and 11 (they hit the same struct + same `CodingKeys` + same `makeSnapshot`). Land `cursorShape` and `iconName` in one Codable patch after B Task 4's convenience init exists. Track A Task 4's renderer-side work (drawing block/underline/bar + blink uniform) stays as its own commit. Savings: one complete `CodingKeys + init(from:) + encode(to:)` migration cycle = ~100 LOC of boilerplate avoided.

### 3.2 Cross-plan target-membership drift

Track A Task 12 instructs the implementer to modify `TermCore/TerminalPalette.swift`. **Verified: that file does not exist.** `TerminalPalette` lives at `/Users/ronny/rdev/rTerm/rTerm/TerminalPalette.swift` (lines 38+; preset `xtermDefault` at line 100) — it is an **rTerm app-target file**, not a TermCore file. The plan's commit hunks (Step 2, Step 6) would fail.

- If `TerminalPalette` moves to TermCore for Phase 3 reasons, that move is its own prerequisite sub-task (and changes visibility / module-stability surface of TermCore).
- If it stays in the app target, the plan text just needs the path corrected in four places (Step 2, Step 2 extension, Step 6 `git add`, and a "Files:" list entry).

**Recommendation:** correct the path to `rTerm/TerminalPalette.swift` in Task 12. No framework move; it's app-local. (Internal palette presets don't need to be in TermCore — the renderer is app-local anyway.)

### 3.3 Task ordering / build-break risk

- **B Task 3 (file split) before B Task 5 (doc comment on moved method)**: correct order; doc comment targets the post-split file. Good.
- **B Task 4 adds `Cursor.zero`** → **A Task 6 (DECOM)** and **A Task 7 (DECCOLM)** both use `Cursor.zero` → implicit dependency on B Task 4 lands first. Tracked correctly in the preamble.
- **B Task 6 (typed `DispatchSerialQueue` init) before B Task 3 (file split)?** Task 3 does not move the `init` method (verified via the enumerated section list in Task 3 prose: `init` stays in `ScreenModel.swift`). No conflict. Order is fine.
- **A Task 1 (writeback sink) before A Task 2 (DA1/DA2)**: correct — A Task 2 relies on `emitWriteback`.
- **A Task 4 (DECSCUSR) depends on B Task 4 (TerminalState convenience init)**: documented in A Task 12 self-review note. Good.
- **A Task 10 (OSC 52 clipboard) inserts its sink install adjacent to A Task 1's sink install** — Step 6 says "inside the same `screenModel.assumeIsolated { model in … }` block." This is a cross-plan timing coupling (the exact site depends on A Task 1 landing first). Documented. OK.

### 3.4 Signpost subsystem/category collisions

Three tasks add `os_signpost` or `OSSignposter` intervals:

- B Task 7: `OSSignposter(subsystem: "rTerm", category: "RenderCoordinator")` — interval `"drawFrame"`.
- B Task 8: signposter interval `"metalBufferAlloc"` — uses the **same** signposter from Task 7 (no new instance specified), so same subsystem+category.
- A Task 4 (DECSCUSR cursor blink uniform): mentions "a shared global timer uniform" but no signpost. Uses `CACurrentMediaTime()` directly.

`"drawFrame"` and `"metalBufferAlloc"` are unique interval names under the same (subsystem, category) pair — **fine**. Both intervals will render correctly in Instruments' Points of Interest track.

**Recommendation:** add a one-line convention note in Track B Task 7 ("all new signposts use `OSSignposter(subsystem: \"rTerm\", category: \"RenderCoordinator\")`; interval names must be unique within the category") rather than re-prescribing in each task. Covers Phase 4 additions without plan churn.

---

## 4. Reference-terminal factorings worth borrowing

### 4.1 WezTerm: unify all query-response (DA1/DA2/DA3/CPR/DSR/terminal-name/params/XtSmGraphics) into one match arm

File: `/Users/ronny/dev/public/wezterm/term/src/terminalstate/mod.rs`, lines 1254–1356.

WezTerm handles `Device::RequestPrimaryDeviceAttributes`, `RequestSecondaryDeviceAttributes`, `RequestTertiaryDeviceAttributes`, `RequestTerminalNameAndVersion`, `RequestTerminalParameters`, `StatusReport`, and `XtSmGraphics` all in the **same** match arm on a `Device::*` enum, each one calling `self.writer.write(...)` on the same writer. No "writeback infrastructure prelude" task — the writer is just the PTY primary, held as a single trait object on `TerminalState`.

Cited WezTerm response for DA1: `"\x1b[?65;4;6;18;22;52c"` (VT525 + sixel + selective erase + windowing ext + vt525 color + clipboard access). rTerm's plan picks `?1;2c` (VT102 + advanced video) citing xterm compat — this is a reasonable policy divergence; note that **WezTerm is happy to identify as VT525** even though its "c" list is advertising features it doesn't all implement. rTerm's choice is safer.

**Applicability to rTerm:** the Phase 3 plan fragments DA1 + DA2 (Task 2) and CPR (Task 3) into two tasks. Merging per §1 above matches wezterm's factoring. Adding DSR (CSI 5 n → `\x1b[0n`) and DA3 (CSI = c) as two-line follow-ups in the same commit is zero extra work; the plan notes DSR "falls through to .unknown" — WezTerm implements it in ONE line (`self.writer.write(b"\x1b[0n").ok();`, line 1336). Consider whether Phase 3 should include DSR trivially. (If the answer is "defer to Phase 4," the merged task already covers the wezterm factoring.)

### 4.2 WezTerm: DECCOLM side-effect set is exactly what the Phase 3 plan documents

File: `/Users/ronny/dev/public/wezterm/term/src/terminalstate/mod.rs` lines 1690–1910 show matches on alt-screen and column-switch with the four side effects Phase 3 Track A Task 7 enumerates (clear + home + reset DECSTBM + reset DECOM). The post-remediation plan correctly cites these. **Nothing to change**; the plan's VT510 grounding matches the established implementation.

### 4.3 iTerm2: separate clipboard path is also the established pattern

File: `/Users/ronny/rdev/iTerm2/sources/VT100Terminal.m:2584` calls `[_delegate terminalCopyStringToPasteboard:decoded]` for OSC 52 set; the writer-side reports go through `[_delegate terminalSendReport:]` at many other lines.

**Applicability:** Track A Task 10's separate `_clipboardSink` alongside Task 1's `_writebackSink` is correct. Both wezterm and iTerm2 split pasteboard from PTY write. The plan's two-sink design is the established factoring. **No change recommended.**

### 4.4 Renderer hot-path hoist — already inlined, may not need restructure

File: `/Users/ronny/rdev/rTerm/rTerm/RenderCoordinator.swift:197` defines `cellAt` with `@inline(__always)` and reads `let historyRow = history[historyRowIdx]` inside the closure. The Phase 3 plan Track B Task 9 proposes restructuring the loop so `historyRow` is loaded in the outer (row) loop, citing "1,920 header copies per frame."

Caveat: with `@inline(__always)` on the local function + LLVM's loop-invariant code motion pass, the compiler almost certainly already hoists the `history[historyRowIdx]` read out of the column loop when the `row < scrollOffset` branch is taken for all columns in that row. The "2.6 MB/s" number in the plan assumes the compiler does NOT hoist — which is not verified.

**Recommendation:** before landing Task 9 as proposed, add a one-line measurement step using `os_signpost` to confirm the regression exists. If the compiler already hoists (likely), Task 9 becomes a no-op — delete it. Cost: 5 minutes measurement. Benefit: avoid a ~30 LOC restructure that may add nothing.

---

## 5. Recommendations (ranked, largest time savings first)

| # | Recommendation | Est. saved | Type |
|---|---|---|---|
| 1 | Merge Track A Tasks 2 + 3 (DA1 + DA2 + CPR) into one task; merge Track A Tasks 4 + 11 (cursorShape + iconName Codable migration) into one task | 2 full implement/review/simplify cycles (~45–60 min per cycle, so 1.5–2 hrs) | Scope |
| 2 | Drop Track B Task 8 Step 1 intermediate commit (counter + signposter baseline) — fold into the ring implementation commit | 1 commit + 1 build-reporter pass + 1 simplify round (~15 min) | Scope |
| 3 | Add `Data.csi(_:)` / `Data.osc(_:_:)` test helpers once in Track B Task 1; all downstream tests read clearly; eliminates ~20+ hand-assembled `[UInt8]` arrays | Saves 3–5 off-by-one defects (debug time variable, conservatively 15–30 min each over implementation) plus test readability | Execution |
| 4 | Merge Track B Task 5 (doc comment) into Track B Task 3 (file split) — single commit lands the moved methods + their docstring | 1 commit + review cycle (~15 min) | Scope |
| 5 | Pre-resolve all "grep to find out" steps in the plan text (A5 Step 3/4, B3 Step 1, A7 Step 2 `maxBuffersInFlight` check, A12 Step 1 palette inspection) — remediator verifies, implementer acts | ~5 min × 5 places = 25 min of implementer investigation avoided | Execution |
| 6 | Correct Track A Task 12's incorrect file path (`TermCore/TerminalPalette.swift` → `rTerm/TerminalPalette.swift`); split Task 12 into 12a (presets + lookup) and 12b (SettingsView + scene) | Avoids 1 build break on the first implementer run (~15 min debugging). Split aids reviewer focus. | Structural |
| 7 | Measure Track B Task 9's `history[row]` header-copy overhead with os_signpost before restructuring the loop — it may already be hoisted by `@inline(__always)` | If the compiler already hoists (likely), saves ~30 LOC + 1 commit. If not, the measurement validates the 2.6 MB/s claim. | Execution |
| 8 | Add a single convention note on signpost subsystem/category naming to Track B Task 7; later signpost additions cite the convention instead of re-deriving it | Saves re-deriving convention in 2 later tasks (~5 min) | Structural |

**Net estimated savings:** 4–5 commit boundaries consolidated, 2–3 hours of implementer round-trip time, reduced off-by-one defect risk in ~20 byte-array tests, and one averted first-run build break (A12 file-path).
