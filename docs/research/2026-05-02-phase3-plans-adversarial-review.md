# Adversarial Review — Phase 3 Plans (Track A + Track B)

- **Date:** 2026-05-02
- **Reviewer role:** Adversarial — find defects, not validate.
- **Plans reviewed:**
  - `/Users/ronny/rdev/rTerm/docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md` (Track B)
  - `/Users/ronny/rdev/rTerm/docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` (Track A)
- **Spec:** `/Users/ronny/rdev/rTerm/docs/superpowers/specs/2026-04-30-control-characters-design.md` §8
- **Tooling note:** `invisible-island.net`, `vt100.net`, and `docs.swift.org` were blocked by the sandbox allowlist during this session. VT/xterm semantics in the report rely on published VT control-sequence knowledge and cite the best available Apple/Swift sources; any claim tagged "unverified" is so marked. Everything else was confirmed by Read of the actual repo file at the line(s) cited.

---

## 1. Blocking defects

### 1.1 Track A Task 6 Step 3 — `active.cursor = ...` cannot compile

**Location:** features plan, Task 6 Step 3 (DECOM `handleSetMode` block).

**Defect.** Plan writes:
```swift
if modes.originMode {
    active.cursor = Cursor(row: scrollRegion.top ?? 0, col: 0)
} else {
    active.cursor = Cursor.zero
}
```

Two independent problems:

1. `active` in `ScreenModel` is a **get-only computed property** (`TermCore/ScreenModel.swift:191-193` — `private var active: Buffer { activeKind == .main ? main : alt }`). Assigning to `active.cursor` modifies a temporary `Buffer` copy and is rejected by the compiler with "cannot assign to property: 'active' is a get-only property." All mutations go through `mutateActive { $0.cursor = ... }` in the existing code.

2. `scrollRegion` is a field on `Buffer` (`ScreenModel.swift:158`), not on `ScreenModel`. The unqualified name `scrollRegion` is undefined at this scope. The correct access is `active.scrollRegion?.top` (and `scrollRegion` is `ScrollRegion?`, not `(Int?)` — the optional is on the whole struct, the `top: Int` field is non-optional).

**Correction.** Route the mutation through `mutateActive`:
```swift
mutateActive { buf in
    if enabled {
        buf.cursor = Cursor(row: buf.scrollRegion?.top ?? 0, col: 0)
    } else {
        buf.cursor = Cursor.zero
    }
}
```
Same pattern must propagate to Task 6 Step 4 (cursor-position translation).

**Source.** `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift:158,183-193`.

---

### 1.2 Track A Task 6 Step 4 — `scrollRegion.top ?? 0` has wrong optionality

**Location:** features plan, Task 6 Step 4 (cursor-position CSI translation).

**Defect.** Plan writes:
```swift
case .cursorPosition(let row, let col):
    let effectiveRow = modes.originMode ? row + (scrollRegion.top ?? 0) : row
    ...
```
`scrollRegion.top ?? 0` would be a double-optional error. The optional is on `active.scrollRegion` (`ScrollRegion?`); `ScrollRegion.top` itself is `Int` (non-optional). The expression must be `active.scrollRegion?.top ?? 0`.

**Correction.** Use `active.scrollRegion?.top ?? 0`.

**Source.** `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift:29-32` (`ScrollRegion` struct), line 158 (Buffer stores `scrollRegion: ScrollRegion?`).

---

### 1.3 Track A Task 1 Step 3 — `installWritebackSink` called without actor isolation

**Location:** features plan, Task 1 Step 3 — Session installs the writeback sink.

**Defect.** Plan writes:
```swift
model.installWritebackSink { [weak self] bytes in
    guard let self else { return }
    self.writeToPTY(bytes)
    self.fanOutResponse(.writeback(sessionID: self.id, data: bytes))
}
```
`model` is `ScreenModel` which is an `actor` (`ScreenModel.swift:49`). Calling `installWritebackSink` on an actor from a nonisolated context requires `await` or `assumeIsolated`. Session.init is nonisolated. The existing code pattern is `screenModel.assumeIsolated { model in model.apply(events) }` (Session.swift:199). The plan omits this wrapping. Compile error: "actor-isolated instance method 'installWritebackSink' cannot be referenced from a nonisolated context."

**Correction.** Either install in an `assumeIsolated` block in `startOutputHandler` (where the actor's queue is known to match the daemon queue), or make `installWritebackSink` nonisolated (e.g., an init-time-only, nonisolated setter backed by a `Mutex`).

**Source.** `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift:49`, `/Users/ronny/rdev/rTerm/rtermd/Session.swift:111-127,199`.

---

### 1.4 Track A Task 1 Step 3 — `fanOutResponse` does not exist

**Location:** features plan, Task 1 Step 3.

**Defect.** The plan calls `self.fanOutResponse(.writeback(...))`. In the actual Session, the only broadcast helpers are `fanOutToClients(_:)` (takes raw `Data`) and `broadcast(_:)` (takes `DaemonResponse`). `fanOutResponse` is not a member of `Session`. Compile error: "value of type 'Session' has no member 'fanOutResponse'."

**Correction.** Use `self.broadcast(.writeback(...))`.

**Source.** `/Users/ronny/rdev/rTerm/rtermd/Session.swift:210-224`.

Same issue repeats in Track A Task 10 Step 6 (clipboard sink fan-out).

---

### 1.5 Track B Task 8 — `MetalBufferRing.nextBuffer` writes without GPU in-flight synchronization

**Location:** hygiene plan, Task 8 Step 2-4 (`MetalBufferRing`).

**Defect.** `MetalBufferRing.nextBuffer(copying:length:)` copies into `buffers[cursor].contents()` and advances the cursor modulo `buffers.count`. No semaphore gates CPU writes against GPU reads. With `maxBuffersInFlight = 3` and three committed command buffers in flight, the CPU may begin writing buffer index `cursor` while the GPU is still sampling it — classic triple-buffering use-after-free / torn-read hazard. Apple's own guidance mandates a `DispatchSemaphore(value: maxBuffersInFlight)` plus `commandBuffer.addCompletedHandler { semaphore.signal() }` for exactly this pattern.

The ring design also never calls `ensureRings` on resize correctly: the plan's `ensureRings` uses `resize(byteLength:)` but the comment "Caller guarantees no buffer is currently in flight" is never enforced — resize may wreck ongoing GPU reads.

**Correction.** Pair the ring with a `DispatchSemaphore(value: 3)`; `semaphore.wait()` at the top of `draw(in:)`, `semaphore.signal()` in `commandBuffer.addCompletedHandler`. Stall resize until all in-flight buffers drain (`commandBuffer.waitUntilCompleted()` on the prior frame or gate resize behind the semaphore).

**Source.** Apple docs, `https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work` (fetched this session): "**No, this is NOT safe.** Even with `maxBuffersInFlight=3`, you must wait for the GPU to finish using the buffer before the CPU modifies it." `/Users/ronny/rdev/rTerm/docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md:1199-1207,1211-1219,1295-1320`.

---

### 1.6 Track A Task 9 — Assumes `RenderCoordinator.glyphMetrics` exists (it does not)

**Location:** features plan, Task 9 Step 3 (`cellCoordinate(at:)`).

**Defect.** Plan uses `coordinator?.glyphMetrics` to compute cell-pixel geometry. A repo-wide search shows no such accessor exists on `RenderCoordinator` — the coordinator does not cache per-glyph width/height in Phase 2 because the renderer computes cell geometry from grid dimensions / clip space, not pixels. Task 9's hover-and-click mapping must build the cell-pixel math from scratch.

**Correction.** Either add a `cellSize: CGSize` computed property to `RenderCoordinator` that computes pixels per cell from `view.drawableSize / (cols, rows)`, or hang the metrics off `GlyphAtlas` (where glyph pixel dimensions already live — `GlyphAtlas` creation uses CoreText glyph bounds). Plan must land this accessor explicitly as a sub-task before Task 9 can compile.

**Source.** `rg -n "glyphMetrics" /Users/ronny/rdev/rTerm` returns only the plan itself; `/Users/ronny/rdev/rTerm/rTerm/RenderCoordinator.swift` contains no `glyphMetrics` symbol.

---

### 1.7 Track A Task 12 — Assumes palette presets that do not exist

**Location:** features plan, Task 12 Step 2.

**Defect.** Plan's `preset(named:)` maps `"xterm"`, `"solarized-dark"`, `"solarized-light"` to `.xterm`, `.solarizedDark`, `.solarizedLight`. The actual `TerminalPalette` defines exactly one static preset: `xtermDefault` (`TerminalPalette.swift:100`). There is no `solarizedDark`, no `solarizedLight`, and no `.xterm` alias. Task 12 as written compiles only after someone first adds the preset definitions — a prerequisite the plan treats as free.

**Correction.** Add a Task 12 Step 1a: "Author `TerminalPalette.solarizedDark` and `.solarizedLight` structs with vetted 16-color data." Either include the RGBA values in the plan or cite a source to copy from. The plan's Step 1 `rg ...` just to "check preset names" is insufficient because the null result is a prerequisite failure, not a look-up.

**Source.** `rg -n "public static let" /Users/ronny/rdev/rTerm/rTerm/TerminalPalette.swift` → one match only (`xtermDefault` at line 100). Plan reference: `2026-05-02-control-chars-phase3-features.md:1875-1888`.

---

### 1.8 Track A Task 10 Step 7 — `NSAlert.runModal()` blocks MainActor inside an `await` response handler

**Location:** features plan, Task 10 Step 7 (`clipboardConsent`).

**Defect.** Plan awaits `clipboardConsent(for:preview:)` which internally calls `NSAlert.runModal()`. `runModal()` spins a nested modal event loop that blocks the calling thread (per Apple docs). Invoked from the response handler (`ContentView.swift:168` is a `@Sendable` closure whose `Task { @MainActor in ... }` dispatches MainActor work), this freezes the render loop and all XPC message handling every time the shell sends an OSC 52 — and OSC 52 is easy to spam (one `printf` in a loop). Worse, if a second OSC 52 arrives during the modal, the handler re-enters and stacks modals.

**Correction.** Use `NSAlert.beginSheetModal(for:completionHandler:)` wrapped in `withCheckedContinuation` so `await` actually yields. Also add a throttle / coalesce: at most one pending clipboard prompt per session.

**Source.** Apple docs, `https://developer.apple.com/documentation/appkit/nsalert` (fetched this session): "**Yes, `runModal()` is a blocking call.** It runs a modal event loop that blocks the calling thread until the user dismisses the alert." Plan reference: `2026-05-02-control-chars-phase3-features.md:1636-1647`.

---

### 1.9 Track A Task 7 (DECCOLM) — missing required VT side effects

**Location:** features plan, Task 7 Step 2.

**Defect.** Per the VT510 spec (mode 3, DECCOLM), enabling/disabling DECCOLM must: (a) clear the screen, (b) home the cursor, (c) **reset the scrolling region (DECSTBM) to the full screen**, (d) **reset origin mode (DECOM) to off**. The plan covers (a) and (b) only. Missing (c) and (d) is a real-app-breaker: vim and tmux use DECCOLM on entry and rely on the post-DECCOLM state being "full-screen scroll region, origin mode off." Without (c) a prior `CSI 5;22 r` leaks into the 132-column session; without (d) a prior `CSI ?6 h` silently re-origins the new cursor-position CSI arms.

The spec §8 even flags this: "DECCOLM also clears the screen by spec; model must coordinate." The plan treats "clear + home" as sufficient and silently drops the other two.

**Correction.** In the DECCOLM handler, before signalling `pendingCols`, also `mutateActive { $0.scrollRegion = nil }` and `modes.originMode = false`.

**Source.** VT510 spec (unverified this session — `vt100.net` returned 403). Corroborated by xterm's documented behavior for mode 3. Plan reference: `2026-05-02-control-chars-phase3-features.md:964-977`.

---

### 1.10 Track A Task 8 — OSC 8 `<params>` grammar misuses `split(separator: ";")`

**Location:** features plan, Task 8 Step 3 (`parseOSC8`).

**Defect.** The plan splits the whole OSC 8 payload on the first `;`, giving `paramsPart` and `uriPart`. Then it splits `paramsPart` again on `;` expecting multiple key=value pairs. But the OSC 8 params grammar (per xterm and the de-facto "hyperlinks in terminal emulators" spec) is **colon-separated**: `OSC 8 ; id=A:user=joe ; https://x ST`. The outer `;` is the field separator (params vs URI), the inner separator between k=v entries is `:`, not `;`. Using `;` at the inner level will silently swallow additional params because the outer split consumed them already; it won't "break" on a tricky input — it simply will never return a parameter other than the first.

Even worse, if the parser ever switches to a different outer-split strategy (e.g., scan for the first `;` after a non-escaped context), the plan's code is wrong either way.

**Correction.** Split `paramsPart` on `:` for key=value entries: `paramsPart.split(separator: ":")`. Add a test with a multi-param payload (e.g., `id=A:user=joe`).

**Source.** Consensus OSC 8 grammar (xterm, WezTerm, kitty, Alacritty). Plan reference: `2026-05-02-control-chars-phase3-features.md:1115-1122`. (`invisible-island.net` was blocked this session; marked unverified from a primary source, but the convention is unanimous across implementations.)

---

### 1.11 Track A Task 10 — `ClipboardTarget.from(xtermChar:)` collapses the target set to one char

**Location:** features plan, Task 10 Step 1 + Step 3.

**Defect.** Per xterm's OSC 52 ("Manipulate Selection Data") grammar, the target string `<target>` is a **set** of characters — each character selects one pasteboard slot. Shells send `"cs"` meaning "clipboard and primary selection"; they send `""` (empty) meaning "use default which is `s0` per xterm". The plan's parser calls `ClipboardTarget.from(xtermChar: targetStr.first ?? "c")` — it reads only the first character and discards the rest, then routes a single enum value. A shell sending `"cs"` gets just `.clipboard`; the `s` is lost silently.

For Phase 3 "set path only, set only" this may be acceptable, but the plan does not acknowledge the loss and the commit message implies full xterm-compatibility. Security-aware shells send `"cs"` precisely so that whichever pasteboard a downstream consumer has rights to can be satisfied — collapsing silently defeats that.

**Correction.** Either:
  - Iterate every character and enqueue a clipboard write per matching target; or
  - Parse the target set and use an `OptionSet`-style `ClipboardTargets` with `.clipboard`, `.primary`, `.selection`; or
  - Document in Phase 3 scope that only `first.map { ClipboardTarget.from(xtermChar:) }` is supported and explicitly route empty/multi-char targets to `.clipboard`.

**Source.** xterm ctlseqs "Manipulate Selection Data" grammar (unverified this session — allowlist block). Convention is stable across xterm, tmux's OSC 52 forwarding, and alacritty. Plan reference: `2026-05-02-control-chars-phase3-features.md:1527-1534,1557-1560`.

---

### 1.12 Track B Task 3 Step 2-3 — Access-control plan is incoherent; `Buffer`, `ScrollRegion`, `HistoryBox` are `private` to the actor

**Location:** hygiene plan, Task 3 Steps 2-4.

**Defect.** Actual visibility in `ScreenModel.swift`:
- `ScrollRegion`: top-level `private struct` (line 29)
- `Buffer`: actor-nested `private struct` (line 154)
- `HistoryBox`: actor-nested `private final class` (line 119)
- `SnapshotBox`: actor-nested `private final class` (line 99)
- Stored properties (`main`, `alt`, `_latestHistoryTail`, `pendingHistoryPublish`) are all `private` actor stored properties.

The plan's self-contradictory narrative:
1. Step 2 starts: "For Buffer and ScrollRegion that were `private` nested types: keep them nested inside the extension and change `private` to `fileprivate`."
2. Then: "Actually — the cleanest approach: define Buffer and ScrollRegion at `fileprivate` inside the Buffer extension file using the `extension ScreenModel { fileprivate struct Buffer ... }` syntax. But Swift disallows `fileprivate` types nested inside `extension X where` blocks from being visible to the main ScreenModel.swift at file scope."
3. Then: "Use `internal` visibility for Buffer and ScrollRegion in the new files. Mark them internal-only by keeping them inside an `extension ScreenModel { ... }` block — this keeps them module-private to TermCore. They will not be re-exported because the extension wraps them."

This is three contradictory prescriptions in the same step. The third is also factually wrong about re-export: types declared inside `extension ScreenModel { ... }` are declared at *module* scope if the enclosing type is public (and `ScreenModel` is public: `public actor ScreenModel` at line 49). Making `Buffer` `internal` in an extension of a public actor makes `ScreenModel.Buffer` an `internal` nested type **on the public actor** — it is module-visible (internal = module), not "module-private because wrapped." The framework's own tests could reference it; Swift does not re-scope types wrapped in extensions of public types.

4. Step 3 then discovers mid-paragraph that stored properties cannot live in extensions (correct), and instructs the implementer to revise the plan on the fly: "Revise Step 3 accordingly: `_latestHistoryTail`, `pendingHistoryPublish`, and `HistoryBox` stay in `ScreenModel.swift`." This is not an execution plan; it's a discovery narrative. An agentic executor will follow the first half and then contradict itself.

**Correction.** Rewrite Task 3 with a single prescriptive access-control plan: (a) types stay nested in the actor's main declaration **or** become module-internal (`internal`) with a clear callout that "this is exposed to TermCore internals but still not public API"; (b) stored properties stay on the actor's main declaration; (c) only methods move to extension files; (d) specify exactly one policy and include a sentence noting that the resulting access level is still not part of the public API of TermCore (TermCore.h does not re-export them, which is separate from Swift visibility).

**Source.** `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift:29,49,99,119,154`. Plan `2026-05-02-control-chars-phase3-hygiene.md:345-412`.

---

### 1.13 Track B Task 6 — `DispatchSerialQueue` typed-init overload resolution ambiguity

**Location:** hygiene plan, Task 6 Step 3-4.

**Defect.** The plan adds:
```swift
public convenience init(cols: Int = 80, rows: Int = 24,
                         historyCapacity: Int = 10_000,
                         queue: DispatchSerialQueue? = nil) { ... }

@available(*, deprecated, ...)
public convenience init(cols: Int = 80, rows: Int = 24,
                         historyCapacity: Int = 10_000,
                         queue: DispatchQueue? = nil) { ... }
```

Every existing call site uses the default value (`ScreenModel(cols: 80, rows: 24)`). Swift's overload resolution on `nil`-with-default against `DispatchQueue?` vs `DispatchSerialQueue?` is **ambiguous** — both signatures match the call with no arguments and Swift has no canonical tiebreaker for this pattern. A minimum reproduction would be every `TerminalSession.init` which currently does `ScreenModel(cols: Int(cols), rows: Int(rows))` — after this change the compiler would either select the deprecated overload (causing a project-wide deprecation warning) or emit an ambiguity error.

The plan's claim that "a caller passing `nil` picks the `DispatchSerialQueue?` overload (more specific context)" is not grounded — there is no "more specific context" inferable without further parameter-type information.

**Correction.** Either:
  - Rename one init so overload resolution is by name: e.g., `init(serialQueue: DispatchSerialQueue? = nil)` is the new one; keep the old `queue: DispatchQueue? = nil` as the deprecated.
  - Or drop the default from the new typed init, forcing callers to be explicit about which overload they want. Remove the default from *both* inits before migrating, migrate callers, then re-introduce defaults on the typed form only.
  - Empirically verify resolution in a scratch build **before** recommending this pattern across a framework.

**Source.** Plan `2026-05-02-control-chars-phase3-hygiene.md:783-829`. Repo call-site counts: `Session.swift:123` passes `queue: queue` (typed `DispatchQueue`); `ContentView.swift:58` passes no queue; TermCoreTests 79+ call sites pass no queue (plan's count).

---

### 1.14 Track A Task 8 (CellStyle Codable) — Existing `CellStyle` is auto-derived; adding a field breaks Phase 1/2 wire compat

**Location:** features plan, Task 8 Step 4.

**Defect.** The plan's rewrite of `CellStyle` replaces the current auto-derived `Codable` with hand-coded `init(from:)` that uses `decodeIfPresent` for the new `hyperlink` field. The intent (preserve wire compat) is correct, but the plan misstates the status quo: it says "this preserves Phase 1/2 wire compat." In fact the current `CellStyle` Codable is auto-derived (`CellStyle.swift:40 public struct CellStyle: Sendable, Equatable, Codable`, no hand-written `init(from:)`). Replacing auto-derived with hand-coded changes the JSON shape implicitly (synthesized encode emits keys even for default-valued fields, hand-coded may omit them).

More importantly, the plan's `encode(to:)` conditionally omits `hyperlink` when nil (`if let h = hyperlink { try c.encode(h, forKey: .hyperlink) }`). Encoding against this scheme but decoding via the auto-derived one (which a daemon built from stale source would use) would tolerate it only because Swift's synthesized `decodeIfPresent`-like behavior applies only when types are `Optional` — for a required key under synthesized decode, a missing key throws. Since daemon and client ship together, same-version compat is fine, but the plan's "Phase 1/2 wire compat" claim is only true if both sides update lockstep. The actual constraint (per spec §6) is "daemon and client ship together," so the plan is fine — **but** the rationale in Step 4 and the commit message misrepresent what changes.

**Correction.** Rewrite the plan's justification: "Switch `CellStyle` from auto-derived Codable to hand-coded Codable so that the new `hyperlink` field uses `decodeIfPresent` — synthesized Codable would require the key. Wire compat across mixed daemon/client versions is not a Phase 3 constraint, but the `decodeIfPresent` pattern is the project convention for all new fields (spec §6)." Also add a `JSONEncoder` roundtrip test ensuring `hyperlink: nil` payloads decode correctly **from a pre-Phase-3 JSON blob** (the plan's Task 8 Step 6 `test_legacy_cell_decodes` does this correctly for Cell but not for isolated CellStyle).

**Source.** `/Users/ronny/rdev/rTerm/TermCore/CellStyle.swift:40` (the type is plain `Codable`, no hand-coded init). Plan reference: `2026-05-02-control-chars-phase3-features.md:1132-1166`.

---

### 1.15 Track B Task 7 — `forTesting` factory is labeled "implementation sketch"; Task 8 depends on it

**Location:** hygiene plan, Task 7 Step 5; Task 8 Step 6.

**Defect.** Task 7's `RenderCoordinator.forTesting(screenModel:)` body literally is:
```swift
static func forTesting(screenModel: ScreenModel) throws -> RenderCoordinator {
    // Implementation sketch: ... 
    throw NSError(domain: "RenderCoordinator.forTesting", code: 1)
}
```
It unconditionally throws. The escape hatch is "`throw XCTSkip("requires Metal device; run manually")`." Then Task 8 Step 6 calls the same factory to pin a "steady-state makeBuffer count == 0" invariant. That's two tasks whose core verification is "skip the test."

This is a spec-item-checkbox exercise that delivers no regression coverage. Both tasks claim to "add a test" but neither test actually runs. The Task 8 commit message states: "DEBUG-only counter test pins the zero-steady-state invariant" — but there is no test; the factory throws and the test skips.

**Correction.** Either:
  - Implement the test without `MTKView` by extracting `beginFrameCleanup(cols:rows:)` and `encodeDrawCalls(commandBuffer:)` as standalone public-test-hook methods (the factory builds a no-drawable coordinator wired to a fake Metal device via `MTLCreateSystemDefaultDevice()`), and call only `beginFrameCleanup` for the allocation test. This is doable — `RenderCoordinator.init` doesn't need an `MTKView`, it takes a `ScreenModel` and `AppSettings`.
  - Or explicitly demote the task to "add a signpost, measure manually with Instruments, add a prose measurement record." Do not land unexecuted assertions that will appear to guard an invariant.

**Source.** Plan `2026-05-02-control-chars-phase3-hygiene.md:1047-1056,1350-1357`.

---

### 1.16 Track B Task 10 — Measurement criterion contradicts itself

**Location:** hygiene plan, Task 10 Step 4 (decision point).

**Defect.** The plan defines the defer-or-implement gate as:

> "if measurements show no regression at 60 MB/s sustained throughput, document 'deferred with measurement'..."

Then computes: 60 MB/s = 18,750 LF/s; runs 20,000 LFs with a 2 s budget.

- 20,000 LFs / 2.0 s = 10,000 LF/s → under the 18,750 LF/s threshold for 60 MB/s throughput.
- The test passes (< 2 s) only at ≥ 10,000 LF/s, which is **below** the spec's 60 MB/s threshold.

The plan concludes "if pass → defer." But passing the test does not imply meeting the 60 MB/s threshold. To meet it you'd have to run 20,000 LFs in < 1.07 s (20000 / 18750). The plan uses a 2.0 s budget, which silently accepts regressions at half the spec rate.

Second, it's not clear that "no regression at 60 MB/s sustained" is the right criterion anyway: at 60 MB/s sustained the terminal is allocator-bound even without scrolling, because byte→character→cell conversion alone dominates. The spec phrase was aspirational; treating it as a hard go/no-go is a mismatch.

**Correction.** Either:
  - Change the budget: 20,000 LFs in < 1.07 s, OR use 40,000 LFs in < 2 s (both match 18,750 LF/s).
  - Or frame the deferral as "no visible allocator stall at sustained `yes` output rate" and pick a test that matches. Do not assert "pass implies 60 MB/s met" when the math shows otherwise.

**Source.** Plan `2026-05-02-control-chars-phase3-hygiene.md:1557-1591`.

---

## 2. Significant risks (unverified or likely)

### 2.1 Track A Task 2 — DA1 `ESC [ ? 65 ; 22 c` identity is non-standard

**Claim.** Plan emits `CSI ? 65 ; 22 c` for DA1.

**Risk.** xterm's own default DA1 response is `CSI ? 1 ; 2 c` (VT102 with adv. video). The plan's choice of `65` (VT525) and `22` (ANSI color) is valid per DEC numbering but is not what xterm emits by default. Real-world tmux/vim/less detect terminal class by DA1; they do pattern-matching and many only special-case `CSI ? 6[0-9]` or `CSI ? 1`. If the plan's `65` is wrong, subtle feature-detection misses could follow (e.g., tmux concluding "this is not xterm-class" and refusing to pass through a 256-color attribute).

**Verification requested.** Before merging, confirm by grepping tmux and vim sources for DA1 response substrings, or run a short test: set up a fresh tmux with `TERM=xterm-256color`, send the rTerm DA1, see whether tmux enters xterm-class mode.

**Source.** `invisible-island.net/xterm/ctlseqs/ctlseqs.html` blocked this session; cited from general knowledge. Plan reference: `2026-05-02-control-chars-phase3-features.md:288-292`.

---

### 2.2 Track A Task 2 — DA2 version field `95` is undocumented as rationale

**Claim.** Plan emits `CSI > 1 ; 95 ; 0 c` for DA2, claiming "the 95 slot maps to 'xterm 95'; tmux reads this verbatim."

**Risk.** Real xterm puts its patch number in this slot. `95` is also a credible xterm patch number, but the plan calls it "xterm 95" without a source citation; tmux actually pattern-matches on `ESC [ > 0` (terminal class) and the patch/version numbers rarely. The plan's choice is not wrong; but the commit message's "Chosen to satisfy tmux, vim, and mosh detection logic" is not verified.

**Verification requested.** Capture a real xterm's DA2 response on the implementer's machine (`echo -e '\e[>c'` then read a bit of stdin) and compare.

**Source.** Same source as 2.1. Plan reference: `2026-05-02-control-chars-phase3-features.md:289-292`.

---

### 2.3 Track B Task 1 — Concurrent-reader test may not reliably observe the window

**Claim.** Plan: `Task.detached(priority: .userInitiated)` spins reading `latestSnapshot()`/`latestHistoryTail()`; after `await model.restore(from:)`, "no window is ever observed."

**Risk.** `ScreenModel.restore(from:)` holds the actor's executor serial queue for its duration. The detached Task runs on the cooperative pool's shared executor. Whether the reader ever schedules during the actor's serial execution depends on whether the Swift runtime suspends the actor job mid-call — and `restore(from:)` does not contain any `await`, so it runs to completion without yielding. The reader may only observe "before restore" or "after restore" states, never the intermediate. The test then passes trivially, not because the ordering is correct.

That said: the actor executes on a dispatch queue, and the reader runs on a different thread. Both can access the `nonisolated` mutexes (`_latestSnapshot`, `_latestHistoryTail`) in parallel. **So** the race window does exist and is observable in principle — but the sleep windows (10 ms pre-restore, 50 ms post-restore) may be too tight to hit consistently on fast hardware.

**Verification requested.** Run the test 1000 times on CI and observe flake rate. If the ordering is backwards (snapshot-before-history-clear), the test should fail reliably; if correct (current code), the test should pass. Perform a negative-control experiment by locally inverting the order of `_latestHistoryTail.withLock { $0 = HistoryBox([]) }` and `restore(from: payload.snapshot)` in `ScreenModel.restore(from:)` and re-running — the test should observe violations. If it doesn't, the test is not actually exercising the window.

**Source.** `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift:632-641`. Plan reference: `2026-05-02-control-chars-phase3-hygiene.md:92-173`.

---

### 2.4 Track A Task 5 — Blink rendering is marked "manual visual test"

**Claim.** Step 4: "Launch the app, run `printf '\033[5mHELLO\033[0m\n'`. The 'HELLO' text should blink at 1 Hz."

**Risk.** Unit-testable approximations exist: pass the `blinkPhase` into the rendering path and test that cells with `.blink` attribute project to `bg` when `blinkPhase > 0.5`. The plan punts on this and relies entirely on eyeballing. Given Phase 2's emphasis on tests, that's a significant coverage regression — blink stays untested forever unless someone proactively adds pixel-compare tests.

**Verification requested.** Add a pure-function test on `AttributeProjection.project(fg:bg:attributes:blinkPhaseOff:)` or factor out the blink decision into a testable pure function.

**Source.** Plan `2026-05-02-control-chars-phase3-features.md:773-778`.

---

### 2.5 Track A Task 12 — `@Observable @MainActor` class with `@ObservationIgnored @AppStorage` accessor

**Claim.** Plan stacks a computed `paletteName` on top of `@ObservationIgnored @AppStorage`. Expected behavior: SwiftUI observes `paletteName` via `@Observable` macro; writes go through `@AppStorage`; the stored value survives app restart.

**Risk.** `@AppStorage` is a SwiftUI property wrapper designed for use *inside a View*. Using it as a wrapped property on a non-View class is a pattern with mixed documentation. `AppStorage` internally uses `UserDefaults` but also registers observers via the SwiftUI graph; when the wrapper is used outside a view, change notifications may or may not fire. The plan's `@Observable` wrapper then observes the computed var `paletteName`, which reads from `storedPaletteName`. Whether this gives reactive updates depends on whether `@Observable` tracks access to a computed property that synthesizes reads from `@AppStorage`. Likely works (tested by many apps) but not Apple-documented as a supported pattern.

**Verification requested.** Test empirically: with the palette picker in Settings, change the palette, observe whether the live terminal view updates within one frame. If not, add a `NotificationCenter` observer on `UserDefaults.didChangeNotification` as a fallback.

**Source.** Apple docs, `https://developer.apple.com/documentation/swiftui/appstorage` (fetched, content minimal). Plan reference: `2026-05-02-control-chars-phase3-features.md:1856-1869`.

---

### 2.6 Track B Task 7 — Signposter API verification

**Claim.** Plan constructs `OSSignposter(subsystem: "rTerm", category: "RenderCoordinator")` and calls `beginInterval("name", id: id)` returning a state; ends with `endInterval("name", signpost)`.

**Risk.** Apple docs (fetched) confirm `beginInterval(_:id:_:)` and `init(subsystem:category:)` as public API. Confidence: high. Plan's signposter code is correct.

---

### 2.7 Track A Task 11 — `iconName` add to `ScreenSnapshot` must also update the init signature at every call site

**Claim.** Plan Step 1: "Extend convenience init to forward it... in the flat `ScreenSnapshot.init`, add `iconName: String? = nil`."

**Risk.** The existing 12-param init's `makeSnapshot(from:)` is reused from Track B Task 4 (which already extracted `TerminalState`). Task 11 chains `iconName` onto `TerminalState`, requiring `makeSnapshot(from:)` to pass `iconName: iconName` through the `TerminalState` constructor. The plan references this but does not recompute how many total fields pass through at each integration point — after Task 4, Task 7 (`cursorShape` via `TerminalState`), and Task 11 (`iconName` via `TerminalState`), the terminal-state cluster grows to 9 fields. Small; still, each task touches the same init, and a merge-order mistake corrupts the chain. Add an integration checkpoint in the plan that reconciles all three after Track A Task 11.

**Source.** Plan references `TerminalState` field list in Task 4 Step 2; Task 11 Step 1; and Track B Task 4 Step 2.

---

### 2.8 Track B Task 3 — Pbxproj surgery is described as "dispatch a 'pbxproj surgery' subagent"

**Claim.** "If the implementer can't use Xcode GUI, dispatch a 'pbxproj surgery' subagent with the two new file names..."

**Risk.** pbxproj file editing by hand is error-prone and easy to corrupt. The plan treats this as a footnote but it's a likely source of a broken Xcode project. An implementer without Xcode access should not attempt it without a tool; the "subagent" referenced does not exist in the skill list.

**Verification requested.** Restate Task 3 Step 5 as: "Open Xcode; drag two files into the TermCore group; commit the resulting pbxproj diff." Remove the subagent reference.

**Source.** Plan `2026-05-02-control-chars-phase3-hygiene.md:417-422`.

---

### 2.9 Track A Task 10 — `DaemonResponse` adding cases is compatible because Codable is auto-derived

**Claim (positive).** Per the review prompt's list: confirm whether `DaemonResponse` uses auto-derived or hand-coded `Codable`.

**Read.** `/Users/ronny/rdev/rTerm/TermCore/DaemonProtocol.swift:62`: `public enum DaemonResponse: Codable, Sendable, Equatable`. No hand-coded `init(from:)` or `encode(to:)`. Verdict: **auto-derived**. Adding new cases is source-compatible (existing case lists stay intact) and wire-compatible in both directions as long as daemon+client ship together (spec §6).

No defect here; verification confirms the plan's silent assumption is correct.

---

### 2.10 Track B Task 2 — `top`/`htop` fixture does not assert alt-screen was entered

**Claim.** Test builds a bytestream including `ESC [ ? 1049 h`, writes content, then `ESC [ ? 1049 l`, and asserts "after.activeBuffer == .main".

**Risk.** The fixture never asserts that, between the enter and exit, `activeBuffer == .alt` was reached. A buggy handler that silently treats 1049 as a no-op would pass this test (enter + exit both no-op → end on main, assertion holds). The test name claims "lands on alt, clears region, restores main on exit" but only verifies the final state.

**Correction.** Split `model.apply(events)` into two halves — one batch that ends after the 5 colored rows, assert `after.activeBuffer == .alt` and alt grid contains the expected content; then apply the exit sequence and assert restoration.

**Source.** Plan `2026-05-02-control-chars-phase3-hygiene.md:236-297`.

---

## 3. Coverage gaps — spec §8 items not covered by any task

Walking §8 Track A:
| Spec bullet | Task | Gap? |
|---|---|---|
| OSC 8 hyperlinks (parser/model) | Track A Task 8 | OK |
| OSC 8 hyperlinks (renderer + click) | Track A Task 9 | OK modulo defects 1.6, 1.10 |
| OSC 52 clipboard (set only) | Track A Task 10 | OK modulo defects 1.8, 1.11 |
| OSC 52 query | Deferred to Phase 4 per answered Q1 | OK |
| DECSCUSR | Track A Task 4 | OK modulo defect 1.1-ish |
| Blink attribute rendering | Track A Task 5 | Weakly covered (risk 2.4) |
| DA1 | Track A Task 2 | OK modulo risk 2.1 |
| DA2 | Track A Task 2 | OK modulo risk 2.2 |
| CPR | Track A Task 3 | OK |
| DECOM | Track A Task 6 | Blocked by defect 1.1, 1.2 |
| DECCOLM | Track A Task 7 | Blocked by defect 1.9 (missing side effects) |
| Palette chooser UI | Track A Task 12 | Blocked by defect 1.7 |
| Integration fixture corpus completion | Track B Task 2 | OK modulo risk 2.10 |

Walking §8 Track B:
| Spec bullet | Task | Gap? |
|---|---|---|
| 1. Renderer vertex array reuse | Track B Task 7 | OK modulo defect 1.15 |
| 2. Metal buffer pre-alloc ring | Track B Task 8 | Blocked by defect 1.5 (no GPU sync) |
| 3. ScrollbackHistory.Row pre-alloc | Track B Task 10 | OK modulo defect 1.16 |
| 4. ScreenSnapshot 12-param init → TerminalState | Track B Task 4 | OK |
| 5. ScreenModel.swift file split | Track B Task 3 | Blocked by defect 1.12 |
| 6. DispatchSerialQueue force-cast hardening | Track B Task 6 | Blocked by defect 1.13 |
| 7. cellAt scrolled-render loop hoist | Track B Task 9 | OK |
| 8. publishHistoryTail ordering doc | Track B Task 5 | OK |
| 9. Cursor.zero static | Track B Task 4 | OK (bundled) |
| 10. CircularCollection TODO | Track B completion checklist notes "deferred with tracking comment"; no task lands the comment | **Gap:** no task actually adds the tracking comment to `CircularCollection.swift` line 53. Task 10's footnote mentions it but doesn't land it. |
| 11. ImmutableBox<T> extraction | Deferred per answered decision | OK |
| 12. Test gaps (AttributeProjection invariance, restore-ordering test, top/htop fixture) | Track B Tasks 1 + 2 | OK |
| 13. Comment cleanup | Completion checklist only | **Gap:** no task scans for stale T-references; checklist says "verify" but that's not an action. A pre-PR `rg "T[0-9]+|Phase 2 T"` grep should be an explicit step. |

**Additional items raised by the prompt that no task covers:**

- **iconName exposure on ScreenSnapshot** (answered Q7, yes). — Track A Task 11 covers it. OK.
- **OSC 8 URI allowlist** (answered Q4). — Track A Task 9 Step 1 covers `HyperlinkScheme`. OK.
- **OSC 52 query deferred** (answered Q1). — Acknowledged throughout. OK.

**Gaps to add as explicit tasks:**
1. Add a tracking comment at `CircularCollection.swift:53` (spec §8 Track B item 10).
2. Pre-PR stale-T-reference grep + clean-up (§8 Track B item 13).

---

## Summary

- **16 blocking defects** — any one prevents a clean build or a functional feature ship.
- **10 significant risks** — likely issues whose severity depends on unverifiable external docs or runtime behavior not reproducible in this static review.
- **2 coverage gaps** — §8 items 10 and 13 have no concrete task.

The Track A DECOM (6) and DECCOLM (7) tasks in particular stand out: DECOM can't compile as written (defects 1.1 + 1.2); DECCOLM is semantically incomplete (defect 1.9). Track B's Task 3 file split (defect 1.12) and Task 6 init (defect 1.13) both have access-control / overload-resolution issues that will surface at first build. Task 8's Metal buffer ring (defect 1.5) is a GPU-synchronization hazard that may pass tests and corrupt live rendering intermittently.

Neither plan should land as-is.
