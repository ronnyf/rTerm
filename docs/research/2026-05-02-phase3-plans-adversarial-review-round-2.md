# Phase 3 Plans — Round-2 Adversarial Review

- **Date:** 2026-05-02
- **Reviewer role:** Adversarial — find defects introduced by the `/simplify` pass.
- **Plans reviewed:**
  - `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md` (Track B, 10 tasks)
  - `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` (Track A, 11 tasks)
- **Priors:**
  - Round-1 review: `docs/research/2026-05-02-phase3-plans-adversarial-review.md`
  - Round-1 remediation: `docs/research/2026-05-02-phase3-plans-remediation-summary.md`
  - /simplify application: `docs/research/2026-05-02-phase3-plans-simplify-applied-summary.md`
- **Source truth for API verification:** `/Users/ronny/rdev/rTerm/` on branch `phase-2-control-chars`.

---

## 1. Blocking defects

### 1.1 Track A Task 2 — tests call `installWritebackSink`, the API the /simplify pass removed

**Location:** features plan, Task 2 Step 5 (`TermCoreTests/DeviceAttributesTests.swift`), lines 455, 464, 477, 487.

**Defect.** The /simplify unification (commit `18a39db`) replaced `installWritebackSink` with `installOutputSink(_:)` that takes a `ScreenModelOutput` event. Task 2's four test bodies still call the old symbol:

```swift
model.installWritebackSink { sink.append($0) }   // four occurrences
```

Two compile errors per site:
1. No method named `installWritebackSink` on `ScreenModel` — Task 1 only adds `installOutputSink`.
2. Even if the method existed, the closure body `{ sink.append($0) }` expects `$0: Data` because `DataSink.append` is `func append(_ more: Data)` (hygiene plan, line 84). After the unification `$0` is `ScreenModelOutput`, not `Data`.

**Tool-verified sources.**
- `rg -n "installWritebackSink" docs/superpowers/plans/` → four hits, all in features plan Task 2 Step 5.
- `rg -n "installOutputSink|installWritebackSink" docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` — shows `installOutputSink` is the sole sink install API declared in Task 1 (line 147).
- `DataSink.append(_ more: Data)` is defined in hygiene plan Task 0 Step 1 (lines 84–87).

**1-line fix.** Replace every `model.installWritebackSink { sink.append($0) }` with:
```swift
model.installOutputSink { if case .ptyWriteback(let d) = $0 { sink.append(d) } }
```
Must be prefixed by `await` too (see defect 1.2).

---

### 1.2 Track A Task 1 + Task 2 + Task 10 — `installOutputSink` called without `await`

**Location:** features plan, Task 1 Step 4 (line 221), Task 2 Step 5 (lines 455, 464, 477, 487 if they switch to the unified API), Task 10 Step 8 (line 2034).

**Defect.** `installOutputSink` is declared on a public actor without `nonisolated`:
```swift
public func installOutputSink(_ sink: @escaping @Sendable (ScreenModelOutput) -> Void)
```
(features plan, line 147.) Calling this from outside the actor requires `await` or `assumeIsolated`. Task 1 Step 4 test at line 221:
```swift
model.installOutputSink { event in received.append(event) }
```
…is in an `async func` but has no `await`. Compile error: "actor-isolated instance method 'installOutputSink' cannot be referenced from a nonisolated context."

Same issue on line 2034 (Task 10 Step 8).

**Tool-verified sources.**
- features plan line 147: `public func installOutputSink(_ sink: @escaping @Sendable (ScreenModelOutput) -> Void)` — no `nonisolated`.
- `ScreenModel` is `public actor` (verified `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift:49`).
- `rg -n "model\.installOutputSink" docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` → 5 hits; none carry `await` prefix on the test sites (line 221, 2034).

**1-line fix.** Either (a) prefix every test call with `await`, or (b) mark `installOutputSink` as `nonisolated` and guard `_outputSink` with a `Mutex`. Prior blocker 1.3 from round 1 was fixed via `assumeIsolated` in the daemon; this regression is new to the test surface.

---

### 1.3 Track A Task 1 — `ScreenModelOutput` enum + `Session` switch reference types that do not exist at Task 1 commit boundary

**Location:** features plan, Task 1 Step 1 (`ScreenModelOutput.swift`, line 112) and Step 3 (Session install code, lines 183-189).

**Defect.** The Task 1 `ScreenModelOutput` enum declares:
```swift
case clipboardWrite(targets: ClipboardTargets, base64Payload: String)
```
But `ClipboardTargets` is only created in Task 10 Step 1 (features plan line 1829). A Task 1 commit would fail: "cannot find type 'ClipboardTargets' in scope."

Same issue in the Session switch at Task 1 Step 3:
```swift
case .clipboardWrite(let targets, let base64Payload):
    self.broadcast(.clipboardWrite(sessionID: self.id,
                                    targets: targets,
                                    base64Payload: base64Payload))
```
References `DaemonResponse.clipboardWrite` which is added in Task 10 Step 4 (line 1899).

The plan's footnote at line 195 says "the switch can temporarily omit `.clipboardWrite` (or include a `@unknown default` in the compile-matrix)." Both escapes fail:
- Omitting a case in a switch over a non-`@frozen` module-internal enum is a non-exhaustive switch — compile error.
- `@unknown default` only satisfies exhaustiveness for `@frozen` public enums from *other modules*; `ScreenModelOutput` is declared in the same module with no `@frozen` attribute.

**Tool-verified sources.**
- features plan Task 1 Step 1 `ScreenModelOutput.swift` at line 103-113: `public enum ScreenModelOutput: Sendable` (no `@frozen`).
- `rg -n "^public enum|public struct ClipboardTargets" docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` — `ClipboardTargets` declared at line 1829 (Task 10 Step 1).
- `rg -n "DaemonResponse.clipboardWrite|case clipboardWrite" docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` — `.clipboardWrite` enum case on `DaemonResponse` added at line 1899 (Task 10 Step 4).

**1-line fix.** Either (a) move `ClipboardTargets.swift` + `DaemonResponse.clipboardWrite` into Task 1's Files list and Step 1, or (b) introduce `ScreenModelOutput` with only `.ptyWriteback` in Task 1 and extend with `.clipboardWrite` in Task 10 Step 1. Option (b) aligns with Task 10's Files list which already modifies `OSCCommand.swift`, `DaemonProtocol.swift`, and `ClipboardTargets.swift` together.

---

### 1.4 Track B Task 6 — `PerfCountersDebug.swift` target location contradicts itself within one step

**Location:** hygiene plan, Task 6 Step 1 — Files list says `TermCore/PerfCountersDebug.swift` (line 1031); the Step 1 code block says "Create `rTerm/PerfCountersDebug.swift`" (line 1041) with file header comment `//  rTerm` (line 1046); then a reconciliation paragraph at lines 1091-1093 presents two conflicting prescriptions:

> "Add the file to the **rTerm app target** — `PerfCountersDebug` is … visible to `TermCore` for the Row-allocation increment in `ScreenModel.scrollAndMaybeEvict`. Since TermCore is a framework that rTerm imports (not the other way around), place the counter write site in TermCore too — use the same name but declared in `TermCore/PerfCountersDebug.swift` OR have TermCore export its own counter…"

Followed by:

> "**Layering note:** simplest layout is `TermCore/PerfCountersDebug.swift` because TermCore's `ScrollbackHistory` needs to write one of the counters."

Three contradictory prescriptions in one step. This is a P10 narrative-execution regression — mirrors the Task 3 access-control narrative that round-1 blocker 1.12 flagged and remediation commit `0f42a77` fixed. The `/simplify` pass reintroduced the same pattern when it unified three counters into one file.

**Concrete compile hazard.** Task 9 (`ScrollbackHistory` row-allocation counter) writes from inside `TermCore` (line 1793: `#if DEBUG PerfCountersDebug.rowAllocationCount += 1 #endif`). If the file lives in the rTerm target, TermCore cannot see the type — TermCore is a framework that rTerm imports, not the reverse.

**Tool-verified sources.**
- hygiene plan, Files list line 1031: `TermCore/PerfCountersDebug.swift`.
- hygiene plan, Step 1 code at line 1041: `Create rTerm/PerfCountersDebug.swift` (file header `// rTerm`).
- hygiene plan, reconciliation paragraph lines 1091-1093: two contradictory locations.
- hygiene plan, Task 9 Step 1 line 1793: `PerfCountersDebug.rowAllocationCount += 1` written from inside `TermCore/ScrollbackHistory.swift`.

**1-line fix.** Delete the "Create `rTerm/PerfCountersDebug.swift`" code block; keep only the `TermCore/PerfCountersDebug.swift` version. Remove the narrative paragraph at 1091-1093 that presents it as an open decision.

---

### 1.5 Track A Task 7 DECCOLM tests — read actor state without `await`

**Location:** features plan, Task 7 Step 3 (lines 1171, 1178).

**Defect.**
```swift
#expect(model.pendingCols == 132)   // line 1171
#expect(model.pendingCols == 80)    // line 1178
```
`ScreenModel` is a `public actor`; `pendingCols` is declared `public private(set) var pendingCols: Int? = nil` on the actor (line 1138). Reading an actor stored property from outside the actor requires `await`. The surrounding `@Test` functions are `async` — adding `await` compiles; without it, "expression is 'async' but is not marked with 'await'".

**Tool-verified sources.**
- features plan Task 7 Step 2 line 1138 declares `public private(set) var pendingCols: Int?` on the actor.
- `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift:49` confirms `public actor ScreenModel`.
- Round-1 patterns for similar reads (e.g., Task 1 Step 4 test uses `await model._testEmitWriteback(...)` explicitly, features plan line 222) show the convention is `await`-prefixed.

**1-line fix.** Both `#expect` lines: prefix `model.pendingCols` with `await` or capture `let pending = await model.pendingCols` first.

---

## 2. Significant risks

### 2.1 Track B Task 7 — stale cross-reference "preamble from Task 7"

**Location:** hygiene plan, line 1587.

**Content.** "Call `ensureRings(cols: cols, rows: rows)` at the top of `draw(in:)` (right after the `removeAll(keepingCapacity:)` preamble from Task 7)."

This text is inside **Task 7** itself. The `removeAll(keepingCapacity: true)` preamble is defined in **Task 6** Step 3 (line 1164). Remediation-era renumbering left a stale reference. An implementer of Task 7 will look for a "preamble from Task 7" that doesn't exist.

**Fix.** Change "from Task 7" to "from Task 6".

---

### 2.2 Track A Task 4 — hand-coded `encode(to:)` fragment is incomplete

**Location:** features plan, Task 4 Step 2 (lines 755-767).

**Content.** The plan shows only two lines of `encode(to:)`:
```swift
try container.encode(cursorShape, forKey: .cursorShape)
try container.encodeIfPresent(iconName, forKey: .iconName)
```

But the current `ScreenSnapshot` at `/Users/ronny/rdev/rTerm/TermCore/ScreenSnapshot.swift` has NO hand-coded `encode(to:)` — it has hand-coded `init(from:)` (line 105) plus synthesized `encode(to:)`. Task 4 switches the decoder from synthesized-partial to hand-coded, and its shown fragment implies only *appending* the new keys. An implementer who follows the fragment literally will leave `encode(to:)` still synthesized, producing inconsistent Codable.

**Fix.** Spell out the full 14-key `encode(to:)` implementation explicitly, or keep `encode(to:)` synthesized and decode only (since Swift synthesizes `encode` from every stored property).

---

### 2.3 Track A Task 7 Step 4 — `clearPendingCols()` declared "nonisolated" cannot mutate actor stored state

**Location:** features plan, Task 7 Step 4 (line 1230).

**Content.** "…and calls `session.screenModel.clearPendingCols()` (a new nonisolated function that resets the pending flag)."

If `clearPendingCols()` is `nonisolated`, Swift forbids it from mutating `pendingCols` (actor-isolated stored property). The plan gives contradictory requirements. Likely fix is to make it a regular actor-isolated `func` and reset from an `async` hop in the SwiftUI `onChange`, or wrap `pendingCols` in a `Mutex` and declare both reader and clearer `nonisolated`. The plan does not choose.

**Fix.** Specify one implementation path.

---

### 2.4 Track A Task 2 — `sink.all()` pattern assumes single emit is one `Data` blob

**Location:** features plan, Task 2 Step 5 (lines 457, 466, 480, 493).

**Content.** After `await model.apply([.csi(.deviceAttributes(.primary))])`, `#expect(sink.all() == .csi("?1;2c"))` expects exactly one emit. With the unified sink, routing multiple writeback events to the same sink would concatenate. This matches the DA1/DA2/CPR single-emit-per-query shape. OK — but only if the test fix for 1.1 filters `.ptyWriteback` into the `DataSink` rather than storing raw `ScreenModelOutput` events.

**Fix — depends on 1.1 resolution.** Once 1.1's fix is in place, this pattern works.

---

### 2.5 Track A Task 1 Step 3 — install-once semantic is not gated against the event handler firing twice

**Location:** features plan, Task 1 Step 3 (lines 165-193).

**Content.** `installOutputSink` has `precondition(_outputSink == nil)` but the Step 3 sample shows the install inside `startOutputHandler()`, before the dispatch source is installed. Reading Session.swift (line 199) shows `screenModel.assumeIsolated { model in model.apply(events) }` is *inside* the dispatch source event handler, which fires per-read. If the plan's sink install is accidentally placed inside the same `setEventHandler` closure, the precondition traps on the second byte read. The plan's guidance "after the precondition checks and before installing the dispatch source" is correct but easy to misread.

**Fix.** Explicit sub-step: "Install the sink OUTSIDE the `source.setEventHandler` closure — the install executes exactly once per session, not per byte read."

---

### 2.6 Track A Task 11 — `AppSettings.paletteName` setter cross-actor visibility

**Location:** features plan, Task 11 Step 2 (lines 2181-2192).

**Content.** `AppSettings` is `@Observable @MainActor public final class`. `@AppStorage` + computed setter fires `palette = TerminalPalette.preset(named: newValue) ?? .xtermDefault`. SwiftUI observers react via the `@Observable` macro tracking `palette`, not the computed `paletteName`. In practice this works in most apps, but the plan's commit message claims "observers … pick up changes without extra wiring" — verify empirically in an Xcode scratch run before landing. Remediation summary §2.5 flagged this as a risk; still unresolved.

---

## 3. Regression check — original 16 blockers

Spot-checks against the post-/simplify plan text:

| # | Blocker | Check | Status |
|---|---------|-------|--------|
| 1.1 | `active.cursor = …` direct assignment | `rg -n "active\.cursor\s*=" docs/superpowers/plans/` → empty | ✓ still fixed |
| 1.4 | `fanOutResponse` non-existent method | `rg -n "fanOutResponse" docs/superpowers/plans/` → 1 hit, the appendix documenting "does not exist" | ✓ still fixed |
| 1.7 | solarized presets missing | `rg -n "solarizedDark\|solarizedLight" docs/superpowers/plans/` → canonical Schoonover 16-slot RGB table present at lines 2116-2153; `preset(named:)` + `allPresetNames` at 2163-2175 | ✓ still fixed |
| 1.11 | `ClipboardTargets` OptionSet | `rg -n "OptionSet" docs/superpowers/plans/` → `public struct ClipboardTargets: OptionSet, Sendable, Equatable, Codable` at line 1829; `parse(_:)` reads every xterm letter | ✓ still fixed |

All four spot-checks hold. The remediation pass's fixes for the original 16 blockers are intact.

---

## Summary

**5 blocking defects** introduced or left unresolved by the /simplify pass:
- **1.1** — Task 2 tests call removed `installWritebackSink` (4 sites).
- **1.2** — Task 1, Task 2, Task 10 test sites call actor-isolated `installOutputSink` without `await`.
- **1.3** — Task 1 references `ClipboardTargets` + `DaemonResponse.clipboardWrite` that aren't landed until Task 10.
- **1.4** — Task 6 `PerfCountersDebug.swift` target location contradicts itself within one step (P10 regression).
- **1.5** — Task 7 DECCOLM tests read actor `pendingCols` without `await`.

**6 significant risks** — narrative or unverified.

**4 regression spot-checks from original 16 — all clean.** The /simplify pass preserved every round-1 fix.

Neither plan should execute as-is; all five blocking defects compile-fail.
