# T8 Quality Review — Empirical Findings

Date: 2026-05-01
Commit: 8cb30b2 ("input: bracketed paste (Phase 2 T8)")
Reviewer: Claude Sonnet 4.6 (code-reviewer role)

## Files Changed

| File | Lines Added | Nature |
|------|-------------|--------|
| rTerm/ContentView.swift | +33 | bracketedPasteWrap + paste(_:) on TerminalSession |
| rTerm/TermView.swift | +29 | paste(_:), validateMenuItem(_:), onPaste wiring |
| rTermTests/BracketedPasteTests.swift | +52 | 4 new tests (new file) |
| rTerm.xcodeproj/project.pbxproj | +4 | BracketedPasteTests.swift added to rTermTests target |

## Q: Is `reserveCapacity(payload.count + 12)` accurate?

Yes. The two bracketed-paste envelopes are each exactly 6 bytes:
- ESC [ 2 0 0 ~ = 0x1B 0x5B 0x32 0x30 0x30 0x7E (6 bytes)
- ESC [ 2 0 1 ~ = 0x1B 0x5B 0x32 0x30 0x31 0x7E (6 bytes)

Total overhead: 12 bytes. `reserveCapacity(payload.count + 12)` is exact.

## Q: Is `paste(_:)` on NSResponder, making missing `override` a bug?

No. Verified against
`MacOSX27.0.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSResponder.h`:
`paste:` does NOT appear on `NSResponder` in the SDK headers. It appears on
`NSText` (line 128) and `NSTextView`. NSTextView's header says "These methods
are like `paste:` (from NSResponder)" in a comment, but the method is not
actually declared on `NSResponder` in the current SDK. AppKit dispatches
`paste:` via the responder-chain target-action mechanism; any object that
implements the selector will receive it. No `override` is possible or required
on `MTKView`. The comment in TermView.swift explaining this is correct.

## Q: Is `NSMenuItemValidation` a formal protocol? Does missing conformance matter?

`NSMenuItemValidation` IS a formal protocol, declared in
`NSMenu.h` (MacOSX27.0.sdk):

```objc
@protocol NSMenuItemValidation <NSObject>
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem NS_SWIFT_UI_ACTOR;
@end
```

The old Objective-C informal-protocol category `NSMenuValidation` is
deprecated since macOS 11.0 and hidden behind `#if __swift__ < 40200`.

`TerminalMTKView` does not declare `NSMenuItemValidation` conformance.
At runtime this is harmless — AppKit checks `respondsToSelector:` before
calling `validateMenuItem:`, so the method will be invoked correctly. However:

1. The code comment on line 78-80 of TermView.swift incorrectly calls it an
   "informal protocol". It is a formal protocol since macOS 11.
2. Missing the conformance declaration means the Swift compiler does not
   verify that the method signature matches the protocol requirement, and
   `TerminalMTKView` won't appear in protocol-typed contexts.
3. The correct fix is:
   ```swift
   final class TerminalMTKView: MTKView, NSMenuItemValidation {
   ```
   with `override` added before `func validateMenuItem`.

## Q: `validateMenuItem(_:)` returns `true` for non-paste items — correct?

The current implementation:
```swift
func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    if menuItem.action == #selector(paste(_:)) {
        return NSPasteboard.general.string(forType: .string) != nil
    }
    return true
}
```

This returns `true` for any menu item whose action is not `paste(_:)`, which
enables every other menu item unconditionally. This is the standard pattern
for objects that only handle a subset of menu actions: for items you don't own,
return `true` so they remain enabled (or rely on the responder chain to find
the correct validator). Returning `false` would wrongly disable actions handled
by items higher in the responder chain that happen to reach this validator first.

Prior behavior (T7) did not have `validateMenuItem` at all; items were
validated by the default AppKit behavior (enabled). The current `return true`
for non-paste items is equivalent to that prior behavior — no regression.

The theoretically more defensive pattern is to call super:
```swift
return super.validateMenuItem(menuItem)
```
But `MTKView` / `NSView` / `NSResponder` do not declare `validateMenuItem`,
so `super` is not callable here. `return true` is the correct and conventional
fallback.

## Q: Is `paste(_:)` in `TerminalMTKView` invoked from the MainActor?

LSP hover confirms the synthesized Swift declaration is:
`@objc @MainActor func paste(_ sender: Any?)` (TermView.swift:71)

AppKit invokes responder-chain actions on the main thread. `TerminalMTKView`
is `@MainActor` (inherited from `MTKView` via `NSView`). The `onPaste` closure
routes to `session.paste(text)`, which is on `TerminalSession` (`@Observable
@MainActor`). The full call chain is same-isolation. No actor crossing.

## Q: `paste(_:)` log message — privacy concern?

`log.debug("paste: \(str.count) chars")` logs the character count only, not
the pasteboard content. At `debug` level this is not captured in production
logs. The existing codebase has no privacy annotations on any log call
(verified via `rg "privacy"`): `sendInput: \(data.count) bytes` at line 102,
`keyDown: keyCode=\(event.keyCode)` at line 59, etc. — all un-annotated.
The absence of `.public` annotations is consistent with the rest of the file.
No user content is logged; only metadata (counts, key codes). This is
acceptable.

## Q: `nonisolated public static` on a non-public class — access level issue?

`bracketedPasteWrap` is declared `public static` on `TerminalSession`, which
is an `internal class` (no explicit access modifier, so `internal` by default
in a non-framework target). `public` on a member of an `internal` type is
effectively `internal` — the Swift compiler accepts this but it is misleading.
There is no `public` API surface in the `rTerm` app target (it is not a
framework). The `public` modifier serves only to signal intended testability
(the method is accessed via `@testable import rTerm` in tests). Established
pattern in the project: `TerminalPalette` and `RGBA` use `nonisolated public
static` for the same reason (lines 48, 100 in TerminalPalette.swift; lines 40,
41 in RGBA.swift). So this is an existing project convention, not a T8
introduction.

## Q: `TermView` makeNSView / updateNSView drift check

Both `makeNSView` and `updateNSView` assign:
- `view.onKeyInput = onInput` / `nsView.onKeyInput = onInput`
- `view.onPaste = onPaste` / `nsView.onPaste = onPaste`  (NEW in T8)
- `view.cursorKeyModeProvider = makeCursorKeyModeProvider()` / same

No drift. T7's `cursorKeyModeProvider` is present in both. T8's `onPaste` is
present in both. The `clearColor` is in `updateNSView` only (correct: it only
needs to react to settings changes, not initial make).

## Q: T7 comment forward-reference to T8/T10

TermView.swift line 128-129:
```
// keeps `makeNSView` and `updateNSView` in lockstep as T8/T10 add more
// view-callback hooks.
```
This comment was written in T7 as an explanation of why `makeCursorKeyModeProvider`
was extracted. T8 is now complete; T10 is still pending. The reference to T8
is now stale (it was a future task at time of writing). Minor hygiene issue.

## Q: `!str.isEmpty` guard in paste — correct?

`guard let str = pb.string(forType: .string), !str.isEmpty else { return }`

Silently drops empty paste. A terminal that receives a bracketed paste with
zero bytes between the envelopes is technically valid (RFC specifies that
shells must handle it). However, for a real user interaction (Edit > Paste),
pasting an empty string is a no-op from the user's perspective, so the guard
is pragmatically reasonable. The `bracketedPasteWrap` test at line 34 confirms
the empty-string case is handled correctly by the wrapper — the guard here
just prevents a useless XPC send.

## Q: Test coverage gaps?

The 4 tests in `BracketedPasteTests` cover:
1. `test_wrap_enabled` — complete envelope check
2. `test_wrap_disabled` — raw bytes
3. `test_wrap_empty_enabled` — empty string with envelope
4. `test_wrap_multibyte_utf8` — UTF-8 payload preservation

Not covered:
- `empty string, enabled: false` — returns `Data()`, trivially correct from
  the guard path; no test needed.
- `paste(_:)` integration (reads snapshot, calls sendInput) — cannot be unit
  tested without a live daemon; not a gap for this PR.
- `validateMenuItem` returning correct bool — not unit testable without
  a live AppKit event loop.

Coverage is appropriate for a pure-function static helper. No gaps.

## Q: `NSMenuItemValidation` — runtime impact of missing conformance?

AppKit's `NSMenuItem.update` calls `[NSApp targetForAction:... from:menuItem]`
to find the validator, then checks `respondsToSelector:` before dispatching
`validateMenuItem:`. Since `TerminalMTKView` does implement the selector (via
`@objc func validateMenuItem`), the method WILL be called at runtime. The
missing formal conformance is a Swift static-typing omission only; it does not
affect runtime behavior.

## Concurrency — actor isolation chain

1. AppKit calls `paste(_:)` on the main thread.
2. `TerminalMTKView` is `@MainActor` (from `NSView` inference). Safe.
3. `onPaste?(str)` calls the closure `{ text in session.paste(text) }` from
   ContentView. The closure captures `session` which is `@MainActor`.
   The call is from `@MainActor` to `@MainActor`. No crossing. Safe.
4. `session.paste(_:)` calls `screenModel.latestSnapshot()` which is
   `nonisolated` and lock-protected (Mutex). Safe from any context.
5. `sendInput(_:)` is a plain synchronous method on `@MainActor` class. Safe.

No data races, no isolation boundary crossings.
