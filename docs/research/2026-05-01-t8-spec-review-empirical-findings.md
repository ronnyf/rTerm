# T8 Spec Review — Empirical Findings

**Commit reviewed:** `8cb30b2` ("input: bracketed paste (Phase 2 T8)")
**Plan reference:** `docs/superpowers/plans/2026-05-01-control-chars-phase2.md` lines 2994–3234
**Reviewer:** Code Review Agent
**Date:** 2026-05-01

---

## Overall Verdict

SPEC COMPLIANT with two documented, justified deviations and one minor deviation.
All required functionality is present and correct. No critical issues found.

---

## File Scope Check

Files touched by the commit:

| File | Expected | Actual |
|------|----------|--------|
| `rTerm/ContentView.swift` | Modify | Modified |
| `rTerm/TermView.swift` | Modify | Modified |
| `rTermTests/BracketedPasteTests.swift` | Create | Created |
| `rTerm.xcodeproj/project.pbxproj` | Implicit (new test file registration) | Modified |

No files outside the allowed set were touched. The xcodeproj change is the expected side-effect of adding a new source file.

---

## `TerminalSession.bracketedPasteWrap(_:enabled:)`

**Plan required:** `public static func bracketedPasteWrap(_ text: String, enabled: Bool) -> Data`

**Actual:** `nonisolated public static func bracketedPasteWrap(_ text: String, enabled: Bool) -> Data`

All requirements confirmed:

- Declared `public static`. Correct.
- Returns `Data`. Correct.
- ESC[200~ prefix: `[0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]`. Correct.
- ESC[201~ suffix: `[0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]`. Correct.
- `guard enabled else { return payload }` returns raw `Data(text.utf8)` when disabled. Correct.
- Empty string with `enabled: true` emits the 12-byte envelope with zero payload bytes. Correct.
- `reserveCapacity(payload.count + 12)`: the envelope is exactly 6 + 6 = 12 bytes. Correct.

### Deviation D1: `nonisolated` added to `bracketedPasteWrap`

**Implementer's rationale:** The function is pure (no actor state reads or writes), so `nonisolated` is semantically correct and required for the test file to call it without a `MainActor` annotation or `await`. The function does not need `@MainActor` isolation because it takes only `String` and `Bool` parameters and produces a `Data` value with no side effects.

**Assessment:** JUSTIFIED. The plan's code block omitted `nonisolated`, but the plan's stated intent was "testable without an AppKit responder dance." `nonisolated` is the correct keyword to satisfy that intent on a `@MainActor`-isolated class. This is a correction to the plan, not a departure from it.

---

## `TerminalSession.paste(_:)`

Confirmed:

- Reads `screenModel.latestSnapshot().bracketedPaste`. `latestSnapshot()` is nonisolated and lock-protected on `ScreenModel` (verified in `TermCore/ScreenSnapshot.swift` and `TermCore/ScreenModel.swift`). No actor hop on the call path.
- Calls `Self.bracketedPasteWrap(text, enabled: enabled)`. Correct.
- Calls `sendInput(data)`. Correct.

---

## `TerminalMTKView` — `onPaste` property

**Plan required:** `var onPaste: ((String) -> Void)?`

**Actual:** `var onPaste: ((String) -> Void)?` at line 46 of `TermView.swift`. Correct.

---

## `TerminalMTKView.paste(_:)`

**Plan required:** `@objc override func paste(_ sender: Any?)`

**Actual:** `@objc func paste(_ sender: Any?)` (no `override`)

Confirmed behavior:
- Reads `NSPasteboard.general.string(forType: .string)`.
- Guards on non-empty string.
- Logs `paste: \(str.count) chars`.
- Calls `onPaste?(str)`. Correct.

### Deviation D2: `override` removed from `paste(_:)` and `validateMenuItem(_:)`

**Implementer's rationale:** These are informal-protocol selector methods picked up via responder-chain dispatch, not methods declared on `MTKView` or `NSView`.

**Verification against SDK headers (MacOSX27.0 SDK):**

`NSResponder.h` — does NOT declare `paste(_:)` or `validateMenuItem(_:)`. The file was read in full; neither selector appears.

`NSView.h` — does NOT declare `paste(_:)` or `validateMenuItem(_:)`.

`NSText.h` — declares `- (void)paste:(nullable id)sender;`, but `TerminalMTKView` does not inherit from `NSText`.

`validateMenuItem(_:)` is a requirement of the `NSMenuItemValidation` protocol, declared in `NSMenu.h`. It is an informal-protocol method on `NSObject` via `NSMenuValidation` for Swift < 4.2, but there is no superclass on `MTKView`'s chain that has a Swift-visible `override`-able declaration.

**Conclusion:** `override` would be a compile error for `paste(_:)` and is not applicable for `validateMenuItem(_:)` (a protocol requirement, not an inherited method). Removing `override` is correct. The plan's code blocks were wrong on this point; the implementer's deviation fixes a bug in the plan.

---

## `TerminalMTKView.validateMenuItem(_:)` — fallback return value

**Plan required:** `return super.validateMenuItem(menuItem)` as the fallback for actions other than `paste(_:)`.

**Actual:** `return true`

This is a **minor deviation** from the plan spec.

**Analysis:** Because `validateMenuItem(_:)` is a protocol method (`NSMenuItemValidation`), there is no `super` implementation callable. If `override` were present (it is not), a `super.validateMenuItem` call would attempt to call into `MTKView` or `NSView`, neither of which declares the method. In practice, `return true` is functionally correct — it enables all other menu items by default, which is the standard behavior for a view that does not restrict any actions beyond paste. The plan called for `return super.validateMenuItem(menuItem)` in the context of having `override` on the method; since `override` was correctly removed, the `super` call was no longer possible.

**Severity:** Trivial. No functional regression. The behavior is correct for the terminal use case (no menu items other than paste need restriction). The plan's `super` fallback was dependent on the now-invalid `override`, so the implementation's `return true` is the appropriate substitution.

---

## `#selector` reference in `validateMenuItem`

**Plan used:** `#selector(NSText.paste(_:))`

**Actual:** `#selector(paste(_:))`

`#selector(paste(_:))` resolves to the `paste(_:)` method defined directly on `TerminalMTKView` (the `@objc func paste` above). This is more precise than `#selector(NSText.paste(_:))` because it explicitly names the selector defined in this class, not a different class's declaration. Both resolve to the same Objective-C selector string `"paste:"`. This is a minor improvement, not a problem.

---

## `TermView` SwiftUI Bridge

Confirmed in `TermView.swift`:

- `var onPaste: ((String) -> Void)?` added to `TermView` struct. Correct.
- `makeNSView`: `view.onPaste = onPaste` present. Correct.
- `updateNSView`: `nsView.onPaste = onPaste` present. Correct.
- No drift between `makeNSView` and `updateNSView`. Correct.

---

## `ContentView`

Confirmed:

`onPaste: { text in session.paste(text) }` passed in the `TermView` constructor at line 204 of `ContentView.swift`. Correct.

---

## Tests — `BracketedPasteTests.swift`

All 4 tests present and match the plan's exact signatures and byte sequences:

| Test | Plan match |
|------|-----------|
| `test_wrap_enabled` | Exact match — `Data([0x1B,0x5B,0x32,0x30,0x30,0x7E])` + payload + `Data([0x1B,0x5B,0x32,0x30,0x31,0x7E])` |
| `test_wrap_disabled` | Exact match — `"hello".data(using: .utf8)` |
| `test_wrap_empty_enabled` | Exact match — 12-byte envelope only |
| `test_wrap_multibyte_utf8` | Exact match — prefix/suffix/middle slice checks |

Suite annotation `@Suite("Bracketed paste")` present. `@testable import rTerm` present. GPLv3 header present.

---

## Summary Table

| Requirement | Status | Notes |
|-------------|--------|-------|
| `bracketedPasteWrap` is `public static` | PASS | |
| `bracketedPasteWrap` returns `Data` | PASS | |
| ESC[200~ prefix bytes correct | PASS | |
| ESC[201~ suffix bytes correct | PASS | |
| Disabled returns raw UTF-8 | PASS | |
| Empty string gets envelope when enabled | PASS | |
| `nonisolated` on helper | DEVIATION D1 — justified correction | |
| `paste(_:)` reads bracketedPaste from latestSnapshot | PASS | |
| `paste(_:)` calls bracketedPasteWrap + sendInput | PASS | |
| `onPaste` property on TerminalMTKView | PASS | |
| `paste(_:)` reads NSPasteboard, guards non-empty, calls onPaste | PASS | |
| `validateMenuItem(_:)` gates on pasteboard availability | PASS | |
| `override` removed from paste(_:) / validateMenuItem(_:) | DEVIATION D2 — justified fix | |
| validateMenuItem fallback `return true` vs `return super` | MINOR DEVIATION — no functional impact | |
| `onPaste` in TermView struct | PASS | |
| makeNSView wires onPaste | PASS | |
| updateNSView wires onPaste | PASS | |
| ContentView passes onPaste closure | PASS | |
| 4 BracketedPasteTests present | PASS | |
| Test byte sequences match plan exactly | PASS | |
| Only allowed files modified | PASS | |
