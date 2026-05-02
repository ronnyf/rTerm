# T7 Spec Review — Empirical Findings

**Date:** 2026-05-01
**Commit under review:** 94b1cf7e843f212bbc80f628c79461a19dad565a
**Reviewer:** Code Review (Claude Sonnet 4.6)

---

## Q1: Were only the 3 allowed files modified?

**Method:** `git show 94b1cf7 --name-only`

**Findings:** Exactly 3 files changed:
- `rTerm/KeyEncoder.swift`
- `rTerm/TermView.swift`
- `rTermTests/KeyEncoderTests.swift`

No `xcodeproj` or other files touched (no new source files added, so no project file update was needed).

**Conclusion:** PASS — file scope matches the spec constraint.

---

## Q2: Does `CursorKeyMode` match the spec?

**Method:** Read `rTerm/KeyEncoder.swift` lines 27–31.

**Findings:**
```swift
@frozen public enum CursorKeyMode: Sendable, Equatable {
    case normal
    case application
}
```

Spec required exactly: `@frozen public enum CursorKeyMode: Sendable, Equatable { case normal; case application }`

**Conclusion:** PASS — exact match, including `@frozen`, `public`, `Sendable`, `Equatable`.

---

## Q3: Does `encode(_:cursorKeyMode:)` signature match?

**Method:** Read `rTerm/KeyEncoder.swift` line 46.

**Findings:**
```swift
public func encode(_ event: NSEvent, cursorKeyMode: CursorKeyMode = .normal) -> Data?
```

Spec required: `public func encode(_ event: NSEvent, cursorKeyMode: CursorKeyMode = .normal) -> Data?`

**Conclusion:** PASS — exact match.

---

## Q4: Are the special-key keyCodes correct and in the right switch?

**Method:** Read `rTerm/KeyEncoder.swift` lines 48–74.

**Findings:**
- case 36 → `Data([0x0D])` (Return) — matches spec
- case 51 → `Data([0x7F])` (Backspace/DEL) — matches spec
- case 48 → `Data([0x09])` (Tab) — matches spec
- case 126 → `cursorKey(.up, mode:)` — matches spec
- case 125 → `cursorKey(.down, mode:)` — matches spec
- case 124 → `cursorKey(.right, mode:)` — matches spec
- case 123 → `cursorKey(.left, mode:)` — matches spec
- case 115 → `Data([0x1B, 0x5B, 0x48])` (Home ESC[H) — matches spec
- case 119 → `Data([0x1B, 0x5B, 0x46])` (End ESC[F) — matches spec
- case 116 → `Data([0x1B, 0x5B, 0x35, 0x7E])` (PgUp ESC[5~) — matches spec
- case 121 → `Data([0x1B, 0x5B, 0x36, 0x7E])` (PgDn ESC[6~) — matches spec
- case 117 → `Data([0x1B, 0x5B, 0x33, 0x7E])` (Fwd-Delete ESC[3~) — matches spec

**Conclusion:** PASS — all 12 cases present with correct byte values.

---

## Q5: Structural order change — ctrl+letter now runs AFTER the keyCode switch. Is this a behavioral regression?

**Method:** Compared Phase 1 implementation (commit 7477b42) to Phase 2 (commit 94b1cf7). Phase 1 had ctrl+letter FIRST, then keyCode switch. Phase 2 has keyCode switch FIRST, then ctrl+letter.

**Findings:** The spec says (step 4 code block):
```
// 1. Special keys by keyCode (handled before printable-character paths).
// 2. Ctrl + letter (a-z) → control byte (Phase 1 behavior, preserved).
// 3. Printable characters
```

The spec explicitly mandates keyCode first, ctrl+letter second. The Phase 1 ordering was inverted from what the spec now prescribes. The practical consequence: on keyCodes 36/48/51 with `.control` modifier, Phase 1 would have hit the ctrl+letter branch first (returning a control byte) if the `charactersIgnoringModifiers` happened to be in a–z range. Phase 2 exits via the keyCode switch before reaching that branch, which is correct terminal behavior (Return with Ctrl held is still Return, not a control byte).

**Conclusion:** The reordering is a deliberate spec-mandated improvement, not a regression. PASS.

---

## Q6: Is ctrl+letter logic preserved intact?

**Method:** Read `rTerm/KeyEncoder.swift` lines 77–85.

**Findings:** The logic is identical to Phase 1 — same conditions (`modifierFlags.contains(.control)`, single character, a–z range), same computation (`UInt8(scalar.value) &- 0x60`).

**Conclusion:** PASS — ctrl+letter behavior preserved.

---

## Q7: Is printable fallback preserved?

**Method:** Read `rTerm/KeyEncoder.swift` lines 88–90.

**Findings:**
```swift
if let characters = event.characters, !characters.isEmpty {
    return Data(characters.utf8)
}
```
Identical to Phase 1.

**Conclusion:** PASS.

---

## Q8: Does `cursorKey(_:mode:)` helper match spec byte values?

**Method:** Read `rTerm/KeyEncoder.swift` lines 95–108.

**Findings:**
- `CursorKey` private enum with `.up`, `.down`, `.right`, `.left` — matches spec
- Final bytes: up=0x41(A), down=0x42(B), right=0x43(C), left=0x44(D) — matches spec
- intro byte: application → 0x4F (O), normal → 0x5B ([) — matches spec
- Returns `Data([0x1B, intro, final])` — matches spec

**Conclusion:** PASS — exact match.

---

## Q9: Does `TerminalMTKView` have `cursorKeyModeProvider`?

**Method:** Read `rTerm/TermView.swift` lines 39–42.

**Findings:**
```swift
var cursorKeyModeProvider: (() -> CursorKeyMode)?
```
Spec required: `var cursorKeyModeProvider: (() -> CursorKeyMode)?`

**Conclusion:** PASS.

---

## Q10: Does `keyDown(with:)` read mode from closure with `?? .normal` fallback?

**Method:** Read `rTerm/TermView.swift` lines 51–61.

**Findings:**
```swift
override func keyDown(with event: NSEvent) {
    let mode = cursorKeyModeProvider?() ?? .normal
    let encoder = KeyEncoder()
    if let data = encoder.encode(event, cursorKeyMode: mode) {
```
Spec required the same pattern.

**Conclusion:** PASS — exact match, including `?? .normal` fallback.

---

## Q11: Does `makeNSView` wire `cursorKeyModeProvider` correctly?

**Method:** Read `rTerm/TermView.swift` lines 85–91.

**Findings:**
```swift
let model = screenModel
view.cursorKeyModeProvider = {
    model.latestSnapshot().cursorKeyApplication ? .application : .normal
}
```
Spec required a `let model = screenModel` binding outside the closure, capturing `model` not `self` (to avoid a potential retain cycle through `TermView`'s `screenModel` property). Implementation matches.

**Conclusion:** PASS.

---

## Q12: Does `updateNSView` also wire `cursorKeyModeProvider`?

**Method:** Read `rTerm/TermView.swift` lines 94–100.

**Findings:**
```swift
let model = screenModel
nsView.cursorKeyModeProvider = {
    model.latestSnapshot().cursorKeyApplication ? .application : .normal
}
```
Matches spec requirement.

**Conclusion:** PASS.

---

## Q13: Are all 9 test functions present with the correct names?

**Method:** Read `rTermTests/KeyEncoderTests.swift` lines 188–275.

**Findings:**
- `test_arrow_up_normal_mode` — present (line 191)
- `test_arrow_up_application_mode` — present (line 199)
- `test_all_arrows_normal_mode` — present (line 206)
- `test_all_arrows_application_mode` — present (line 221)
- `test_home_key` — present (line 237)
- `test_end_key` — present (line 245)
- `test_page_up` — present (line 253)
- `test_page_down` — present (line 260)
- `test_forward_delete` — present (line 269)

All 9 functions present.

**Conclusion:** PASS.

---

## Q14: Do test `@Test` annotations match the plan strings?

**Method:** Compare `@Test(...)` labels in implementation vs. plan spec.

**Findings:**
- Implementation does NOT include `@MainActor` on individual test functions. Spec plan code showed `@MainActor` on each `@Test` function in the plan's Step 2 listing.
- The struct `KeyEncoderTests` has `@MainActor` at the struct level (line 83), which propagates isolation to all methods. This means individual methods inherit `@MainActor` without needing per-function annotation.
- This is semantically equivalent and cleaner Swift Testing practice — struct-level `@MainActor` propagates to all methods.
- The plan's per-function `@MainActor` annotations were instructions for a free-function approach; the implementation uses a struct, making per-function annotation redundant.

**Conclusion:** PASS — struct-level `@MainActor` is equivalent and preferable to per-function annotation in this context.

---

## Q15: Does `mockKeyDown` match the plan's required signature?

**Method:** Read `rTermTests/KeyEncoderTests.swift` lines 62–78.

**Findings:**
```swift
@MainActor
private func mockKeyDown(
    keyCode: UInt16,
    characters: String = "",
    modifierFlags: NSEvent.ModifierFlags = []
) -> NSEvent {
```
Spec required: `mockKeyDown(keyCode: UInt16, characters: String = "", modifierFlags: NSEvent.ModifierFlags = []) -> NSEvent`

Return type is non-optional with force-unwrap (`!`) in the body, matching the spec. `@MainActor` annotation present. All parameter labels and defaults match.

**Conclusion:** PASS — exact match.

---

## Q16: Do test byte assertions match the plan's expected values?

**Method:** Cross-referenced each `#expect` value against the plan spec byte sequences.

**Findings:** All byte sequences match:
- normal mode arrows: `[0x1B, 0x5B, suffix]` — PASS
- application mode arrows: `[0x1B, 0x4F, suffix]` — PASS
- Home: `[0x1B, 0x5B, 0x48]` — PASS
- End: `[0x1B, 0x5B, 0x46]` — PASS
- PgUp: `[0x1B, 0x5B, 0x35, 0x7E]` — PASS
- PgDn: `[0x1B, 0x5B, 0x36, 0x7E]` — PASS
- Fwd-Delete: `[0x1B, 0x5B, 0x33, 0x7E]` — PASS

**Conclusion:** PASS.

---

## Summary

All 16 verification questions pass. No deviations from the spec were found. The one structural difference (evaluation order of keyCode switch vs. ctrl+letter) is explicitly mandated by the spec and is a correctness improvement over Phase 1. The `@MainActor` placement at struct scope rather than per-function is semantically equivalent and consistent with the existing test file's structure.
