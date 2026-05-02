# T7 Quality Review — Empirical Findings

Date: 2026-05-01
Reviewer: Claude Sonnet 4.6 (code-reviewer role)
Commit: 94b1cf7 (branch phase-2-control-chars)

---

## Q1: Is `@frozen public enum CursorKeyMode` appropriate?

**Method:** Checked `BUILD_LIBRARY_FOR_DISTRIBUTION` across all xcconfig files. Verified the module that declares `CursorKeyMode`.

**Findings:**
- `CursorKeyMode` is declared in `rTerm/KeyEncoder.swift`, which belongs to the `rTerm` app target.
- `rTerm.xcconfig` does NOT set `BUILD_LIBRARY_FOR_DISTRIBUTION`. The xcconfig has no distribution key at all.
- `TermCore.xcconfig` sets `BUILD_LIBRARY_FOR_DISTRIBUTION = NO` (Debug) and `YES` (Release).
- `TermUI.xcconfig` sets `BUILD_LIBRARY_FOR_DISTRIBUTION = YES`.
- The `rTerm` app target is an executable, not a library. ABI stability / `@frozen` resilience machinery applies only to frameworks with `BUILD_LIBRARY_FOR_DISTRIBUTION = YES`.

**Conclusion:** `@frozen` on `CursorKeyMode` in the rTerm app target has zero ABI effect — the attribute is meaningless for an app binary (the compiler accepts it, but it generates no extra resilience metadata). It is safe but misleading, implying a library-evolution concern that does not exist here. Contrast: in `TermCore`, `@frozen` on `C0Control` and `BufferKind` is deliberate and correct because TermCore is a distributable framework. The consistent project convention (visible in `CSICommand.swift`, `DECPrivateMode.swift`) is to annotate `@frozen` with a rationale comment explaining which stable-spec it mirrors. `CursorKeyMode`'s doc comment does this correctly ("Mirrors DECCKM (DEC private mode 1)"), which is the real justification — not ABI, but semantic closure-by-spec.

**Verdict:** `@frozen` is harmless and its doc comment rationale is sound. No fix needed, but note it has no ABI effect here.

---

## Q2: Does `KeyEncoder` remain Sendable and stateless after T7?

**Method:** Read full `KeyEncoder.swift` post-T7. Checked for any stored properties. Verified `encode` signature. Checked test default parameter usage.

**Findings:**
- `KeyEncoder` is a `public struct` with no stored properties (`public init() {}` only).
- The `cursorKeyMode: CursorKeyMode = .normal` parameter is per-call, no state mutation.
- `CursorKey` (private enum) has no state.
- `KeyEncoder` is explicitly `Sendable`, and its `public` conformance is correct for a no-state struct.

**Conclusion:** Confirmed stateless and Sendable. No issues.

---

## Q3: `cursorKey(_:mode:)` helper design

**Method:** Read the implementation at KeyEncoder.swift:95–108.

**Findings:**
```swift
private enum CursorKey { case up, down, right, left }

private func cursorKey(_ key: CursorKey, mode: CursorKeyMode) -> Data {
    let final: UInt8
    switch key {
    case .up:    final = 0x41
    case .down:  final = 0x42
    case .right: final = 0x43
    case .left:  final = 0x44
    }
    let intro: UInt8 = (mode == .application) ? 0x4F : 0x5B
    return Data([0x1B, intro, final])
}
```

- `CursorKey` is `private` (nested in the file scope, but effectively private since `KeyEncoder` is the only user). Correct.
- The two-switch design (separate switch on key, then ternary on mode) is readable.
- Alternative: a single `switch (key, mode)` would be 8 cases with more repetition of `0x1B`. The current design is more compact and correct.
- The `final` identifier name shadows the Swift keyword conceptually but is legal as an identifier (it's not a reserved word in Swift).

**Conclusion:** Design is clean. `CursorKey` private enum is appropriate. No issues.

---

## Q4: Magic keyCode numbers — named constants vs inline literals

**Method:** Read the switch block at KeyEncoder.swift:48–73. Reviewed existing project style in Phase 1 KeyEncoder.

**Findings:**
- Phase 1 already used inline magic numbers (keyCode 36, 51, 48) with inline comments.
- T7 continues the same style (keyCode 126, 125, 124, 123, 115, 119, 116, 121, 117) with inline comments explaining the mapping.
- The existing Phase 1 tests (KeyEncoderTests.swift:103–131) also hardcode the same numbers, cross-referencing the same mapping.
- Apple does not expose `NSEvent.SpecialKey` constants for arrow keys in a way that avoids the magic-number problem (the type exists but uses virtual key codes indirectly).
- Named constants (`static let upArrowKeyCode: UInt16 = 126`) would co-locate the number with a name but offer no compile-time verification.
- Comment style `// keyCode 126 = up arrow` is already established in the test file (`mockKeyDown` for keyCode 126).

**Conclusion:** Inline literals + comments are consistent with Phase 1 style and adequate. Named constants would be marginally cleaner but are not a quality regression. No fix required.

---

## Q5: `cursorKeyModeProvider` closure — hot-path safety

**Method:** Traced the call path: `keyDown` → `cursorKeyModeProvider?()` → `model.latestSnapshot()`. Verified `latestSnapshot` isolation.

**Findings:**
- `keyDown` runs on the AppKit responder chain, which is on MainActor.
- `cursorKeyModeProvider` is a stored closure on `TerminalMTKView`; LSP hover confirms it is `@MainActor var cursorKeyModeProvider`.
- `latestSnapshot()` is `nonisolated` (ScreenModel.swift:681), backed by `Mutex<SnapshotBox>`.
- `SnapshotBox` is a `final class: Sendable` holding an immutable `ScreenSnapshot` struct; the mutex guards a pointer swap, not a full struct copy.
- The closure captures `model: ScreenModel` (the actor itself), but only calls `nonisolated latestSnapshot()`. No actor hop, no `await`. Safe on the input hot path.
- No caching is needed: the lock is a single pointer read and is already negligible.

**Conclusion:** Closure design is correct and efficient. No issues.

---

## Q6: `makeNSView` / `updateNSView` duplication of `cursorKeyModeProvider`

**Method:** Read TermView.swift:77–101.

**Findings:**
```swift
// makeNSView:
let model = screenModel
view.cursorKeyModeProvider = {
    model.latestSnapshot().cursorKeyApplication ? .application : .normal
}

// updateNSView:
let model = screenModel
nsView.cursorKeyModeProvider = {
    model.latestSnapshot().cursorKeyApplication ? .application : .normal
}
```

- The two closures are byte-for-byte identical. The only difference is the target variable (`view` vs `nsView`).
- The `let model = screenModel` capture pattern avoids capturing `self` (which is a `struct`). But since `TermView` is a struct, capturing `self` would just copy the struct anyway — the explicit `let model` capture is technically equivalent but visually clearer.
- The duplication is real: if the closure body changes (e.g., when T8 adds paste mode, or T10 adds scroll intercept), it must be updated in two places.
- A private helper `func makeCursorKeyModeProvider() -> (() -> CursorKeyMode)` would centralize it.

**Conclusion:** Duplication is a maintenance concern (not a correctness issue). The cost of the reassignment on every SwiftUI update pass is immeasurable — it's a stored property write on a small object.

---

## Q7: `updateNSView` reassigning the closure on every SwiftUI update

**Method:** Read the pattern. Checked what `TermView`'s `@Observable` dependencies are (none directly — it reads `session.screenModel` from `ContentView`).

**Findings:**
- `updateNSView` is called whenever SwiftUI decides to reconcile the view (any parent state change). For a terminal emulator rendering at 60 fps, SwiftUI updates are typically low-frequency (user interaction, title changes).
- The closure assignment writes an 8-byte function pointer + capture. This is O(1) and trivially cheap.
- The existing `onKeyInput = onInput` and `clearColor` reassignments already establish this pattern as intentional and acceptable.

**Conclusion:** Cost is negligible. Not an issue.

---

## Q8: `CursorKeyMode` placement — should it be in TermCore?

**Method:** Traced what uses `CursorKeyMode`: `KeyEncoder.swift`, `TermView.swift`, `KeyEncoderTests.swift`. Checked if any TermCore type references it.

**Findings:**
- No TermCore file imports or references `CursorKeyMode`.
- `ScreenSnapshot.cursorKeyApplication` returns `Bool` — TermCore decouples itself from the `CursorKeyMode` type intentionally.
- `CursorKeyMode` is a pure UI/input-encoding concern. Keeping it in `rTerm` target is architecturally correct.

**Conclusion:** Placement is correct.

---

## Q9: `mockKeyDown` force-unwrap — safety of `NSEvent.keyEvent(...)!`

**Method:** Read mockKeyDown at KeyEncoderTests.swift:62–79. Compared to `makeKeyEvent` helper (returns optional).

**Findings:**
- `NSEvent.keyEvent(with:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:)` returns `NSEvent?`.
- Apple's docs note it returns nil if the event type is not a key event type. Since `.keyDown` is always a key event type, this path cannot return nil with valid arguments.
- The helper supplies: valid `.keyDown` event type, `.zero` location, zero timestamp, zero windowNumber, nil context, empty characters, zero-or-valid keyCode. None of these can cause a nil return.
- `makeKeyEvent` (Phase 1 helper) returns optional and is used with `try #require(...)`. The `mockKeyDown` helper is a different design: it documents that it always succeeds by using `!` and returning `NSEvent` (non-optional).
- The `@MainActor` annotation is correct since `NSEvent.keyEvent` must be called on the main thread per AppKit threading rules.

**Conclusion:** Force-unwrap is safe. The input parameters are provably valid. No crash risk. This is an acceptable pattern for a test helper where the arguments are statically known. The dual-helper situation (optional vs non-optional) creates minor friction but doesn't warrant a change.

---

## Q10: Test redundancy — `test_arrow_up_normal_mode` vs `test_all_arrows_normal_mode`

**Method:** Read all 9 new tests.

**Findings:**
- `test_arrow_up_normal_mode` (line 191): single test, up arrow, normal mode. ESC [ A.
- `test_all_arrows_normal_mode` (line 206): loop over all 4 arrows including up. Normal mode.
- `test_arrow_up_application_mode` (line 199): single test, up arrow, application mode.
- `test_all_arrows_application_mode` (line 221): loop over all 4 arrows including up. Application mode.

The `test_arrow_up_*` tests are subsumed by `test_all_arrows_*`. The up-arrow case is tested twice in normal mode and twice in application mode. This is intentional documentation-style redundancy: the single-key tests make the most common case explicit and independently named, while the grouped tests verify correctness of the 4-case mapping exhaustively. The pattern is consistent with how the Phase 1 tests document Return/Delete/Tab individually.

**Conclusion:** Redundancy is intentional and harmless. No test simplification needed.

---

## Q11: Retain cycle analysis — `ScreenModel` captured in `cursorKeyModeProvider`

**Method:** Traced ownership graph.

**Findings:**
```
ContentView (@State) → TerminalSession → ScreenModel (actor)
ContentView (body) → TermView (struct) → makeNSView → TerminalMTKView (NSView)
TerminalMTKView.cursorKeyModeProvider captures: model: ScreenModel
```

- `TerminalMTKView` is owned by AppKit's view hierarchy, which is owned by SwiftUI's bridge. SwiftUI does not store a back-reference to `ScreenModel`.
- `ScreenModel` does not own `TerminalMTKView` or `TermView`.
- The closure on `TerminalMTKView` captures `ScreenModel` strongly. This is a one-directional reference: view → model. No cycle.
- `TerminalSession` owns `ScreenModel` and is owned by `ContentView @State`. `TerminalMTKView` holding a reference to `ScreenModel` extends its lifetime while the view is alive, which is the correct behavior (the model must outlive the view).

**Conclusion:** No retain cycle. Correct.

---

## Q12: `@frozen` on `CursorKeyMode` — is it consistent with the project convention for spec-closed enums?

**Method:** Reviewed all `@frozen` annotations across TermCore and rTerm.

**Findings:**
- Pattern in TermCore: `@frozen` is applied to `C0Control` ("exhaustive per POSIX/ECMA-48"), `BufferKind` ("only two VT100 buffers exist"), `EraseRegion` ("only 3 possible values"), `CellAttributes` (OptionSet, closed). Each has a rationale comment.
- Pattern: deliberately NOT `@frozen` on `CSICommand` (open-world unknown case), `DECPrivateMode`, `SGRAttribute`, `OSCCommand`, `TerminalEvent`.
- `CursorKeyMode` has exactly 2 cases: normal, application. The DECCKM spec defines precisely these two states. There is no "unknown" state. The doc comment says "Mirrors DECCKM (DEC private mode 1)".
- This matches the project's own `@frozen` policy: "spec-closed enum where adding a new case would be a spec violation."

**Conclusion:** `@frozen` is semantically correct by the project's own convention, even though it has no ABI effect in this target. Consistent with the codebase pattern.

---

## Q13: `TermView` concurrency — closure isolation under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`

**Method:** Read rTerm.xcconfig, TermView.swift. Checked LSP hover on key types.

**Findings:**
- `rTerm` target has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. All declarations without explicit isolation get `@MainActor` inferred.
- `TermView` is a struct conforming to `NSViewRepresentable`, which is `@MainActor @preconcurrency`. Both `makeNSView` and `updateNSView` are `@MainActor`.
- `cursorKeyModeProvider: (() -> CursorKeyMode)?` on `TerminalMTKView`: LSP confirms `@MainActor var`.
- The closure body calls `model.latestSnapshot()` which is `nonisolated`. No isolation crossing in the closure.
- `TerminalMTKView.keyDown` runs on MainActor. Reading `cursorKeyModeProvider` from `keyDown` is safe (same actor).
- `rTermTests` target has `SWIFT_DEFAULT_ACTOR_ISOLATION = nonisolated`. The explicit `@MainActor` on `mockKeyDown` and `KeyEncoderTests` is required and present.

**Conclusion:** Isolation is correct. No issues.
