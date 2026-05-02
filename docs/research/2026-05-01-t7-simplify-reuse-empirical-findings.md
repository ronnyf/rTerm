# T7 Simplify – Reuse Empirical Findings

Date: 2026-05-01
Commit: c37093e ("input: arrow keys, Home/End, PgUp/PgDn + DECCKM")
Scope: rTerm/KeyEncoder.swift, rTerm/TermView.swift, rTermTests/KeyEncoderTests.swift

---

## Q1: Do the keyCode literals (126/125/124/123/115/119/116/121/117) duplicate any constant defined elsewhere?

**Method:** `rg -rn "case 126|case 125|case 124|case 123|case 115|case 119|case 116|case 121|case 117|keyCode.*126|..." /Users/ronny/rdev/rTerm -g "*.swift"` excluding KeyEncoder.swift and KeyEncoderTests.swift.

**Findings:** Zero hits. No other Swift source in the project (rTerm app, TermCore, rtermd, or test bundles) defines a keyCode map, a named constant for any of these values, or a separate switch on NSEvent.keyCode.

**Conclusion:** Clean. The nine literal keyCode values are not duplicated anywhere. No extraction or deduplication needed.

---

## Q2: Does `mockKeyDown` reinvent a test helper already in rTermTests or TermUITests?

**Method:** `rg -rn "mockKeyDown|makeKeyDown|fakeKeyDown|keyDownEvent|makeKeyEvent"` across all Swift files outside KeyEncoderTests.swift.

**Findings:** No hits outside KeyEncoderTests.swift. The UI test files (rTermUITests.swift, rTermUITestsLaunchTests.swift, TermUITests.swift) contain no NSEvent factory helpers at all.

**Additional finding:** KeyEncoderTests.swift already has a pre-existing `makeKeyEvent` helper (lines 38-56, present before this commit). `mockKeyDown` is a second, subtly different helper added in this commit. The differences are:

| | `makeKeyEvent` | `mockKeyDown` |
|---|---|---|
| Return type | `NSEvent?` (optional) | `NSEvent` (force-unwrapped) |
| `charactersIgnoringModifiers` param | separate parameter | mirrors `characters` |
| `@MainActor` | no | yes |
| Caller usage | `try #require(makeKeyEvent(...))` | direct assignment |

`mockKeyDown` is not a pure duplicate — it trades the separate `charactersIgnoringModifiers` parameter for a simpler call site suited to navigation keys (which carry no characters). The two helpers serve different test styles and both live in the same file, so there is no cross-file reinvention. Whether to consolidate them into one helper is a quality/simplification question (not a reuse question), and the difference is small enough to leave as-is.

**Conclusion:** No reinvention of an existing helper from another file. The two coexisting helpers in KeyEncoderTests.swift are intentionally different. No action required.

---

## Q3: Does `cursorKey(_:mode:)` duplicate any existing escape-sequence builder?

**Method:** `rg -rn "cursorKey|arrowKey|\[0x1B, 0x4F\]|\[0x1B, 0x5B\]|ESC.*O.*[ABCD]"` across all Swift files excluding KeyEncoder.swift and KeyEncoderTests.swift.

**Findings:** No other file builds ESC-O-X or ESC-[-X arrow sequences. The hits returned are all in TermCore and TermView, and relate to `nApplication` / `nModeProvider` property names (the working-tree rename of `cursorKeyApplication` / `cursorKeyModeProvider`) — not to sequence construction. No TerminalParser, ScreenModel, or any other source constructs cursor-key output sequences.

**Conclusion:** Clean. `cursorKey(_:mode:)` is the sole escape-sequence builder for arrow keys in the project. No duplication.

---

## Summary

All three checks are clean. The keyCode literals are unique to KeyEncoder, `mockKeyDown` is not a cross-file reinvention (it is a local sibling to the pre-existing `makeKeyEvent` with a different API shape), and `cursorKey(_:mode:)` has no counterpart anywhere in the codebase.
