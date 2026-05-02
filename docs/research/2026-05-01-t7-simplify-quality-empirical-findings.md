# T7 Simplify / Quality Review — Empirical Findings

**Commit:** c37093e  
**Date:** 2026-05-01  
**Scope:** Three targeted questions from the reviewer; no generic review dispatched (scope is too narrow).

---

## Files Reviewed

- `/Users/ronny/rdev/rTerm/rTerm/KeyEncoder.swift`
- `/Users/ronny/rdev/rTerm/rTerm/TermView.swift`
- `/Users/ronny/rdev/rTerm/rTermTests/KeyEncoderTests.swift`

---

## Question 1 — KeyCode magic numbers: `private enum KeyCode` block or fine inline?

**Verdict: Fine inline. No action needed.**

The nine key codes (123–126, 115, 119, 116, 121, 117) appear exactly once each, directly annotated on the same line with a comment that names the key and the byte sequence it produces. The switch-case statement already reads as a self-documenting table. A `private enum KeyCode` block would add ~15 lines of declaration with no new information — the comment on each case already names the key, and the numeric values must still appear somewhere (either as the raw value or as an NSEvent constant). The only scenario where a constant block earns its cost is when the same key code appears more than once in non-trivial logic; that is not the case here.

The existing inline pattern also matches the Phase 1 encoding in the same file (cases 36, 51, 48 also carry only inline comments), so a constants block would create a stylistic split within the same switch statement.

---

## Question 2 — Redundant tests `test_arrow_up_normal_mode` + `test_arrow_up_application_mode`

**Verdict: Keep, but add intent comments.**

These two tests are not purely subsumed by `test_all_arrows_normal_mode` and `test_all_arrows_application_mode`.

Arguments for keeping:
- `test_arrow_up_normal_mode` and `test_arrow_up_application_mode` are the *mode-contrast pair* — they test the same keyCode 126 under both modes back-to-back in adjacent test functions. When DECCKM handling breaks, the failure appears at the simplest possible input, making the failure message immediately actionable without scanning a parameterized table.
- The table tests iterate all four arrow keyCodes but do not express the mode-contrast invariant within a single keyCode as clearly. A reader scanning the file sees the DECCKM switching semantics stated explicitly in the pair tests before encountering the table tests.
- The Swift Testing runner reports each `@Test` by its display name. If the intro byte is wrong for all arrows, the table test fails with "keyCode 126 normal-mode" (a message embedded in the `#expect` comment), but the pair test fails with "Up arrow normal-mode → ESC [ A" — the full VT sequence in the title.

Arguments for removing:
- Two of the four key codes (down, right, left) are not covered by a mode-contrast pair, creating an asymmetry. If the pair tests stay, it would be more consistent to add similar pairs for the other three arrows — but that is scope creep.

**Recommendation:** Keep the two existing tests. Add a one-line comment above them:

```swift
// Explicit mode-contrast pair for up arrow; remaining arrows are covered by
// the table tests below. These stay because they name the VT sequences in
// their titles and fail with minimal context when DECCKM switching breaks.
```

---

## Question 3 — `private enum CursorKey`: inline vs. switch-on-keyCode?

**Verdict: Current design is better. No change recommended.**

The question is whether `CursorKey` enum + `cursorKey(_:mode:)` helper should be replaced with a direct switch-on-keyCode that builds the final byte inline in `encode(_:cursorKeyMode:)`.

The current two-step design has concrete advantages:

1. **Separation of concerns.** The outer switch maps hardware keyCodes to logical directions; `cursorKey(_:mode:)` encodes DECCKM logic. If a future keyboard layout maps a different keyCode to the up arrow, only the outer switch changes. The DECCKM encoding is untouched.

2. **Readability of the DECCKM branch.** The helper makes the encoding formula visible in one place:
   ```swift
   let intro: UInt8 = (mode == .application) ? 0x4F : 0x5B
   return Data([0x1B, intro, final])
   ```
   An inlined version would repeat this formula four times (once per arrow), making a future change to the intro byte require four edits instead of one.

3. **Test surface.** `cursorKey(_:mode:)` is `private`, so tests exercise it only through `encode`. That is the right level — the helper is an implementation detail.

The `CursorKey` enum is four cases, defined inline on one line. Its cost is negligible. The alternative (a switch-on-keyCode that produces `final` directly) would eliminate the enum but require duplicating the `intro` logic or moving it to a nested closure, which is not simpler.

**One minor note:** `CursorKey` is defined after the `encode` function body at line 95, which means a reader scanning the file hits the enum values used at lines 54–57 before seeing their definition. Placing `CursorKey` and `cursorKey(_:mode:)` before `encode` (or at the top of the private section) would aid linear readability. This is a style preference, not a correctness issue.

---

## Concurrency / Isolation Spot-Check (prompted by makeCursorKeyModeProvider)

`ScreenModel.latestSnapshot()` is `nonisolated public` and reads from a `Mutex<SnapshotBox>` (line 681–682 in ScreenModel.swift). `TermView.makeCursorKeyModeProvider()` captures `screenModel` and calls `latestSnapshot()` from a closure that runs on the AppKit responder chain (main thread, inside `keyDown(with:)`). This is safe: `Mutex` contention is bounded and never blocks the actor queue. The commit message's description of this invariant is accurate.

No isolation violations, no `nonisolated(unsafe)`, no Sendable issues introduced.

---

## Summary

| Question | Finding | Action |
|---|---|---|
| KeyCode constants block | Not worth it; inline comments are sufficient | None |
| Redundant arrow-up tests | Keep; add intent comment | Add comment (optional) |
| Inline `CursorKey` | Current design is better | None; minor reorder suggestion |

**Overall: Clean. Ready to merge as-is.**
