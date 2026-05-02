# Adversarial Retrospective — Phase 1 + Phase 2 Plans as Written

- **Date:** 2026-05-02
- **Reviewer role:** Adversarial — identify defects that existed *in the plans at write time*, using the post-hoc research docs as ground truth.
- **Plans reviewed:**
  - `/Users/ronny/rdev/rTerm/docs/superpowers/plans/2026-04-30-control-chars-phase1.md` (landed `main` as squash commit `cef6d91`)
  - `/Users/ronny/rdev/rTerm/docs/superpowers/plans/2026-05-01-control-chars-phase2.md` (landed as branch `phase-2-control-chars`, PR #5)
- **Reference catalog:** `/Users/ronny/rdev/rTerm/docs/research/2026-05-02-phase3-plans-adversarial-review.md` (16 Phase 3 blockers across 7 categories).

---

## Part A — Phase 1 plan defects

There are **no per-task research docs for Phase 1**. Phase 1 landed in a single squash-merge commit (`cef6d91`, "Phase 1: ANSI/VT control characters + truecolor renderer (#4)") rather than the one-commit-per-task discipline the plan's self-review promised. The Phase 1 plan has no audit trail; defects had to be silently corrected by the implementer at commit time. The absence of Phase 1 per-task research is itself **Finding A0**: there is no evidence the Phase 1 plan was adversarially reviewed at all — the same plan-author/reviewer blindspots that show up in Phase 2 T3–T10 certainly existed in Phase 1 but went unrecorded.

Reviewing the plan cold against the landed source on `main`:

### A1 — `AttachPayload` top-level `typealias Row` (plan line 1955) vs. nested in landed code

The plan's Task 7 Step 2 writes:
```swift
public typealias Row = ContiguousArray<Cell>

public struct AttachPayload: Sendable, Codable { … }
```
with `Row` declared at **module/file scope**. The landed `TermCore/AttachPayload.swift:33` nests it inside `AttachPayload`: `public typealias Row = ContiguousArray<Cell>`. Phase 2 T6 then re-declares `public typealias Row = ContiguousArray<Cell>` **again** inside `ScrollbackHistory` (`TermCore/ScrollbackHistory.swift:33`). The module now has two independently-named `Row` typealiases. Had the plan been executed literally, the module-level `Row` would have collided with the later `ScrollbackHistory.Row`. The implementer silently fixed this by nesting. **Category: api-mismatch.**

### A2 — `AttachPayload` conformances mismatch: plan says `Sendable, Codable`, landed has `Sendable, Equatable, Codable`

Plan line 1962 declares `AttachPayload: Sendable, Codable`. Landed `TermCore/AttachPayload.swift:30` is `Sendable, Equatable, Codable`. Without `Equatable`, the Phase 2 T6 test `test_attach_payload_populates_history` (which builds a payload and compares fields) would compile only because it compares individual properties rather than the whole struct — but the plan's own Task 7 Step 7 `attach_payload_roundtrip` test already compares `decoded.snapshot == payload.snapshot`, not the whole payload, so it narrowly escapes. **Category: api-mismatch / plan-sketch.**

### A3 — `handleOSC` return-type oscillation across tasks (Task 6 vs. Task 7)

Task 6 Step 3 defines `private func handleOSC(_ cmd: OSCCommand)` returning `Void` (plan line 1775), and the plan explicitly notes "Task 7 rewrites it to return `Bool`" (plan line 1787). Task 7 Step 3 then redefines it returning `Bool`. Writing code that will be replaced one task later is benign for documentation but is a **plan-sketch** defect: any controller building tests against Task 6's output under cross-task parallelism is racing Task 7's signature. Task 6's `ScreenModel.apply(_:)` dispatch at plan line 1790 uses `case .osc(let cmd): handleOSC(cmd)` — which has to be rewritten to `changed = handleOSC(cmd) || changed` in Task 7. **Category: plan-sketch / task-ordering.**

### A4 — Task 4 handleCSI writes to `cursor` and `savedCursor` as if they're instance fields, but Phase 1's state shape doesn't include a `savedCursor` yet

Plan line 1225 adds `private var savedCursor: Cursor?` to `ScreenModel`, but Task 5 Step 3 later writes `pen = .default` when the `private var pen: CellStyle = .default` hasn't been introduced either — these fields are introduced implicitly mid-task. Task 2 Step 8 wrote `grid[cursor.row * cols + cursor.col] = Cell(character: char)` (plan line 655) with `cursor` as a direct field. Task 4 Step 4 then writes to `cursor.row`, `cursor.col`, `cursor` wholesale (plan lines 1201-1225). Task 7 Step 3 rewrites it again, this time wrapping all cursor mutation in `buf.cursor` under a `mutateActive` closure. **Category: plan-sketch** — the plan leaks mutable-state shape across task boundaries and the final consolidation happens only at Task 7.

### A5 — Task 3 VTState enum omits `pendingST` — the OSC state machine can't signal "`ESC` seen, waiting for `\`" without it

Plan line 821 defines `oscString(ps: Int?, accumulator: String)` with no `pendingST: Bool` field. Phase 1's plan also shows `case dcsIgnore` with no state. But the landed parser (verified via `git show cef6d91 -- TermCore/TerminalParser.swift`) uses `oscString(ps: Int?, accumulator: String, pendingST: Bool)` — the `pendingST` flag exists in landed code because the state machine has to distinguish "payload char" from "ESC seen, maybe ST follows" mid-OSC. Without this distinction the plan's state machine would either emit OSC on spurious `\` bytes or fail to terminate on `ESC \`. The plan's pseudocode "append until BEL or ESC \\ ST, then emit" (plan line 867) glosses the two-byte terminator but the enum doesn't carry the transient state it needs. **Category: vt-semantics / compile.** The implementer silently fixed this.

### A6 — `ScreenSnapshot.activeCells` in plan vs. pre-existing `ScreenSnapshot.cells` in repo — no audit of existing call sites

Plan Task 7 Step 1 replaces the definition of `ScreenSnapshot` without mentioning that the pre-existing `ScreenSnapshot` was defined in `TermCore/Cell.swift` (plan line 1878: "or wherever `ScreenSnapshot` currently lives — check `Cell.swift`"). The plan author didn't read the existing file. Then Task 7 Step 7 says to run `rg -n "ScreenSnapshot\(cells:|\.cells\b"` to find hits — but the audit is post-hoc, run during implementation. The plan should have inventoried the existing shape and consumers at authoring time. **Category: plan-sketch / api-mismatch.** This is the same class as Phase 3 Track A Task 6 Defect 1.1 ("active is a get-only property") — the plan author substituted what the API "should" be for what it actually is.

### A7 — No Swift 6 migration consequence inventory for Task 0

Task 0 Step 4 says "likely a handful in `ScreenModel`, `DaemonClient`, `TerminalSession`" will need Sendable fixes after the Swift 6 bump. No pre-flight survey was produced; the plan describes a fix-forward loop ("dispatch a fix-focused implementer subagent with the reporter's findings"). Swift 6 strict-concurrency errors can cascade across the module graph; the plan should have named the expected sites (e.g., `DaemonPeerHandler`, `Session.swift`'s XPC closures) so that the implementer could prepare the fix in one pass. **Category: plan-sketch / concurrency.**

### A8 — Integration test fixture `vimStartupSequence` contains stale Phase-1 comments that carry forward as stale into Phase 2 (captured in T4 spec review)

Plan line 2849-2851 introduces the fixture with "Phase 1 ScreenModel ignores the mode event" as the comment. The T4 spec review (`2026-05-01-t4-spec-review-empirical-findings.md:135-144`) documents that these comments remained in the source after Phase 2 wired up alt-screen. Plan-authored stale documentation propagated through Phase 2 because the implementer faithfully copied the plan's fixture text. **Category: plan-sketch** — the plan embedded phase-bound comments in code that would survive phases.

### A9 — `Task 9` fixtures assert `snap[0, 0].style.foreground == .ansi16(4)` but Task 8 (renderer) is already "complete" in the plan before Task 9

Tasks 8 (Step 6-8) covers renderer + shader work. Task 9 (`TerminalIntegrationTests`) asserts the parse-and-model path. The plan orders them 8 → 9, but Task 9 has no dependency on the renderer; Task 9 could have run in parallel with any model-layer task. **Category: task-ordering** — not a blocker, but an un-acknowledged concurrency seam.

### A10 — Self-review claim "One commit per task — 9 commits total" (plan line 2959) is false at landing time

Phase 1 landed as a **single squash-merge commit** (`cef6d91`). `git log --oneline main -- TermCore/` shows no per-task commits for Phase 1. The plan's self-review assertion was not enforced. This is a process-discipline defect in the plan's execution contract: the plan *asserts* the controller will dispatch per-task, but the actual landing discarded that granularity. **Category: plan-sketch (process).**

### A-summary

10 defects found in the Phase 1 plan without research-doc support. They split roughly: **4 api-mismatch / compile** (A1, A2, A5, A6), **3 plan-sketch** (A3, A4, A7), **1 vt-semantics** (A5 overlap), **2 process** (A8, A10), **1 task-ordering** (A9). The implementer silently corrected every one of them at commit time; the squash merge hid this work.

---

## Part B — Phase 2 per-task plan defects (T3–T10)

T1 and T2 have no research docs; the Phase 2 plan's "spec-extending decisions" mention T1 corrections inline (e.g., compound DECSET multi-emit) but no post-hoc review exists. I surveyed T1 directly (plan §Task 1) and found no blocking defects — the `appendCSIEvents` dispatcher design is sound and the parser tests exercise it. T2 similarly appears coherent cross-referenced against Phase 2's `2026-05-01-phase2-final-review-empirical-findings.md` Q1.

| Task | Plan defect | Research citation | Category |
|------|-------------|-------------------|----------|
| T3 | Plan Step 10 prose claims "all 9 new tests pass" but the Step 8 code block contains **8** tests (off-by-one in plan summary). | `2026-05-01-t3-spec-review-empirical-findings.md:128` | plan-sketch / test-is-noop (would false-fail on CI gate) |
| T3 | Plan Step 6 `handlePrintable` has `buf.cursor.col += 1` unconditional; implementer had to gate on `autoWrap` to prevent cursor transiently exceeding grid. Plan left DECAWM-off cursor transiently at col == `cols`. | `2026-05-01-t3-spec-review-empirical-findings.md:70-85` | vt-semantics / runtime |
| T3 | `BufferKind` plan didn't specify `String` raw type; implementer added it to make the Phase-1 back-compat JSON test pass. Landed code has `BufferKind: String, Sendable, Equatable, Codable`. | `2026-05-01-t3-spec-review-empirical-findings.md:91-104` | wire-compat |
| T4 | Plan `test_alt_screen_1047_cursor_persists_across_re_entry` wrote `cursorPosition(row:1, col:3)` which triggers deferred wrap on `cols=4`; the plan's final assertion `reentered.cursor.col == 3` would have failed because `snapshotCursor` returns `(2, 0)` after wrap. Implementer moved to `col:2`. | `2026-05-01-t4-spec-review-empirical-findings.md:64-74` | vt-semantics / test-is-noop |
| T4 | Plan `test_save_restore_per_buffer` expected `(0,0)` at step 8, but 1049 enter overwrites `main.savedCursor` from the prior `CSI s`. Plan author did not trace through DECSC/1049 single-slot sharing. Implementer asserted `(1,2)` with a documented rationale. | `2026-05-01-t4-spec-review-empirical-findings.md:77-93` | vt-semantics |
| T5 | **Documented plan correction** inline. Step 4 `scrollWithinActiveBounds` else branch said "Clamp without scrolling" — contradicts the plan's own `test_decstbm_lf_below_region_does_full_screen_scroll` which requires full-screen scroll when cursor overflows *outside* the region. Dispatcher trigger was `cursor.row >= rows`-only; implementer broadened to include `cursor.row > scrollRegion.bottom`. | `2026-05-01-t5-spec-review-empirical-findings.md:15-101` | vt-semantics / runtime (plan internally inconsistent with its own test) |
| T5 | Plan's `scrollWithinActiveBounds` compared `cursor.row - 1 == region.bottom` against cursor.row == 5 vs region.bottom == 3 — false; the else branch was the only path for region-external overflow, and it was wrong. Only surfaced by tracing the test manually. | `2026-05-01-t5-spec-review-empirical-findings.md:28-57` | vt-semantics |
| T6 | Plan `test_history_capacity_evicts_oldest` iteration had a setup bug: after the first scroll, subsequent iterations' printables land in row 1 (cursor left there) so the next LF evicts empty rows, not the letters. Implementer added `.csi(.cursorPosition(row:0,col:0))` at iteration start. | `2026-05-01-t6-spec-review-empirical-findings.md:174-189` | vt-semantics / test-is-noop |
| T6 | Same setup bug in `test_restore_payload_seeds_history`. | `2026-05-01-t6-spec-review-empirical-findings.md:190-194` | vt-semantics / test-is-noop |
| T6 | Plan didn't list `TermCore/CircularCollection.swift` in allowed files, but Swift 6 strict concurrency required adding `Sendable` conditional conformance with `where Container: Sendable, Container.Index: Sendable` for `ScrollbackHistory` to compile. | `2026-05-01-t6-spec-review-empirical-findings.md:200-212` | concurrency / plan-sketch |
| T7 | Plan Step 2 prefixed each test with per-function `@MainActor`; implementer used struct-level `@MainActor` on `KeyEncoderTests`. Semantically equivalent but illustrates plan-author didn't verify Swift Testing's preferred style. | `2026-05-01-t7-spec-review-empirical-findings.md:220-231` | plan-sketch (stylistic) |
| T7 | No additional blocking defects — the reordering (keyCode switch before ctrl+letter) was spec-mandated and correctly implemented. | `2026-05-01-t7-spec-review-empirical-findings.md:78-92` | — |
| T8 | Plan code block omitted `nonisolated` on `TerminalSession.bracketedPasteWrap(_:enabled:)` but the test file required it (class is `@MainActor`, test wasn't). Implementer added `nonisolated` silently. | `2026-05-01-t8-spec-review-empirical-findings.md:47-52` | concurrency |
| T8 | Plan code block used `@objc override func paste(_ sender: Any?)` — `override` on `paste(_:)` is a compile error because `NSResponder`/`NSView`/`MTKView` do not declare it; `paste(_:)` is an informal-protocol selector. Plan author did not verify against SDK headers. | `2026-05-01-t8-spec-review-empirical-findings.md:76-100` | compile / api-mismatch |
| T8 | Same defect for `validateMenuItem(_:)` — it's a protocol requirement (`NSMenuItemValidation`), not an inherited method. `override` is invalid. Implementer dropped `override` and replaced `super.validateMenuItem(menuItem)` with `return true`. | `2026-05-01-t8-spec-review-empirical-findings.md:101-114` | compile / api-mismatch |
| T9 | Plan's Goal section (line 3258) said "multiply fg **alpha** by 0.5" for dim (SGR 2). Step 3 code block contradicted itself: "Dim modifies the RGB channels (a darker color), not alpha" — the code implements RGB multiplication. The Goal section is wrong per xterm semantics. | `2026-05-01-t9-spec-review-empirical-findings.md:60-71` | vt-semantics (plan internally inconsistent) |
| T9 | Plan's strikethrough `reserveCapacity` snippet used `floatsPerCellVertex` (glyph size, 12) instead of `floatsPerOverlayVertex` (overlay size, 8). Silent copy-paste error; implementer used `floatsPerOverlayVertex`. | `2026-05-01-t9-spec-review-empirical-findings.md:106` | plan-sketch / runtime |
| T10 | Plan Step 3 comment "Expected: 9 tests pass"; Step 2 code block contains 10 `@Test` functions. Same class as T3 off-by-one. | `2026-05-01-t10-spec-review-empirical-findings.md:65-84` | plan-sketch / test-is-noop |
| T10 | Plan Step 1 omitted `nonisolated` on `struct ScrollViewState: Sendable, Equatable`; rTerm target defaults to `@MainActor` isolation, so the test target would fail to call construction off the main actor without `nonisolated`. | `2026-05-01-t10-spec-review-empirical-findings.md:32-45` | concurrency |
| T10 | Plan code block would have resulted in duplicated closure in `makeNSView` and `updateNSView`; implementer extracted `makeCursorKeyModeProvider()`. Not strictly a defect but illustrates the plan's prescription didn't anticipate the DRY tension across the two lifecycle hooks. | `2026-05-01-t10-spec-review-empirical-findings.md:161-179` | plan-sketch |

**Phase 2 plan-defect count: 19** (across T3–T10 only). T5 alone contributed 2; T8 contributed 3; T9 contributed 2. The majority (9/19) are **vt-semantics / test-is-noop**: the plan's example tests, when traced through the VT semantics, produced different state than the plan's assertions expected. This pattern is the same class as Phase 3 defects 1.9 (DECCOLM side effects), 1.10 (OSC 8 grammar), 1.11 (ClipboardTarget set).

---

## Part C — Cross-plan pattern catalog

Each pattern names a class of defect that recurs across Phase 1, Phase 2, and Phase 3 plans.

### P1. Plan-author-guessed API (vs. read actual type)

**Description.** The plan prescribes code that references a symbol that doesn't exist, has a different signature, or has different access control than the plan assumed. The author did not read the actual declaration.

**Exemplars.**
- Phase 1 A6: Plan Task 7 reshapes `ScreenSnapshot` without surveying where it currently lives or what fields call sites already use (`Cell.swift` vs. plan's guess).
- Phase 2 T8: `@objc override func paste(_ sender: Any?)` — `paste` is not on any superclass. Verified against SDK headers.
- Phase 3 defect 1.1: `active.cursor = …` where `active` is a get-only computed property (`ScreenModel.swift:191-193`); the plan author mis-remembered the API.
- Phase 3 defect 1.4: `self.fanOutResponse(.writeback(...))` — method does not exist on `Session`; actual member is `broadcast(_:)`.
- Phase 3 defect 1.6: `coordinator?.glyphMetrics` — accessor does not exist on `RenderCoordinator`.
- Phase 3 defect 1.7: `TerminalPalette.solarizedDark` preset does not exist; only `xtermDefault` is defined.

**Root cause.** Plan author writes against a mental model of the repo rather than doing one `rg` / `Read` per referenced symbol at plan-writing time.

**Mitigation for Phase 3 remediation.** For every type or method name the plan references, run `rg -n "public (struct|enum|func|var) <name>"` once and paste the verified signature into the plan. A "verified in repo" checkbox per symbol.

---

### P2. Plan internally inconsistent with its own example test

**Description.** The plan provides both a test and the code to satisfy it, but tracing the code against the test manually shows they disagree.

**Exemplars.**
- Phase 2 T5: `scrollWithinActiveBounds` else branch says "clamp without scrolling" but `test_decstbm_lf_below_region_does_full_screen_scroll` demands a full-screen scroll.
- Phase 2 T9: Plan Goal says "dim multiplies alpha 0.5" but Step 3 code multiplies RGB — and the test asserts alpha unchanged.
- Phase 3 defect 1.9 (DECCOLM): plan covers "clear + home" but not "reset scroll region + reset origin mode" — required by spec, absent from code and unnoticed because no test exercises them.

**Root cause.** Plan author writes code and tests in different sittings or by different mental models, without executing a dry trace.

**Mitigation for Phase 3 remediation.** Require every plan that includes both code and assertion to have a hand-trace comment below the test (e.g., `// Trace: start state → … → expected state`) that the plan author fills in.

---

### P3. Off-by-one in narrative (prose count ≠ code-block count)

**Description.** The plan's Step N prose says "9 tests pass" but the Step N-1 code block has 8 (or 10). A CI gate that checks "all new tests introduced by task X" will fail or silently pass the wrong count.

**Exemplars.**
- Phase 2 T3: Step 10 prose "9 new tests"; Step 8 code block has 8.
- Phase 2 T10: Step 3 prose "9 tests pass"; Step 2 code block has 10.

**Root cause.** Plan author updated the code block but not the downstream prose (or vice versa).

**Mitigation for Phase 3 remediation.** Any Phase 3 task with "Expected: N tests pass" prose must have `grep -c "@Test" <file>` match the plan number.

---

### P4. VT semantics side effects silently dropped

**Description.** A VT command has multiple spec-mandated side effects (clear grid, home cursor, reset scroll region, reset origin mode, …). The plan covers a subset and silently drops the rest.

**Exemplars.**
- Phase 2 T4 `test_save_restore_per_buffer`: plan didn't account for 1049 enter clobbering prior DECSC save — xterm behavior.
- Phase 2 T6 history-eviction tests: plan's iteration setup didn't re-home cursor, so subsequent LFs evicted empty rows.
- Phase 3 defect 1.9 (DECCOLM): plan missed DECSTBM reset + DECOM off.
- Phase 3 defect 1.11 (ClipboardTarget): plan collapses a multi-char target set (`"cs"`) to the first char, dropping spec-mandated semantics.

**Root cause.** Plan author worked from a summary of VT command semantics, not a primary-source trace through xterm/VT510 spec.

**Mitigation for Phase 3 remediation.** For every VT command added in Phase 3, cite a primary source (vt100.net or xterm ctlseqs) and transcribe the side-effect list into the plan as a checklist. Missing sides = plan defect.

---

### P5. Swift-6 / MainActor isolation mis-specification

**Description.** Plan code block omits `nonisolated` on a value type, static helper, or test suite in a MainActor-defaulting target, producing either a compile error or an isolation mismatch the implementer silently fixed.

**Exemplars.**
- Phase 1 A7: Task 0 doesn't inventory sites that need `nonisolated` or `Sendable` fixes after Swift-6 bump.
- Phase 2 T6: `CircularCollection` had to grow a conditional `Sendable` conformance the plan didn't list.
- Phase 2 T8: `bracketedPasteWrap` had to become `nonisolated` because the test target couldn't call a `@MainActor` static.
- Phase 2 T10: `ScrollViewState` had to become `nonisolated struct` to escape `@MainActor` inference.
- Phase 3 defect 1.3: `model.installWritebackSink` called from nonisolated context without `assumeIsolated`.
- Phase 3 defect 1.13: `DispatchSerialQueue` vs. `DispatchQueue` init overload ambiguity (concurrency-adjacent).

**Root cause.** Plan author wrote Swift 5-style code without running it past Swift-6 strict-concurrency rules; rTerm's MainActor-default makes every nonisolated value type a potential trap.

**Mitigation for Phase 3 remediation.** Every new top-level value type in a rTerm-target file must be marked `nonisolated` OR accompanied by a plan comment explaining why `@MainActor` inference is acceptable. Every test-target file must state its isolation mode.

---

### P6. Cross-task staged state-shape leakage

**Description.** A field/method/type is introduced "as needed" across multiple tasks: Task N introduces `savedCursor`, Task N+1 adds `pen`, Task N+M migrates both to a nested `Buffer` struct. Intermediate commits are internally inconsistent.

**Exemplars.**
- Phase 1 A4: `savedCursor`, `pen`, `iconName`, `windowTitle` all introduced incrementally through Tasks 4–7; Task 2's dispatch signature is rewritten in Task 7.
- Phase 1 A3: `handleOSC` returns `Void` in Task 6, `Bool` in Task 7 — plan acknowledges but ships the churn.

**Root cause.** Plan author optimized for minimal diff per task rather than final-shape-first, which amplifies review effort and makes per-task CI regression tests hard to target.

**Mitigation for Phase 3 remediation.** Each Phase 3 task should land with the final-shape types that subsequent tasks expect, even if some fields are unused until later.

---

### P7. Implicit file-scope escape (new files unlisted)

**Description.** Plan's "Files" block lists only the files the plan author remembered. The implementer has to touch extra files (pbxproj, unrelated Sendable patches, …) to make the task compile.

**Exemplars.**
- Phase 2 T6: `CircularCollection.swift` not in plan's file list but required Sendable fix.
- Phase 2 T3, T9, T10: `rTerm.xcodeproj/project.pbxproj` touched for file registration (plan implicitly assumes Xcode will do this).
- Phase 3 hygiene Task 3 (defect 1.12): plan narrative oscillates on file-split strategy; pbxproj sub-agent is referenced as a "dispatchable worker" that doesn't exist.

**Root cause.** Plan author doesn't do a `git add -A && git status` dry-run against the proposed code.

**Mitigation for Phase 3 remediation.** Every plan's "Files" block must include pbxproj for any task that adds a new file, and must include any adjacent Sendable/actor touchpoints.

---

### P8. Test-is-noop (plan test passes trivially or under wrong assumptions)

**Description.** Plan's "Expected: all tests pass" includes tests whose setup is subtly wrong, so they pass for reasons unrelated to the feature being tested. Or they assert only the end state, not that the feature executed.

**Exemplars.**
- Phase 2 T6: `test_history_capacity_evicts_oldest` evicted empty rows; plan assertion happened to hold because it checked letters not positions.
- Phase 3 defect 1.15: `RenderCoordinator.forTesting(screenModel:)` unconditionally throws; Task 7 and Task 8 both "test" via the factory that skips.
- Phase 3 risk 2.10 (top/htop fixture): asserts only final `activeBuffer == .main`; never asserts alt was entered.

**Root cause.** Plan author writes tests from the top down (assertion first) without executing the setup path.

**Mitigation for Phase 3 remediation.** Every plan test must include explicit intermediate-state assertions, not just the final state. For tests that depend on a factory or hook, the plan must describe how the factory's body makes the hook exercisable — or explicitly mark the test "manual-only."

---

### P9. Wire-compat assertion without Codable shape verification

**Description.** Plan claims "Phase N wire compat preserved" without verifying the JSON shape the existing daemon produces. Auto-derived Codable emits default-valued fields; `decodeIfPresent ?? default` decodes legacy payloads only if the *encoder* side also omits default-valued fields.

**Exemplars.**
- Phase 1 A2: `AttachPayload` conformance list didn't include `Equatable`; wire shape implicit.
- Phase 3 defect 1.14 (CellStyle): plan rewrites auto-derived Codable to hand-coded; wire-compat claim is correct *only* under spec §6's "daemon and client ship together" rule, but the plan's prose misrepresents the prior state.

**Root cause.** Plan author invokes "wire compat" as a slogan without doing a before/after `JSONEncoder().encode` trace.

**Mitigation for Phase 3 remediation.** For every Codable change, the plan must show the before-and-after JSON blob of a canonical instance (e.g., the default-initialized one), plus a round-trip test against a legacy-shaped JSON literal.

---

### P10. Narrative-plan-as-execution (discovery embedded in steps)

**Description.** The plan prose includes "actually, after further thought, let me revise Step 3 to say …" — the plan author discovered a problem while drafting and left the discovery narrative in the plan instead of revising.

**Exemplars.**
- Phase 3 defect 1.12 (Track B Task 3 access-control): three contradictory prescriptions for `Buffer`/`ScrollRegion` visibility in the same step.
- Phase 3 defect 1.16 (Track B Task 10): measurement criterion self-contradicts (pass at 10k LF/s, claim 60 MB/s = 18.75k LF/s).

**Root cause.** Plan author uses the plan as a thinking medium rather than a finished specification.

**Mitigation for Phase 3 remediation.** Scan for "actually," "let me revise," "on further thought," three-paragraph prescriptions for one step. Each step gets one prescription.

---

### P11. Process-contract not enforced (e.g., per-task commits promised, squash delivered)

**Description.** Plan's self-review claims a process discipline that the landing doesn't match.

**Exemplars.**
- Phase 1 A10: "One commit per task — 9 commits total" — landed as `cef6d91` single squash merge.
- No Phase 1 per-task research docs exist — the "dispatch spec-compliance reviewer per task" contract was not honored.

**Root cause.** Execution contract is documented in the plan but nothing outside the plan enforces it. When the controller is a single agent, the discipline collapses under time pressure.

**Mitigation for Phase 3 remediation.** Either drop the "one commit per task" promise or gate each task's completion on a per-task research doc's existence. Phase 2 did the latter (T3–T10 all have 4–5 research docs); Phase 1 did neither.

---

## Part D — Phase 3 remediation priorities

The Phase 3 adversarial review (`2026-05-02-phase3-plans-adversarial-review.md`) enumerated 16 blockers. Cross-classified against Part C patterns:

### Recurring patterns (most remediation-efficient to fix)

| Phase 3 blocker | Pattern | Recurrence |
|------|---------|------------|
| 1.1 (active = …) | **P1 plan-author-guessed API** | Phase 1 A6, Phase 2 T8 |
| 1.2 (`scrollRegion.top ??`) | **P1 plan-author-guessed API** | same as above |
| 1.3 (installWritebackSink no await) | **P5 Swift-6 isolation mis-spec** | Phase 2 T6, T8, T10 |
| 1.4 (fanOutResponse DNE) | **P1 plan-author-guessed API** | |
| 1.6 (glyphMetrics DNE) | **P1 plan-author-guessed API** | |
| 1.7 (palette presets DNE) | **P1 plan-author-guessed API** | |
| 1.9 (DECCOLM side effects) | **P4 VT side effects dropped** | Phase 2 T4 |
| 1.10 (OSC 8 grammar) | **P4 VT side effects dropped** / P1 | new (OSC 8 grammar mis-transcribed) |
| 1.11 (ClipboardTarget set) | **P4 VT side effects dropped** | new (set-semantics) |
| 1.12 (Task 3 access-control) | **P10 narrative-plan-as-execution** | new |
| 1.13 (DispatchSerialQueue overload) | **P5 Swift-6 isolation mis-spec** | Phase 2 T8, T10 |
| 1.14 (CellStyle wire compat) | **P9 wire-compat assertion without verification** | Phase 1 A2 |
| 1.15 (forTesting throws) | **P8 test-is-noop** | Phase 2 T6 |
| 1.16 (20k LF budget math) | **P10 narrative-plan-as-execution** | same as 1.12 |

### New defect classes

- **1.5 (MetalBufferRing no GPU sync)** — Metal triple-buffering semaphore pattern was not on any prior Phase's radar. **New defect class: `gpu-sync`.**
- **1.8 (NSAlert.runModal blocks MainActor)** — AppKit modal loop + async handler interaction; nothing in Phase 1/2 exercised this. **New defect class: `appkit-blocking`.**

### Ranked remediation priorities

1. **P1 plan-author-guessed API** (defects 1.1, 1.2, 1.4, 1.6, 1.7 — **5 blockers**). Fixing this *one* plan defect class would catch **5 of 16 Phase 3 blockers**. Remediation: audit every type/method/property the Phase 3 plans reference against `rg`/`Read`; produce a "symbols verified against repo" table in each plan.
2. **P4 VT side effects dropped** (defects 1.9, 1.10, 1.11 — **3 blockers**). Fix: primary-source citation for every new VT command.
3. **P5 Swift-6 isolation mis-spec** (defects 1.3, 1.13 — **2 blockers**). Fix: every new top-level declaration lands with isolation annotation reviewed.
4. **P10 narrative-plan-as-execution** (defects 1.12, 1.16 — **2 blockers**). Fix: scan for mid-step revisions; rewrite to single prescriptions.
5. **P8 test-is-noop** (defect 1.15 — **1 blocker**). Fix: every "test pins invariant X" claim must be accompanied by an executable (non-skipped) test.
6. **P9 wire-compat** (defect 1.14 — **1 blocker**). Fix: JSON-shape before/after transcripts in the plan.
7. **New classes — gpu-sync, appkit-blocking** (defects 1.5, 1.8 — **2 blockers**). Fix per individually; no accumulated pattern to amortize the work against.

**Bottom line.** Systematically addressing **P1 + P4 + P5 + P10** (one consolidated plan-remediation pass auditing every API reference, every VT semantics claim, every isolation annotation, and every mid-step pivot) would clear **12 of 16 Phase 3 blockers in a single sweep**. The remaining 4 (1.5 GPU sync, 1.8 AppKit modal, 1.14 wire-compat narrative, 1.15 test factory) are independent patches.

---

*Generated by: adversarial retrospective reviewer, 2026-05-02.*
