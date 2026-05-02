# Phase 3 Plans — Simplify Reuse Review

**Inputs reviewed:**
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-hygiene.md` (Track B, 10 tasks)
- `/Users/ronny/rdev/rTerm-phase3-plans/docs/superpowers/plans/2026-05-02-control-chars-phase3-features.md` (Track A, 12 tasks)

**Reference terminals consulted:**
- wezterm (`~/dev/public/wezterm/term/src/terminalstate/mod.rs`)
- iTerm2 (`~/rdev/iTerm2/sources/VT100TerminalDelegate.h`)
- internal Terminal.app (`~/dev/swe/terminal/TTVT100Emulator.m`)

## 1. Intra-plan duplication

### 1a. Track A (features plan)

| Duplicated pattern | Tasks where it appears | Recommendation |
|---|---|---|
| **Sink install/emit trio** — `private var _xxxSink: (@Sendable (…) -> Void)? = nil`, `installXxxSink(...)` with precondition, `emitXxxEvent(...)` no-op-if-nil | Task 1 (writeback, lines 70–89) and Task 10 (clipboard, lines 1812–1821). Both live on `ScreenModel` and are installed from `Session.startOutputHandler()` via `assumeIsolated`. Phase 2 also had a `pasteSink` for bracketed paste. | **Factor to a shared helper.** Either a single `ScreenModelSinks` struct held on the actor (one `installSinks(writeback:clipboard:)` call) OR a generic `Sink<T>` value type (`ScreenModel` holds `Sink<Data>` + `Sink<(ClipboardTargets, String)>`). Track A Task 10 already installs both sinks inside the same `screenModel.assumeIsolated { model in … }` block (line 1839), acknowledging the pattern. Decision deferred to remediation pass; a single helper removes 15–20 lines of boilerplate in each future sink. |
| **ESC-sequence raw byte literals** — `Data([0x1B, 0x5B, …, 0xNN])` or `Data([0x1B, 0x5B, 0x3F, 0x31, …])` hand-written in tests and handler bodies | Tasks 2, 3, 4, 8, 10. Parser tests at lines 282, 289, 296, 438, 684, 691, 698, 715; writeback payload assembly at lines 311, 315, 452–457, 475, 488; OSC byte streams at 1327, 1337, 1357. | **Keep as-is with a thin helper.** `Data(ESC: "[1;2c")` or `let esc: UInt8 = 0x1B` + `Data(bytes:count:)`. No production helper exists today (Phase 2 did not add one). Low impact; the literal byte lists are grep-friendly for wire-debugging. Defer to a test-only `TerminalTestBytes.swift` helper if later remediation touches these files again. |
| **Handler pattern `return false // no snapshot bump — pure writeback/side effect`** | Task 2 (DA1/DA2, line 317), Task 3 (CPR — implicit), Task 8 (setHyperlink, line 1308), Task 10 (setClipboard, line 1829). All return `false` from `handleCSI` / `handleOSC` to skip snapshot versioning. | **Keep as-is, document once.** Already a codebase convention; comment appears four times in similar form. If Track B Task 5's doc-comment scope expands, include a one-liner in `apply(_:)` noting the `true = bump snapshot` contract. |
| **Hand-coded Codable with `decodeIfPresent ?? default`** | Task 4 cursorShape (lines 622–625), Task 8 hyperlink (lines 1274–1292), Task 11 iconName (lines 2046–2049). Three separate CodingKeys extensions. | **Keep three separate, but cross-reference.** Each lands on a different type (`ScreenSnapshot`, `CellStyle`, `ScreenSnapshot`). Factoring would require a macro or PropertyWrapper (out of scope). Add a `CLAUDE.md` bullet: "All new Codable fields on wire types use `decodeIfPresent` with a default; encode drops the key when nil." |
| **Test spies — `final class XSpy: @unchecked Sendable` with NSLock-guarded accumulator** | Task 1 `UnsafeBytesCollector` (lines 166–172), Task 2 `DataSink` (lines 361–366), Task 10 `ClipboardSpy` (lines 1977–1982), plus Track B Task 1 `AtomicBool` (lines 166–172). Four copies of the same 5-line lock pattern. | **Factor to `TermCoreTests/TestHelpers/LockedAccumulator.swift`** — a single `@unchecked Sendable` generic wrapper `LockedAccumulator<T>` with `record(_:)` and `snapshot() -> [T]`. Saves ~30 lines and removes the copy-paste risk that one spy gets its lock body subtly wrong. |
| **Enum-variant addition to same switch** — `CSICommand` gains cases in Tasks 2, 3, 4; `OSCCommand` gains cases in Tasks 8, 10; `DECPrivateMode` gains cases in Tasks 6, 7; `DaemonResponse` gains cases in Tasks 1, 10. | Every task edits the respective enum's cases **and** the `mapCSI` / `mapOSC` / `handleSetMode` switch. Four hot-spot files: `CSICommand.swift`, `OSCCommand.swift`, `DECPrivateMode.swift`, `DaemonProtocol.swift`. | **Sequencing hazard, flag in plan preamble.** If Tasks 2+3+4 land in parallel they conflict at the `CSICommand` enum and `mapCSI` switch bodies. The plan's execution contract (one task at a time, commit gated by reviewer) already sequences them, so this is only a failure mode if a later pass parallelizes. No edit needed; noting in the findings table. |

### 1b. Track B (hygiene plan)

| Duplicated pattern | Tasks where it appears | Recommendation |
|---|---|---|
| **`os.signpost` instrumentation + DEBUG-only counter + `forTesting` accessor** | Task 7 (`signposter` + `vertexCapacitiesForTesting`, lines 938–942, 1108–1118), Task 8 (`makeBufferCountForTesting` + `signposter "metalBufferAlloc"`, lines 1172–1188, 1484–1487), Task 10 (`rowAllocationCountForTesting`, lines 1641–1643). Three separate `nonisolated(unsafe) static var xForTesting` counters. | **Land the signposter + counter infrastructure once in Task 7, have Task 8 and Task 10 reuse.** Current plan installs `OSSignposter(subsystem: "rTerm", category: "RenderCoordinator")` in Task 7 and a separate signposter interval in Task 8. Factor a `RenderSignpost.shared` (or a `RenderCoordinator.signposter` instance already usable by Task 8). The counters (`makeBufferCountForTesting`, `rowAllocationCountForTesting`) should follow a single `PerfCounters` enum pattern so Swift 6 isolation commentary is written once, not three times. Saves three near-identical `nonisolated(unsafe)` blocks and their concurrency annotations. |
| **`removeAll(keepingCapacity: true)` preamble × 6 arrays** | Task 7 (lines 1005–1010, 1045–1050). Six identical calls in the frame prolog. | **Keep inline.** Six calls with six unique array names; a `for-in` helper would obscure grep hits. Already factored to `beginFrameCleanup(cols:rows:)` (line 1040) — the plan already collapses to one method. Good as-is. |
| **Semaphore + sink install mechanics for `MetalBufferRing`** | Task 8 creates one ring × 6 instances (lines 1393–1409). Each ring carries its own `DispatchSemaphore`; each `signalOnCompletion` call site is duplicated once per pass in `draw(in:)` (lines 1457–1463). | **Factor — one command-buffer completion handler releasing all six rings.** Instead of `regularRing!.signalOnCompletion(commandBuffer: cb); boldRing!.signalOnCompletion(commandBuffer: cb); …` (6 lines), attach a single completion handler that signals all six semaphores. Subtle but not free: wezterm's `BufWriter` keeps *one* writer for all bytes, not six. For Metal buffers the analogy is weaker (each pass has its own buffer), so keeping six rings is correct; but the 6× `addCompletedHandler` is pure duplication — each handler is a dispatch closure allocation, 6× for no benefit. A single handler with a `for ring in rings { ring.signal() }` body is cleaner. |

## 2. Inter-plan coupling

### 2a. Track A → Track B dependencies (present)

- **Track A Task 4 (DECSCUSR) → Track B Task 4 (TerminalState extraction).** Track A Task 4 Step 4 (line 613) extends `TerminalState` with `cursorShape`. Track A self-review note at line 2361 explicitly flags the dependency. **Status: documented.**
- **Track A Task 6 (DECOM) → Track B Task 4 (Cursor.zero).** Track A Task 6 Step 3 (line 858) has an explicit "API note" stating "`Cursor.zero` is added by Track B Task 4; this task depends on it." **Status: documented.**
- **Track A Task 7 (DECCOLM) → Track B Task 4 (Cursor.zero) + Track B Task 3 (clearGrid on +Buffer extension).** Track A Task 7 line 1043 uses `Cursor.zero`; line 1035 uses `Self.clearGrid` (moved to `ScreenModel+Buffer.swift` in Track B Task 3). **Dependency is NOT called out at the task level** — only the plan preamble (line 5) says "Track B hygiene must be landed first." Recommend a one-line note in Task 7 Step 2.
- **Track A Task 11 (iconName) → Track B Task 4 (TerminalState).** Line 2024–2028 extends `TerminalState`. **Status: documented implicitly** (the step header says "add to `ScreenSnapshot.TerminalState`").

### 2b. Intra-Track-A dependencies (missing cross-references)

- **Track A Task 7 (DECCOLM) → Track A Task 6 (DECOM).** Task 7 Step 2, side effect 4 (line 1041) sets `modes.originMode = false`. That field is *introduced by Task 6* (line 852). If Task 7 lands before Task 6, the code does not compile. The Track A self-review note at line 2358 mentions both tasks wire into `handleSetMode`, but does not state the ordering requirement. **Recommend:** prepend Task 7 with "Prerequisite: Task 6 must land first so `TerminalModes.originMode` exists." Or: land the struct field in Task 6 and mutate it from Task 7.
- **Track A Task 2/3/4 (DA1/DA2/CPR/DECSCUSR) → Track A Task 1 (writeback sink).** Tasks 2, 3, 4 all call `emitWriteback(...)`. Task 2 (lines 342–356) already explicitly constructs `model.installWritebackSink(...)` in its test — correctly relying on Task 1. But the plan preamble gives no "Task N depends on Task M" table; a new reviewer must discover the chain.
- **Track A Task 8 (OSC 8 parser) → Track A Task 9 (OSC 8 renderer/click).** Task 9 line 1605 reads `cell.style.hyperlink` — the field added in Task 8. Task 9 does not spell out "Task 8 must land first" but it's implicit in the Step 1 references. **Low risk** because Task 9 can't be written without Task 8's types.

### 2c. Track B → Track A coupling (missing)

- **Track B Task 3 (ScreenModel file split) → every Track A task that touches `ScreenModel.swift`.** Track A Task 1 adds `_writebackSink` / `installWritebackSink` / `emitWriteback`. Per Track B Task 3's split, handler methods stay in `ScreenModel.swift` (main file), but `_writebackSink` is a stored property, which must go there too. Track A Task 1 line 70 does place it in `ScreenModel.swift`, so no conflict — but Track A Task 10 (`_clipboardSink`, line 1812) sits beside it. **Status: no conflict, but if Track B Task 3 were re-scoped to move any of `handleCSI` / `handleOSC` / `apply(_:)` to an extension file, every Track A task would need rebasing.** The Track B Task 3 plan explicitly keeps these on the main declaration (lines 352–355). Flag in the Track B Task 3 commit message: "all event dispatchers remain on main declaration; Phase 3 features extend them via new enum cases rather than moving them."

## 3. Reference terminal learnings

### 3a. Unified writeback path (strong evidence across all three reference terminals)

**wezterm** (`~/dev/public/wezterm/term/src/terminalstate/mod.rs:356`):
```rust
writer: BufWriter<ThreadedWriter>,
```
All byte emission — DA1 (line 1296), DA2 (1311), DA3 (1316), terminal name/version (1321–1324), terminal parameters (1329–1331), status report (1336), XtSmGraphics responses, focus events (788–789), keyboard-generated bytes (843–844), SGR-related responses (1248–1249) — routes through `self.writer.write(...)` + `self.writer.flush()`. **One field, one flush discipline.**

**iTerm2** (`~/rdev/iTerm2/sources/VT100TerminalDelegate.h:112`):
```objc
- (void)terminalSendReport:(NSData *)report;
```
Single delegate method for all writeback. A specialized variant `terminalSendOSC4Report:` (line 116) exists for OSC 4 color-palette answers that tmux pipes through a dedicated route — this is the one case where iTerm2 factors a separate sink, and even then it's the same method signature (just a different routing endpoint).

**Internal Terminal.app** (`~/dev/swe/terminal/TTVT100Emulator.m`):
```objc
[_shell writeData:[@"\033[?1;2c" dataUsingEncoding:NSUTF8StringEncoding]];
```
DA1 (line 2098), DA2 (2132), CPR (2073), status report (2066), windowing queries (2614, 2624, 2631, 2636), keyboard responses (2766, 2772, 2787, 2811, 2819) all route through `[_shell writeData:]`. **Same single-sink pattern.**

**rTerm plan diverges.** Track A installs **two separate `@Sendable` sinks** on `ScreenModel` — `_writebackSink: (Data) -> Void` for DA/CPR responses (Task 1) and `_clipboardSink: (ClipboardTargets, String) -> Void` for OSC 52 (Task 10). If Phase 4 adds OSC 4 query replies, cursor position queries, XTSMGRAPHICS, focus events, or any of the other writeback-required sequences, the plan pattern invites a third sink. Reference-terminal consensus says **one typed output stream**.

**Structural borrowing (not code):** a single `ScreenModelOutput` sink returning a typed enum:
```swift
enum ScreenModelOutput: Sendable {
    case ptyWriteback(Data)                          // DA1/DA2/CPR/DSR
    case clipboardWrite(ClipboardTargets, String)    // OSC 52
    // Phase 4 adds: .osc4ColorReply, .focusEvent, …
}
private var _outputSink: (@Sendable (ScreenModelOutput) -> Void)? = nil
```
**Impact on plans:** Task 1 and Task 10 collapse to the same mechanism; each new Phase 4 sink is a new enum case, not a new `@Sendable` property + install method + test. ~40 lines saved across Tasks 1 + 10 alone; the pattern scales.

### 3b. OSC 8 hyperlink storage per cell (strong evidence — rTerm plan under-optimizes)

**wezterm** (`~/dev/public/wezterm/wezterm-cell/src/lib.rs:93`):
```rust
hyperlink: Option<Arc<Hyperlink>>,
```
Every `Cell` carries an `Option<Arc<Hyperlink>>`. Cells within the same OSC 8 `id=` group share the **same Arc** (pointer equality: `Arc::ptr_eq`, see `~/dev/public/wezterm/wezterm-gui/src/termwindow/mouseevent.rs:817`). Hover comparison is pointer-equality, not URI string compare — cheap.

**rTerm plan** (Track A Task 8, line 1265):
```swift
public var hyperlink: Hyperlink?       // value type with String id + String uri
```
`Hyperlink` is declared as `Sendable, Equatable, Codable` value struct (line 1184) — every cell that shares a hyperlink **copies the String fields**. 80×24 grid with a single `OSC 8 ; id=A ; http://apple.com ST` run could carry ~1920 cell-local copies of the URI string.

**Structural borrowing:** use a reference wrapper. Swift's equivalent of `Arc<Hyperlink>` is a `final class Hyperlink` (reference semantics) or a private `Hyperlink.ID` intern table owned by `ScreenModel` that cells reference by a small integer. Either cuts memory from O(cells × URI-length) to O(distinct-hyperlinks).

- **Smaller-change option:** keep `Hyperlink` as a struct but have the renderer (Task 9) compare by `id ?? uri` string identity. rTerm plan Task 9 line 1613 walks `snapshot` looking for cells with matching `link.id` — this already relies on id-match; formalize "distinct hyperlinks per screen ≤ 10" as the operational assumption and string copies become acceptable. Add the assumption to Task 8.
- **Medium-change option:** make `Hyperlink` a `public final class Hyperlink: Sendable` with hand-coded `Equatable` / `Codable`. Same Swift-side ergonomics; per-cell storage drops to 8-byte pointer. Lands in Task 8.

**Recommendation:** flag this tradeoff in Task 8's "Design decision" section. The plan does not acknowledge that `Hyperlink?` is copied into every cell.

### 3c. Palette preset selection (weak alignment)

**iTerm2** ships `plists/ColorPresets.plist` with dozens of named presets (Solarized, Tomorrow, GruvBox, Monokai, …) — presets are data, not code. Settings UI iterates the plist.

**Track A Task 12** hard-codes Solarized Dark/Light in Swift (lines 2144–2181). Stable-identifier lookup is a Swift switch (line 2191). Works for Phase 3 (3 presets), but the pattern doesn't scale to 30.

**Structural borrowing:** read presets from a resource plist. Out of scope for Phase 3 per the "no new features" constraint, but worth a CLAUDE.md hint: "future palette additions should migrate to a plist resource." No plan edit needed — the Solarized constants are correct for today.

### 3d. Alternate-screen save/restore ordering (aligned — no change needed)

iTerm2, wezterm, and Terminal.app all follow VT spec ordering on `1049 h` (save cursor → switch to alt → clear alt) and `1049 l` (clear alt → switch to main → restore cursor). Track B Task 2 fixture (top/htop) exercises this correctly. No divergence.

## 4. Recommendations

Ordered by impact:

1. **Factor the test-spy lock pattern into `TermCoreTests/TestHelpers/LockedAccumulator.swift` (or equivalent).**
   - What: one generic class replaces `UnsafeBytesCollector`, `DataSink`, `ClipboardSpy`, `AtomicBool`.
   - Where: new file under `TermCoreTests/`.
   - Why: four lock-protected `@unchecked Sendable` accumulators with near-identical bodies invite subtle divergence (forgetting `defer { lock.unlock() }` in one copy breaks the test in a hard-to-debug way).
   - Estimated edit size: new ~40-line helper + remove ~120 lines across Track A Tasks 1, 2, 10 and Track B Task 1. Plan-level: add a "TestHelpers" prelude task; each affected task then shrinks by ~10 lines.
   - Skill: `superpowers:test-driven-development` confirms this is a single-purpose helper.

2. **Collapse the two Track A sinks into a single typed `ScreenModelOutput` enum.**
   - What: replace `_writebackSink` + `_clipboardSink` with `_outputSink: (@Sendable (ScreenModelOutput) -> Void)?`; factor install/emit into one pair.
   - Where: Track A Task 1 and Task 10 both collapse; Track A plan preamble gains a "ScreenModel output protocol" note.
   - Why: reference-terminal consensus (wezterm `self.writer`, iTerm2 `terminalSendReport:`, Terminal.app `[_shell writeData:]`) says one sink. Phase 4's OSC 4 query replies, window-size reports, focus events all become new enum cases instead of new `@Sendable` properties. Cuts ~30 lines from Tasks 1 + 10 and pre-commits the Phase 4 shape.
   - Estimated edit size: Task 1 rewrite (~20 lines changed), Task 10 adjusted (~15 lines changed). Keeps both tasks' semantics; changes the mechanics.

3. **Document the Track A internal task ordering (Task 7 depends on Task 6; Tasks 2/3/4 depend on Task 1; Task 9 depends on Task 8).**
   - What: add a "Task dependencies" table near the top of the Track A plan preamble, listing the eight cross-task prerequisites found in §2b.
   - Where: Track A plan header, above "## Task 1".
   - Why: the plan preamble only states "Track B must land first." Within Track A, the implicit ordering is safe only if the controller executes top-to-bottom. A remediation pass that parallelizes (e.g., Tasks 2/3 together) would hit compile errors at `CSICommand` enum edits. Making this explicit is two sentences of prose and zero code.
   - Estimated edit size: 10 lines of markdown in the Track A preamble.

4. **Add a "distinct hyperlinks per screen" budget note to Track A Task 8 OR promote `Hyperlink` to a reference type.**
   - What: either (a) inline a budget note saying "struct copies are acceptable because distinct hyperlinks per 80×24 are ≤ 10 in practice; revisit if a regression surfaces"; or (b) change `public struct Hyperlink` to `public final class Hyperlink: Sendable` with hand-coded `Equatable`/`Codable`.
   - Where: Track A Task 8 (Step 1, line 1184) or its "Design decision" prelude.
   - Why: wezterm's `Option<Arc<Hyperlink>>` is the reference shape; rTerm's `Hyperlink?` value field copies the URI into every cell that shares a hyperlink. Per-screen memory scales with (cells × URI-length) instead of (distinct-hyperlinks × URI-length). Not a performance blocker for Phase 3, but an unacknowledged tradeoff.
   - Estimated edit size: 8 lines of design note if (a); ~25 lines of class conversion + Codable rewrite if (b).

5. **Unify the three DEBUG-only `nonisolated(unsafe) static var xForTesting` counters + `ForTesting` accessors into one "PerfCounters" helper.**
   - What: Track B Tasks 7, 8, 10 each declare a DEBUG-only static counter with near-identical Swift 6 isolation commentary. Factor into a `#if DEBUG enum PerfCounters { static var makeBufferCount = 0; static var vertexCapacitySnapshot: [Int] = []; static var rowAllocationCount = 0 }`. Each task references the shared namespace.
   - Where: Track B Tasks 7, 8, 10.
   - Why: three near-identical `nonisolated(unsafe)` declarations with three near-identical Swift 6 isolation rationale paragraphs. One shared namespace + one paragraph explains all three.
   - Estimated edit size: extract ~15-line helper; replace three counter declarations (~30 lines) with three shared-namespace references (~3 lines).

6. **Collapse the six `signalOnCompletion(commandBuffer:)` call sites in Track B Task 8.**
   - What: replace
     ```swift
     regularRing!.signalOnCompletion(commandBuffer: commandBuffer)
     boldRing!.signalOnCompletion(commandBuffer: commandBuffer)
     … (6 lines)
     ```
     with a single `commandBuffer.addCompletedHandler { _ in for ring in rings { ring.signalSemaphore() } }`. Expose a non-command-buffer `signalSemaphore()` on the ring.
   - Where: Track B Task 8 Step 5 (lines 1457–1463).
   - Why: six separate `addCompletedHandler` closures = 6× heap allocations per frame. One handler, six semaphore signals = 1× heap allocation. Small but free perf win; also one line instead of six.
   - Estimated edit size: add `signalSemaphore()` to `MetalBufferRing` (~3 lines); replace 6-line block with 3-line block in `draw(in:)`.

---

**Not recommended** (deliberate non-findings, to pre-empt):
- Enum-case-addition conflicts (CSICommand, OSCCommand, DaemonResponse) are sequenced by the plan's execution contract; no factoring needed.
- `decodeIfPresent ?? default` across three types is not worth factoring — PropertyWrappers or macros cost more than the three hand-written CodingKeys extensions save.
- The ESC-byte-literal helpers in tests are grep-friendly; factoring hurts debuggability more than it helps line count.
- Alt-screen save/restore ordering — plan matches reference-terminal consensus.
- Track B Task 7/8/9 `os_signpost` instrumentation overlap — recommendation 5 covers it.
