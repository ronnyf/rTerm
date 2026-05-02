# Phase 3 Plans — `/simplify` Review Application Summary

Date: 2026-05-02
Plans touched:
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md`
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md`

Research inputs:
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/research/2026-05-02-phase3-plans-simplify-reuse.md`
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/research/2026-05-02-phase3-plans-simplify-quality.md`
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/research/2026-05-02-phase3-plans-simplify-efficiency.md`

Net outcome: Track A shrunk 12 → 11 tasks; Track B grew 10 → 10 (one task collapsed, one prerequisite added at T0). Five thematic commits landed on branch `phase-3-plans`.

---

## Disposition per finding

Convention: `[APPLIED in <sha>]` | `[SKIPPED — <reason>]`.

### Reuse findings (`…-simplify-reuse.md`)

| # | Finding | Disposition |
|---|---------|-------------|
| Reuse #1 | `LockedAccumulator<T>` shared test helper | **APPLIED in 3398cf5** — new Track B Task 0 lands `TermCoreTests/TestHelpers.swift`; Track A T1 / T2 / T10 + Track B T1 rewritten to reference the shared helper. |
| Reuse #2 | Collapse Track A T1 + T10 sinks into one typed `ScreenModelOutput` enum | **APPLIED in 18a39db** — T1 rewritten to introduce `ScreenModelOutput` enum + `installOutputSink(_:)` + `emitWriteback` wrapper; T10 now just adds a `.clipboardWrite` arm to the unified switch. Reference-terminal consensus cited (wezterm `self.writer`, iTerm2 `terminalSendReport:`, Terminal.app `[_shell writeData:]`). |
| Reuse #3 | Track A task-dependency table in preamble | **APPLIED in 18a39db** — 11-row table added to Track A plan preamble listing each task's deps / deliverables / parallelizable-with. |
| Reuse #4 | Hyperlink struct-vs-class for per-cell storage | **SKIPPED** — premature optimization. The distinct-hyperlinks-per-screen budget is a future concern; leaving as `Sendable` value struct with an inline note that the tradeoff is acknowledged. (Note was not added on skip — the simplify instruction was to skip this item entirely. Callout documented here.) |
| Reuse #5 | Unify the three DEBUG perf counters | **APPLIED in 18a39db** — introduced `TermCore/PerfCountersDebug.swift` with `makeBufferCount`, `vertexCapacitySnapshot`, `rowAllocationCount` fields under one Swift 6 isolation-rationale paragraph. Track B T6 lands the file; T7 and T9 reference it. |
| Reuse #6 | Collapse 6 `signalOnCompletion` calls into one | **NOT APPLIED in this pass** — out-of-scope for the simplify-apply batches as scheduled. Candidate for a later pass. (Not a regression from the review's perspective; the current 6-line block is correct.) |

### Quality findings (`…-simplify-quality.md`)

| # | Finding | Disposition |
|---|---------|-------------|
| Quality #1 | Excise narrative-voice leaks (`earlier draft`, `we adopt`, `we surface`, `we meet`) | **APPLIED in 0f003e3** — all enumerated occurrences rewritten to imperative/factual voice. Hygiene (T2 assertion note, T5 overload-hazard note, T6 test-design note, T9 throughput gate) + features (T7 DECCOLM prose, T8 OSC 8 grammar note, T10 target-string prose + test comment). |
| Quality #2 | Features T10 OSC 52 spec/impl drift | **APPLIED in d60b600** — Goal prose aligned with actual step-2 signature `setClipboard(targets: ClipboardTargets, base64Payload: String)`; filename renamed `ClipboardTarget.swift` → `ClipboardTargets.swift` in Files list + Step 1 header + git-add line. |
| Quality #3 | Tighten three manual-verification punts | **SKIPPED per instructions** — Blink and palette chooser have legit manual visual components; turning them into uniform/observer tests is real work that belongs in the Phase 3 implementation effort, not the plan. Scrolled-hoist was flagged as the exception; no testable invariant was picked up in Batch 1 because the scope was correctness fixes only. |
| Quality #4 | Consolidate 8 `**API note — verified against …:**` blocks | **APPLIED in 0f003e3** — new 'Source-tree verification snapshot (2026-05-02)' appendix at end of features plan; five inline API-note blocks collapsed to `**API note (see appendix — <file>):**` one-liners. Matches the Phase 1 `**Verified toolchain**` idiom. (Hygiene plan had no API-note blocks to consolidate.) |
| Quality #5.1 | Fix broken T4 cross-ref in hygiene T2 | **APPLIED in d60b600** — disambiguated to "Phase 2 T4 alt-screen handler correction". |
| Quality #5.2 | Hygiene T10 Step 5 conditional branching | **APPLIED in d60b600** — rewritten as explicit sequential sub-steps: Step 5a always commits the measurement + baseline deferral; Step 5b is a conditional follow-up ONLY if the numerical 37,500-LF / 2.0 s gate (named `ScrollbackHistoryAllocationTests.test_throughput_gate`) was exceeded in Step 4. |

### Efficiency findings (`…-simplify-efficiency.md`)

| # | Finding | Disposition |
|---|---------|-------------|
| Efficiency #1 (Track A T2+T3 merge) | Merge DA1/DA2 + CPR into one task | **APPLIED in cbce13e** — old T2 + T3 merged into new T2 "Device Attribute + Cursor Position Responses (DA1 + DA2 + CPR)". Track A 12 → 11 tasks. |
| Efficiency #1 part 2 (T4+T11 merge) | Merge cursorShape + iconName snapshot-field work | **APPLIED in cbce13e** — old T4 Step 4 snapshot-field work split out; old T11 deleted; new combined Task 4 "Expose `cursorShape` + `iconName` on `ScreenSnapshot`" lands both in one Codable migration. Old T4 DECSCUSR parser/model/renderer content stays as new T3. |
| Efficiency #2 | Drop B8 Step 1 intermediate commit | **SKIPPED per instructions** — the intermediate commit is the baseline measurement step which the remediation explicitly restructured to preserve observability. Keeping the measurement-hook commit is worth the 15 min of review overhead. |
| Efficiency #3 | Byte-level `Data.csi` / `Data.osc` test helpers | **APPLIED in 3398cf5** — shipped as part of Track B Task 0 (`TestHelpers.swift`). Parser/writeback tests in Track A T2, T8, T10 rewritten to use `.csi(…)` / `.osc(…)` literals — ~20 hand-assembled byte arrays eliminated. |
| Efficiency #4 | Track A Task 12 palette file-path correction | **APPLIED in d60b600** — `TermCore/TerminalPalette.swift` corrected to `rTerm/TerminalPalette.swift` in Files list, Step 1 verified-bullet, Step 2 prose, and git-add line. Verified against the source truth. |
| Efficiency #5.1 | Merge Hygiene T5 (doc comment) into T3 (file split) | **APPLIED in cbce13e** — T5 deleted; ordering-invariant doc comment for `publishHistoryTail` attaches to the moved method in T3 Step 3. Track B 10 → 9 numbered tasks (Track B preserves the same item coverage; one task header removed). |
| Efficiency #5.2 | Pre-resolve "grep to find out" steps | **APPLIED in 0f003e3** — `rTerm/TermView.swift:148` → `preferredFramesPerSecond = 60` pre-resolved for Task 5 (blink); no `maxBuffersInFlight` / `DispatchSemaphore` in `RenderCoordinator.swift` pre-resolved for Task 7 (Metal ring); palette-infrastructure snapshot pre-recorded for Task 11 (palette). B3 Step 1 `rg \\bScrollRegion\\b` audit is a legitimate implementer check, left in place. |

---

## Commit SHAs

| Batch | Commit | Subject |
|------|--------|---------|
| 1 | `d60b600` | phase 3 simplify 1/5: correctness fixes (OSC 52 signatures, palette file path, cross-refs) |
| 2 | `cbce13e` | phase 3 simplify 2/5: merge redundant tasks (DA1/DA2/CPR, snapshot fields, doc comment) |
| 3 | `3398cf5` | phase 3 simplify 3/5: shared test helpers (LockedAccumulator, Data.csi, Data.osc) |
| 4 | `18a39db` | phase 3 simplify 4/5: unified sinks + dependency table + perf-counter consolidation |
| 5 | `0f003e3` | phase 3 simplify 5/5: narrative cleanup + verification-appendix + pre-resolved greps |

Summary commit for this document: follows as `phase 3 simplify applied summary`.

---

## Deliberate skips (from the simplify-instruction skip list)

- **Reuse #4** — Hyperlink class vs struct: premature; `distinct hyperlinks per screen` is a future concern. Left as a `Sendable` value struct. Per-cell String copies are acknowledged as an unmeasured tradeoff rather than a plan-time optimization.
- **Quality #3** — Blink / palette / scrolled-hoist manual-verification punts: Blink and palette chooser have legit manual visual components; turning them into uniform/observer tests is real Phase 3 implementation effort, not plan simplification. Scrolled-hoist exception was not picked up in Batch 1 (correctness-only scope); could be revisited.
- **Efficiency #2** — Track B T7 Step 1 intermediate commit: the measurement hook is load-bearing for the observability story and the 15 min of review overhead is justified.

---

## Improvisations

None of the applied findings required improvisation from the designed approach. All target outputs (shared test helpers, unified output sink, dependency table, perf-counter consolidation, verification appendix, pre-resolved greps) landed as specified by the three research documents and the simplify-instruction batches.

One minor departure from the strict letter of the instructions: Track B's task count remained 10 numbered headers (T0–T9) rather than dropping to 9, because the new Task 0 (TestHelpers prerequisite) was added as an earlier entry. The underlying simplify goal — "single doc-comment task folded into file-split" — was achieved; the numbering convention (pre-0 insertion rather than shift-everything-down) kept every downstream cross-reference in the plan stable.
