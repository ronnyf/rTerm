# End-to-End Pipeline Debugging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Identify and fix every break in the output and input data paths so the terminal displays the shell prompt, accepts keyboard input, and renders shell output.

**Architecture:** The pipeline spans two processes (app + XPC service) with handoffs at PTY FDs, XPC messages, async streams, an actor-isolated screen model, and a Metal renderer. We instrument each handoff with logging, apply predicted fixes, then verify end-to-end.

**Tech Stack:** Swift, Foundation Process/FileHandle, XPCOverlay, AsyncStream/AsyncChannel, OSLog, Metal, Swift Testing

---

### Task 1: Run existing PTY tests to confirm baseline

Confirm the PTY layer works in isolation before debugging the integration.

**Files:**
- Read: `TermCoreTests/PseudoTerminalTests.swift`

- [ ] **Step 1: Run PseudoTerminalTests**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/PseudoTerminalTests test 2>&1 | tail -20`

Expected: All 3 tests pass (write, resize, start+outputStream). If `test_start_and_output_stream` passes, the PTY→shell→outputStream path works locally. The bug is in XPC delivery or rendering.

- [ ] **Step 2: Run all TermCoreTests for full baseline**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests test 2>&1 | tail -30`

Expected: All tests pass. Note any failures — they may be related to the pipeline issue.

---

### Task 2: Add Logger categories for PseudoTerminal and ScreenModel

The existing `Logging.swift` has categories for `SessionHandler`, `RemotePTY`, and `ScreenBuffer`. Add categories needed for output path instrumentation.

**Files:**
- Modify: `TermCore/Logging.swift`

- [ ] **Step 1: Add pseudoTerminal and screenModel logger categories**

In `TermCore/Logging.swift`, add two new static loggers inside the `Logger.TermCore` enum:

```swift
extension Logger {
    enum TermCore {
        static let subsystem = "com.ronnyf.TermCore"
        
        static let sessionHandler = Logger(subsystem: subsystem, category: "SessionHandler")
        static let remotePTY = Logger(subsystem: subsystem, category: "RemotePTY")
        static let screenBuffer = Logger(subsystem: subsystem, category: "ScreenBuffer")
        static let pseudoTerminal = Logger(subsystem: subsystem, category: "PseudoTerminal")
        static let screenModel = Logger(subsystem: subsystem, category: "ScreenModel")
    }
}
```

- [ ] **Step 2: Build TermCore to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCore -configuration Debug build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add TermCore/Logging.swift
git commit -m "chore: add PseudoTerminal and ScreenModel logger categories"
```

---

### Task 3: Instrument the output path with diagnostic logging

Add a log statement at each handoff in the output pipeline. After this, running the app and reading Console.app will show exactly where data stops.

**Files:**
- Modify: `TermCore/PseudoTerminal.swift:102-109` (readabilityHandler)
- Modify: `rTermSupport/PTYResponder.swift:29-35` (outputTask)
- Modify: `TermCore/RemotePTY.swift:79-83` (processingTask)
- Modify: `rTerm/ContentView.swift:55-58` (connect loop)
- Modify: `TermCore/ScreenModel.swift:84` (apply)

- [ ] **Step 1: Add log in PseudoTerminal readabilityHandler**

In `TermCore/PseudoTerminal.swift`, replace the `readabilityHandler` closure inside `start()`:

```swift
        // Hook up output reading before starting the shell
        primaryHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                self?.log.debug("PTY output: EOF (0 bytes)")
                self?.outputContinuation.finish()
                handle.readabilityHandler = nil
            } else {
                self?.log.debug("PTY output: \(data.count) bytes")
                self?.outputContinuation.yield(data)
            }
        }
```

- [ ] **Step 2: Add log in PTYResponder.outputTask**

In `rTermSupport/PTYResponder.swift`, replace the `outputTask` assignment inside `spawn()`:

```swift
        outputTask = Task { [log] in
            for await data in pt.outputStream {
                try Task.checkCancellation()
                log.debug("XPC sending stdout: \(data.count) bytes")
                try session.send(RemoteResponse.stdout(data))
            }
            log.info("output stream finished")
        }
```

- [ ] **Step 3: Add log in RemotePTY processingTask**

In `TermCore/RemotePTY.swift`, add a log in the `processingTask` `for await` body. Replace:

```swift
        processingTask = Task {
            for await message in incomingMessages {
                await outputDataChannel.send(message)
            }
        }
```

with:

```swift
        processingTask = Task {
            for await message in incomingMessages {
                Logger.TermCore.remotePTY.debug("Received XPC message: \(message.count) bytes")
                await outputDataChannel.send(message)
            }
        }
```

- [ ] **Step 4: Add log in TerminalSession.connect() loop**

In `rTerm/ContentView.swift`, add a log inside the `for await` loop in `connect()`. Replace:

```swift
                for await output in remotePTY.outputData {
                    let events = parser.parse(Data(output))
                    await screenModel.apply(events)
                }
```

with:

```swift
                for await output in remotePTY.outputData {
                    let data = Data(output)
                    log.debug("Parser input: \(data.count) bytes")
                    let events = parser.parse(data)
                    await screenModel.apply(events)
                }
```

- [ ] **Step 5: Add log in ScreenModel.apply()**

In `TermCore/ScreenModel.swift`, add a log at the top of `apply(_:)`. This requires importing `OSLog` and adding a logger. Add after the existing properties:

```swift
    private let log = Logger.TermCore.screenModel
```

Then at the top of `apply(_:)`, add:

```swift
    public func apply(_ events: [TerminalEvent]) {
        log.debug("Applying \(events.count) events")
        for event in events {
```

Note: `Logger` stored properties are not allowed directly in actors. Instead, use a `nonisolated` computed property or make the log call use a static. The simplest approach is to use `nonisolated(unsafe)`:

```swift
    nonisolated(unsafe) private let log = Logger.TermCore.screenModel
```

- [ ] **Step 6: Build the app to verify all logging compiles**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build 2>&1 | tail -10`

Expected: BUILD SUCCEEDED

- [ ] **Step 7: Commit**

```bash
git add TermCore/PseudoTerminal.swift rTermSupport/PTYResponder.swift TermCore/RemotePTY.swift rTerm/ContentView.swift TermCore/ScreenModel.swift
git commit -m "debug: add output path diagnostic logging at each handoff"
```

---

### Task 4: Fix PTYResponder.outputTask error resilience

The current `outputTask` has unguarded `try` on `session.send()` — one failure kills the entire output stream. Wrap in do/catch so errors are logged but don't stop output delivery.

**Files:**
- Modify: `rTermSupport/PTYResponder.swift:29-35`

- [ ] **Step 1: Wrap session.send in do/catch**

In `rTermSupport/PTYResponder.swift`, replace the `outputTask` assignment:

```swift
        outputTask = Task { [log] in
            for await data in pt.outputStream {
                if Task.isCancelled { break }
                do {
                    log.debug("XPC sending stdout: \(data.count) bytes")
                    try session.send(RemoteResponse.stdout(data))
                } catch {
                    log.error("XPC send failed: \(error.localizedDescription)")
                }
            }
            log.info("output stream finished")
        }
```

Note: replaced `try Task.checkCancellation()` with `if Task.isCancelled { break }` so cancellation doesn't throw through the catch.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add rTermSupport/PTYResponder.swift
git commit -m "fix(PTYResponder): make outputTask resilient to individual send errors"
```

---

### Task 5: Instrument the input path and fix first responder

Add diagnostic logging to the input path and fix the most likely input issue: first responder not being set.

**Files:**
- Modify: `rTerm/TermView.swift:38-44` (keyDown) and `rTerm/TermView.swift:253-262` (makeNSView)
- Modify: `rTerm/ContentView.swift:66-72` (sendInput)
- Modify: `rTermSupport/PTYResponder.swift:48-49` (respond .input)

- [ ] **Step 1: Add keyDown logging in TerminalMTKView**

In `rTerm/TermView.swift`, add a logger and log inside `keyDown`. Add a property to the class:

```swift
final class TerminalMTKView: MTKView {

    private let log = Logger(subsystem: "rTerm", category: "TerminalMTKView")

    /// Called with the encoded byte sequence for each key-down event.
    var onKeyInput: ((Data) -> Void)?
```

Then update `keyDown`:

```swift
    override func keyDown(with event: NSEvent) {
        let encoder = KeyEncoder()
        if let data = encoder.encode(event) {
            log.debug("keyDown: keyCode=\(event.keyCode), encoded \(data.count) bytes")
            onKeyInput?(data)
        } else {
            log.debug("keyDown: keyCode=\(event.keyCode), unhandled")
        }
        // Swallow all key events — do not call super.
    }
```

Add `import OSLog` at the top of the file if not already present.

- [ ] **Step 2: Fix first responder in makeNSView**

In `rTerm/TermView.swift`, update `makeNSView` to request first responder after the view is in the window:

```swift
    func makeNSView(context: Context) -> TerminalMTKView {
        let coordinator = context.coordinator
        let view = TerminalMTKView(frame: .zero, device: coordinator.device)
        view.delegate = coordinator
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.onKeyInput = onInput

        // Request first responder after the view is added to the window hierarchy.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }

        return view
    }
```

- [ ] **Step 3: Add sendInput logging in TerminalSession**

In `rTerm/ContentView.swift`, update `sendInput`:

```swift
    func sendInput(_ data: Data) {
        log.debug("sendInput: \(data.count) bytes")
        do {
            try remotePTY.send(command: RemoteCommand.input(data))
        } catch {
            log.error("sendInput error: \(error.localizedDescription)")
        }
    }
```

- [ ] **Step 4: Add input logging in PTYResponder**

In `rTermSupport/PTYResponder.swift`, update the `.input` case in `respond`:

```swift
        case .input(let data):
            log.debug("PTY write: \(data.count) bytes")
            pseudoTerminal?.write(data)
            return nil
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 6: Commit**

```bash
git add rTerm/TermView.swift rTerm/ContentView.swift rTermSupport/PTYResponder.swift
git commit -m "fix(TermView): set first responder, add input path diagnostic logging"
```

---

### Task 6: Write shell echo integration test

Test the PTY→parser→ScreenModel pipeline without XPC or rendering. This captures the fix and prevents regression.

**Files:**
- Modify: `TermCoreTests/PseudoTerminalTests.swift`

- [ ] **Step 1: Write the failing test**

Add a new test to `TermCoreTests/PseudoTerminalTests.swift` that spawns a shell, sends `echo hello`, and verifies the output reaches a `ScreenModel` through `TerminalParser`:

```swift
    @Test("shell echo reaches ScreenModel through parser pipeline")
    func test_shell_echo_through_parser_to_screen() async throws {
        let pt = try PseudoTerminal(shell: .sh)
        let _ = try pt.start()

        let screenModel = ScreenModel(cols: 80, rows: 24)
        var parser = TerminalParser()

        // Send a command that produces known output
        pt.write(Data("echo hello\r".utf8))

        // Collect output for up to 2 seconds
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            let chunk = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    for await data in pt.outputStream {
                        return data
                    }
                    return nil
                }
                group.addTask {
                    try await Task.sleep(for: .milliseconds(200))
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }

            guard let chunk else { break }

            let events = parser.parse(chunk)
            await screenModel.apply(events)

            // Check if "hello" appears in the grid
            let snap = await screenModel.snapshot()
            let text = (0..<snap.rows).map { row in
                (0..<snap.cols).map { col in
                    String(snap[row, col].character)
                }.joined()
            }.joined()

            if text.contains("hello") {
                // Success — "hello" reached the screen model
                return
            }
        }

        // If we get here, "hello" never appeared
        let snap = await screenModel.snapshot()
        let firstRowText = (0..<snap.cols).map { String(snap[0, $0].character) }.joined()
        #expect(Bool(false), "Expected 'hello' in screen model, first row: '\(firstRowText.trimmingCharacters(in: .whitespaces))'")
    }
```

- [ ] **Step 2: Run test to verify it passes (or identify PTY issue)**

Run: `xcodebuild -project rTerm.xcodeproj -scheme TermCoreTests -only-testing TermCoreTests/PseudoTerminalTests/test_shell_echo_through_parser_to_screen test 2>&1 | tail -20`

Expected: PASS — confirming the PTY→parser→ScreenModel path works without XPC. If it fails, the issue is in the PTY/shell setup and needs further investigation before proceeding.

- [ ] **Step 3: Commit**

```bash
git add TermCoreTests/PseudoTerminalTests.swift
git commit -m "test: add shell echo integration test through parser to ScreenModel"
```

---

### Task 7: Build app and manual end-to-end verification

Run the app, check Console.app logs, verify the pipeline works.

**Files:**
- Read: Console.app output (filtered by subsystem `com.ronnyf.TermCore` and `rTerm`)

- [ ] **Step 1: Build the app**

Run: `xcodebuild -project rTerm.xcodeproj -scheme rTerm -configuration Debug build 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Run the app from Xcode and check Console.app**

Open Console.app, filter by `com.ronnyf` to see all rTerm/TermCore logs. Then run the app from Xcode (Product → Run or Cmd+R).

Check the log output for:
1. `"activating session"` — XPC connected ✓
2. `"spawn reply: spawned"` — Shell spawned ✓
3. `"PTY output: N bytes"` — Shell produced output ✓ (or ✗ = S1)
4. `"XPC sending stdout: N bytes"` — XPC service sending ✓ (or ✗ = S2)
5. `"Received XPC message: N bytes"` — Client received ✓ (or ✗ = S3)
6. `"Parser input: N bytes"` — Data entering parser ✓
7. `"Applying N events"` — Events reaching screen model ✓ (or ✗ = S4)

The **first missing log** identifies the break point. If all logs appear but no rendering: the issue is Metal/GlyphAtlas (S4).

- [ ] **Step 3: Test keyboard input**

Click on the terminal view to ensure first responder, then type `ls` and press Enter. Check logs for:
1. `"keyDown: keyCode=..."` — Events reaching the view ✓ (or ✗ = S5)
2. `"sendInput: N bytes"` — Data leaving the app ✓
3. `"PTY write: N bytes"` — Data reaching the service ✓
4. New `"PTY output"` / `"Applying N events"` logs from the shell response ✓

- [ ] **Step 4: Verify end-to-end**

Confirm these work:
1. Shell prompt appears on screen after launch
2. Type `echo test` + Enter → "test" appears in output
3. Ctrl+C → no crash, shell stays alive
4. `exit` + Enter → session ends (output stream finishes)

- [ ] **Step 5: If any break point is found, fix it**

If logs reveal a specific break point not covered by the fixes already applied:
- Document the finding
- Apply the minimal fix
- Re-run the app to verify

- [ ] **Step 6: Commit any additional fixes**

```bash
git add -A
git commit -m "fix: resolve pipeline break at [location identified by logs]"
```

---

## Verification Checklist

- [ ] All existing TermCoreTests pass
- [ ] New shell echo integration test passes
- [ ] App builds without errors
- [ ] Console.app shows data flowing through all 5 output path stages
- [ ] Shell prompt renders on screen
- [ ] Keyboard input reaches the shell and produces visible output
