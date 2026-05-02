# T3 Spec Review — Empirical Findings

**Date:** 2026-05-01
**Reviewer:** Claude Sonnet 4.6 (code review pass)
**Commit reviewed:** 373364c

---

## 1. TerminalModes.swift — new file

**Question:** Does the new file match the spec exactly (frozen struct, 4 fields, correct defaults, static .default, license header)?

**Method:** Read `/Users/ronny/rdev/rTerm/TermCore/TerminalModes.swift` in full.

**Raw findings:**
- Line 13: `@frozen public struct TerminalModes: Sendable, Equatable, Codable` — matches spec verbatim.
- Lines 14–17: fields `autoWrap: Bool`, `cursorVisible: Bool`, `cursorKeyApplication: Bool`, `bracketedPaste: Bool` — exact match.
- Lines 19–27: `public init(autoWrap: Bool = true, cursorVisible: Bool = true, cursorKeyApplication: Bool = false, bracketedPaste: Bool = false)` — defaults match spec.
- Line 29: `public static let `default` = TerminalModes()` — matches spec.
- Lines 1–7: GPLv3 license header present.

**Conclusion:** TerminalModes.swift is a verbatim match of the plan's Step 1 code block.

---

## 2. ScreenSnapshot.swift — new fields, init, CodingKeys, init(from:)

**Question:** Are the 4 new fields in the correct order after windowTitle, with correct init defaults and decodeIfPresent back-compat?

**Method:** Read `/Users/ronny/rdev/rTerm/TermCore/ScreenSnapshot.swift` in full.

**Raw findings:**
- Lines 62–65: fields in declared order: `cursorKeyApplication: Bool`, `bracketedPaste: Bool`, `bellCount: UInt64`, `autoWrap: Bool` — matches spec Step 2 order exactly.
- Lines 68–92: init parameters include all 4 with correct defaults (cursorKeyApplication: false, bracketedPaste: false, bellCount: 0, autoWrap: true).
- Lines 99–103: CodingKeys includes all 4 new keys plus all pre-existing keys.
- Lines 127–130: all 4 use `decodeIfPresent ?? default` with correct fallback values.
- Line 42: `@frozen public enum BufferKind: String, Sendable, Equatable, Codable` — `String` raw type added (plan deviation; see section 4 below).

**Conclusion:** All 4 fields are present in the correct order with correct defaults. init(from:) back-compat is correct.

---

## 3. ScreenModel.swift — modes/bellCount fields, publishSnapshot, snapshot(), handleC0(.bell), handleSetMode, handlePrintable autoWrap, restore(from:)

**Method:** Read `/Users/ronny/rdev/rTerm/TermCore/ScreenModel.swift` in full.

**Raw findings (line references):**

**Fields:**
- Line 80: `private var modes: TerminalModes = .default`
- Line 84: `private var bellCount: UInt64 = 0`

**Initializer initial snapshot (lines 170–183):** All 4 new fields spelled out with correct defaults.

**publishSnapshot (lines 227–243):** All 4 new fields plumbed from `modes.*` and `bellCount`.

**snapshot() (lines 518–534):** Mirror of publishSnapshot — all 4 fields present.

**handleC0(.bell) (lines 276–280):**
```swift
case .bell:
    bellCount &+= 1
    return true
```
Matches spec Step 4 exactly. The `.nul, .shiftOut, .shiftIn, .delete` arm correctly excludes `.bell`.

**handleSetMode (lines 620–645):** All 4 user-mode cases present with idempotency guards. Alt-screen cases (alternateScreen47, alternateScreen1047, alternateScreen1049, saveCursor1048) return false. `.unknown` returns false. Matches Step 5 verbatim.

**handlePrintable autoWrap (lines 247–271):** Diverges from plan Step 6.

Plan Step 6 specifies:
```swift
buf.cursor.col += 1   // unconditional
```

Implementation has (lines 267–269):
```swift
if autoWrap || buf.cursor.col < cols - 1 {
    buf.cursor.col += 1
}
```

This is the amend described in the implementer's report ("fix-amend gated col += 1 on autoWrap"). The plan's version would cause `buf.cursor.col` to advance past `cols-1` even with DECAWM off, meaning on the next printable, the `buf.cursor.col >= cols` guard would fire again and clamp back to `cols-1`. The amend's guard ensures cursor never exceeds `cols-1` under DECAWM-off. Both produce the same observable test result (row0 == "abcdg", cursor stays on row 0), but the amend is more obviously correct and avoids the redundant clamp cycle.

**restore(from:) (lines 500–508):** Re-seeds `modes` via `TerminalModes(autoWrap:cursorVisible:cursorKeyApplication:bracketedPaste:)` from snapshot fields, and `self.bellCount = snapshot.bellCount`. Matches Step 7.

**Conclusion:** All ScreenModel changes are implemented and correct. The `handlePrintable` deviation from Step 6 is an intentional improvement that produces identical test behavior while being semantically cleaner (cursor never transiently exceeds grid bounds under DECAWM-off).

---

## 4. BufferKind String raw type — plan deviation

**Question:** Was `BufferKind: String` pre-existing or new? Does it break any test pinning the old dict-encoded JSON shape?

**Method:**
- `rg "activeBuffer.*main" TermCoreTests/` — returns 2 results.

**Raw findings:**
- `/Users/ronny/rdev/rTerm/TermCoreTests/CodableTests.swift:238`: `activeBuffer: .main` — Swift enum literal, not JSON string. Not a test pinning wire format.
- `/Users/ronny/rdev/rTerm/TermCoreTests/CodableTests.swift:264`: `"activeBuffer": "main"` — this IS a JSON string in the Phase 1 back-compat test. It uses the `String` raw value `"main"`, which is exactly what `BufferKind: String` produces. The test was written for the post-deviation format.

The Phase 1 commit (`cef6d91`) had `BufferKind` without `String` raw type (it would have used default dict-encoding). However, rtermd sessions are in-memory only — there is no persistent XPC payload from before the binary was replaced. Cross-version wire compat for `BufferKind` encoding is therefore not a concern in practice.

**Conclusion:** No existing test pinned the old dict-encoding shape. The `String` raw type is safe and necessary for the back-compat test's JSON literal to work.

---

## 5. New test counts

**Question:** Are there exactly 9 new ScreenModelTests and 2 new CodableTests?

**Method:** `git show 373364c -- TermCoreTests/ScreenModelTests.swift | grep "^+" | grep "@Test"`

**Raw findings:**

ScreenModelTests new @Test annotations (8, not 9):
1. `@Test("DECAWM disable: writing past last column overwrites the last cell")`
2. `@Test("DECTCEM disable: snapshot.cursorVisible reflects the change")`
3. `@Test("DECCKM enable: snapshot.cursorKeyApplication = true")`
4. `@Test("Bracketed paste enable: snapshot.bracketedPaste = true")`
5. `@Test("Mode toggle to same value does not bump version")`
6. `@Test("BEL increments bellCount and bumps version")`
7. `@Test("Three BELs in one batch increment bellCount by 3")`
8. `@Test("restore(from:) re-seeds cursorKeyApplication, bracketedPaste, bellCount")`

Plan listed 9 new tests. Implemented: 8.

Missing test: The plan Step 8 lists the 8 tests above. Counting the plan's code block (Step 8, lines 1087–1174 of the plan) also yields 8 `@Test` functions. The plan Step 10 says "all 9 new tests pass" — **this is an off-by-one in the plan's summary text**, not a missing implementation test. The spec's code block in Step 8 contains exactly 8 test functions. 8 were implemented. The count discrepancy is in the plan's Step 10 prose ("9 new tests"), not in the implementation.

CodableTests new @Test annotations (2):
1. `@Test("ScreenSnapshot decodes a Phase 1-shaped JSON payload (missing new fields)")`
2. `@Test("ScreenSnapshot Codable round-trip preserves all Phase 2 fields")`

Both match the plan's Step 9 exactly.

**Conclusion:** 8 new ScreenModelTests (plan's Step 8 code block has 8; plan's Step 10 prose incorrectly says 9). 2 new CodableTests. Implementation matches the plan code blocks.

---

## 6. File scope — only allowed files modified

**Method:** `git show 373364c --name-only`

**Raw findings:**
```
TermCore/ScreenModel.swift
TermCore/ScreenSnapshot.swift
TermCore/TerminalModes.swift
TermCoreTests/CodableTests.swift
TermCoreTests/ScreenModelTests.swift
rTerm.xcodeproj/project.pbxproj
```

6 files: the 5 allowed + xcodeproj for new file registration. No other files touched.

**Conclusion:** File scope is clean.

---

## 7. Pre-existing bellIsNoOp test — name accuracy post-T3

**Question:** Does the pre-existing `bellIsNoOp` test (line 167 in ScreenModelTests, `ScreenModelTests` struct) become misleading or incorrect after T3?

**Method:** Read the test body (lines 167–175).

**Raw findings:** The test asserts printable characters around a bell write to the correct cells and the cursor ends at col 2. It does NOT check `bellCount`. The test name says "NoOp" but bell now bumps `bellCount` (which makes it not a no-op for the snapshot). The test still passes because it only checks grid cell values and cursor position, which bell does not change.

**Conclusion:** The test passes but its name is now misleading — bell is not a no-op for the snapshot after T3 (it bumps `bellCount` and version). This is a minor documentation issue, not a functional defect.
