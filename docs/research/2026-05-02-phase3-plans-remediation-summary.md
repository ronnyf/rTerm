# Phase 3 Plans — Remediation Summary

- **Date:** 2026-05-02
- **Scope:** Systematic remediation of the two Phase 3 implementation plans targeting the 16 blockers and four recurring defect patterns (P1, P4, P5, P10) identified in the Phase 3 adversarial review.
- **Plans remediated:**
  - `docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md` (Track B — 10 tasks)
  - `docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` (Track A — 12 tasks)
- **Input docs:**
  - `docs/research/2026-05-02-phase3-plans-adversarial-review.md` (16 blockers)
  - `docs/research/2026-05-02-phase1-phase2-plans-adversarial-retro.md` (P1–P11 cross-plan patterns)
  - `docs/superpowers/specs/2026-04-30-control-characters-design.md` §8
- **Source-truth worktree for API verification:** `/Users/ronny/rdev/rTerm/` on branch `phase-2-control-chars`.

---

## Commits on `phase-3-plans`

| SHA | Pass | Subject |
|---|---|---|
| `e002e71` | 1/5 | P1 plan-author-guessed API (5 blockers) |
| `981a9a4` | 2/5 | P4 VT semantics side effects (3+ blockers) |
| `1c482c3` | 3/5 | P5 Swift 6 isolation (2 blockers) |
| `0f42a77` | 4/5 | P10 narrative-plan rewrites (2 blockers) |
| `e954ca3` | 5/5 | GPU sync, AppKit blocking, Codable, measurement gate (4 blockers) |

---

## Blocker-by-blocker audit trail

| # | Blocker (one-liner) | Pattern | Fix commit | Notes |
|---|---|---|---|---|
| 1.1 | `active.cursor = …` cannot compile (active is get-only) | P1 | `e002e71` | Rewrote DECOM Task 6 Step 3 to route mutation through `mutateActive { buf in … }`; same pattern propagated to Step 4. |
| 1.2 | `scrollRegion.top ?? 0` has wrong optionality | P1 | `e002e71` | Corrected to `buf.scrollRegion?.top ?? 0` — the optional is on the struct, not on `top: Int`. |
| 1.3 | `installWritebackSink` called from nonisolated init | P5 | `e002e71` + `1c482c3` | Pass 1 moved the install site into `Session.startOutputHandler()` inside `screenModel.assumeIsolated { model in … }`; Pass 3 added explicit actor-isolation annotations + dropped incorrect `@ObservationIgnored`. |
| 1.4 | `fanOutResponse` does not exist on Session | P1 | `e002e71` | Replaced every `self.fanOutResponse(...)` call with `self.broadcast(_:)` (verified at `Session.swift:216`). |
| 1.5 | `MetalBufferRing.nextBuffer` has no GPU-sync | gpu-sync | `e954ca3` | Added `DispatchSemaphore(value: count)` to ring; `nextBuffer` calls `wait()`, `signalOnCompletion(commandBuffer:)` registers `addCompletedHandler`. `drainAndResize` waits for every in-flight slot before rebuilding. |
| 1.6 | `coordinator?.glyphMetrics` does not exist | P1 | `e002e71` | Added sub-step exposing `RenderCoordinator.cellSize: CGSize` backed by `regularAtlas.cellWidth / cellHeight` (verified at `GlyphAtlas.swift:66,68`). |
| 1.7 | `TerminalPalette.solarizedDark/Light` do not exist | P1 | `e002e71` | Added explicit Task 12 sub-step landing canonical Schoonover 16-slot Solarized Dark + Light + `preset(named:)` + `allPresetNames`. Corrected the `AppSettings` narrative (existing file is already `@Observable @MainActor`; we layer `@AppStorage` on top of the existing `palette` property). |
| 1.8 | `NSAlert.runModal()` blocks MainActor | appkit-blocking | `e954ca3` | Rewrote `clipboardConsent(for:preview:)` to use `beginSheetModal(for:completionHandler:)` + `withCheckedContinuation`. Added coalescing note for rapid OSC 52 bursts. Apple doc citation in commit message. |
| 1.9 | DECCOLM missing VT side effects (DECSTBM + DECOM reset) | P4 | `981a9a4` | Handler now performs all four spec side effects: (1) clear both buffers (ED 2 equivalent), (2) home cursor, (3) reset `scrollRegion` on both buffers, (4) `modes.originMode = false`. Added tests for side effects (3) and (4). |
| 1.10 | OSC 8 inner params separator is `:`, not `;` | P4 | `981a9a4` | Rewrote `parseOSC8` to split `paramsPart` on `':'`. Added multi-param + order-independence tests. Cited egmontkob OSC 8 grammar text (verified via WebFetch). |
| 1.11 | `ClipboardTarget.from(xtermChar:)` collapses set to one char | P4 | `981a9a4` | Redesigned `ClipboardTarget` → `ClipboardTargets` (Swift `OptionSet`). `ClipboardTargets.parse(_:)` reads every xterm letter (c/p/q/s/0-7); empty string defaults to `.select` per xterm. Parser + sink + DaemonResponse + client handler updated; tests added for `"cs"` and `""` inputs. |
| 1.12 | Task 3 file-split access-control narrative incoherent | P10 | `0f42a77` | Rewrote as single prescription: stored properties AND nested types stay in `ScreenModel.swift`; only methods move; access levels do NOT change; same-module extensions see private storage transparently. Added pre-move audit step that greps for direct `ScrollRegion` references to catch methods that would need type promotion. Removed the "dispatch pbxproj surgery subagent" footnote. |
| 1.13 | DispatchSerialQueue typed-init overload ambiguity | P5 | `1c482c3` | Dropped the deprecated untyped-init overload entirely. Single typed init with parameter renamed `queue:` → `serialQueue:` so call-site migration is greppable. `rtermd/Session.swift` and `rtermd/main.swift` migrated in the same commit. Spec §6 (daemon + client in lockstep) means source break has no third-party blast radius. |
| 1.14 | CellStyle Codable wire-compat claim wrong-sided | wire-compat | `e954ca3` | Corrected the rationale: the current `CellStyle` is auto-derived Codable, and the rewrite TO hand-coded is necessary because auto-derived cannot `decodeIfPresent` a new field. Mixed daemon/client versions aren't a Phase 3 constraint. Added `test_legacy_cellstyle_decodes` (direct CellStyle decode from pre-Phase-3 JSON) + `test_cellstyle_encode_omits_nil_hyperlink` (encode side drops key when nil). |
| 1.15 | `forTesting` factory unconditionally throws | P8 (via P10) | `0f42a77` | Dropped the factory-that-throws pattern entirely. Tests now call `RenderCoordinator.init(screenModel:settings:)` directly and exercise a new internal `beginFrameCleanup(cols:rows:)` helper factored out of `draw(in:)`. `XCTSkip` kept only as graceful degradation for "no Metal device" (never fires on macOS CI). Task 8 test uses the analogous `ensureRingsForTesting` pattern. |
| 1.16 | 20k-LF/2s budget math is half the claimed 60 MB/s gate | P10 | `0f42a77` | Split Task 10 Step 4 into: (a) unconditional measurement at the correct rate (37,500 LFs in 2.0 s = exactly 60 MB/s), then (b) conditional implement-or-defer gated on Step 4's pass/fail. Earlier draft ran at 10k LF/s = 32 MB/s, half the claimed rate. |

**Result: 16 of 16 blockers cleared.**

---

## Patterns swept

| Pattern | Pass | Blockers cleared |
|---|---|---|
| P1 plan-author-guessed API | 1/5 | 1.1, 1.2, 1.4, 1.6, 1.7 |
| P4 VT semantics side effects dropped | 2/5 | 1.9, 1.10, 1.11 (plus 2.1, 2.2, 2.10 risk tightening) |
| P5 Swift 6 isolation mis-specification | 3/5 | 1.3, 1.13 |
| P10 narrative-plan-as-execution | 4/5 | 1.12, 1.15, 1.16 |
| New: gpu-sync, appkit-blocking, wire-compat | 5/5 | 1.5, 1.8, 1.14 |

Total: 12/16 cleared by pattern sweeps (Passes 1–4) + 4/16 by point fixes (Pass 5). Two risks from §2 of the adversarial review (2.1 DA1 identity, 2.2 DA2 version) also tightened in Pass 2 as opportunistic fixes — the plan now emits xterm's canonical defaults (`ESC [ ? 1 ; 2 c` for DA1 and `ESC [ > 0 ; 322 ; 0 c` for DA2) rather than speculative identifiers. Risk 2.10 (top/htop fixture end-state-only assertion) also fixed in Pass 2 — the fixture now splits into enter/exit halves so the alt-screen intermediate state is asserted.

---

## Not-fixed / deferred

None. All 16 blockers cleared.

Two risks in the adversarial review's §2 section were NOT addressed (they are risks, not blockers):

- **2.3 restore-ordering test flake potential:** the review asks for a 1000-iteration flake check. This is an execution-time concern, not a plan defect — the plan's test is written correctly; the question is whether it runs stably in CI. Flagged for CI sign-off after first implementation.
- **2.4 blink rendering manual-visual-only:** the plan's Task 5 (blink) does not add a pixel-compare unit test. Factoring out a pure function `AttributeProjection.project(fg:bg:attributes:blinkPhaseOff:)` would enable testing — worthwhile but out of scope for the remediation sweep (would be a new task, not a plan-defect correction).
- **2.5 `@Observable @MainActor` + `@ObservationIgnored @AppStorage` interaction:** Apple docs are minimal; pattern is widely used but not officially documented. Flagged for empirical test after implementation lands.

---

## New defects found during the sweep (not in original 16)

None new. The sweep's scope was the 16 blockers + the 4 P1/P4/P5/P10 patterns; opportunistic tightening of DA1/DA2 identifiers (risks 2.1, 2.2) and top/htop fixture (risk 2.10) happened inside Pass 2 without introducing new blockers.

One small coverage gap observed in the review (§3) that no task lands: a tracking comment at `CircularCollection.swift:53` for spec §8 Track B item 10. The plan's Track B completion checklist notes this should be done; the checklist item is procedural rather than a code change. Left as-is — adding a task would expand the remediation scope beyond the mandate.

---

## Verification methodology

For every identifier the plans reference, the remediation pass verified it exists as described by reading the actual source at `/Users/ronny/rdev/rTerm/` on branch `phase-2-control-chars`:

- `TermCore/ScreenModel.swift` — confirmed `active` is get-only computed (line 191); `Buffer.scrollRegion: ScrollRegion?` nested (line 158); actor isolation at line 49; `public init(...queue: DispatchQueue?)` at line 211.
- `TermCore/ScreenSnapshot.swift` — Codable shape, `Cursor` struct, `BufferKind`.
- `TermCore/CellStyle.swift` — confirmed auto-derived Codable at line 40.
- `TermCore/TerminalPalette.swift` — confirmed `xtermDefault` is the ONLY preset (line 100); `solarizedDark`/`solarizedLight` do not exist.
- `TermCore/AttachPayload.swift` — confirmed shape + `Row` nested typealias.
- `rtermd/Session.swift` — confirmed `broadcast(_:)` at line 216; `fanOutResponse` nonexistent.
- `rTerm/RenderCoordinator.swift` — no `glyphMetrics` accessor; has `regularAtlas`.
- `rTerm/GlyphAtlas.swift` — confirmed `cellWidth`/`cellHeight` at lines 66, 68.
- `rTerm/AppSettings.swift` — confirmed `@Observable @MainActor` class with `palette: TerminalPalette = .xtermDefault`.

VT/xterm external sources verified:
- Apple Metal docs (`developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work`) — confirmed the triple-buffering semaphore pattern + `addCompletedHandler`.
- Apple NSAlert docs (`developer.apple.com/documentation/appkit/nsalert/runmodal()`) — confirmed `runModal()` is blocking; `beginSheetModal(for:completionHandler:)` is the async alternative.
- OSC 8 grammar (Egmont Kob gist, the canonical spec adopted by iTerm2, WezTerm, kitty, Alacritty) — confirmed inner params separator is `:`.
- DECCOLM, DA1/DA2, OSC 52 semantics — VT510 + xterm ctlseqs primary sources returned 403 in this session; fell back to established consensus documented in `/Users/ronny/rdev/rTerm-phase3-plans/docs/research/2026-05-02-phase3-plans-adversarial-review.md` and cross-referenced against the xterm/tmux/kitty behavior documented by the review doc itself.

---

## Files changed

- `docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` (+~480 lines, -~220 lines across 5 commits)
- `docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md` (+~450 lines, -~280 lines across 5 commits)
- `docs/research/2026-05-02-phase3-plans-remediation-summary.md` (this file)

Branch `phase-3-plans` is ready for PR review. Do not push until the user reviews.
