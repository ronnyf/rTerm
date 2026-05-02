# T9 Spec Review — Empirical Findings

**Commit reviewed:** `52637ff`
**Date:** 2026-05-01
**Reviewer:** Code Review Agent (Claude Sonnet 4.6)

---

## Overall Verdict: SPEC COMPLIANT (with one justified deviation noted)

The implementation satisfies every behavioral requirement in the plan (lines 3250-3717). One deliberate deviation from the plan's Goal-section wording was resolved correctly in the Step 3 code block; both the deviation and its resolution are documented below.

---

## Checklist: GlyphAtlas (`rTerm/GlyphAtlas.swift`)

| Requirement | Status | Evidence |
|---|---|---|
| Variant enum has all 4 cases: regular, bold, italic, boldItalic | PASS | Lines 40-45 |
| Italic font selection uses `NSFontDescriptor.SymbolicTraits.italic` | PASS | Line 111 |
| Fallback to baseFont with logged warning when descriptor lookup fails | PASS | Lines 114-118 |
| `nonisolated` on Variant enum | PASS | Line 40 |

The font-selection switch matches the plan's Step 1 code block exactly. The two-switch pattern (weight selection then italic descriptor application) is correctly implemented. The `nonisolated` qualifier on the nested enum is the amend described by the implementer and is appropriate: `Variant` is a pure value type with no actor-dependent state.

---

## Checklist: RenderCoordinator (`rTerm/RenderCoordinator.swift`)

| Requirement | Status | Evidence |
|---|---|---|
| 4 atlas properties declared (regular, bold, italic, boldItalic) | PASS | Lines 42-45 |
| All 4 atlases built eagerly at init | PASS | Lines 78-81 |
| Per-cell loop uses `AttributeProjection.atlasVariant(for:)` | PASS | Line 164 |
| Colors run through `AttributeProjection.project(fg:bg:attributes:)` | PASS | Lines 182-186 |
| 4-way vertex dispatch (regular/bold/italic/boldItalic buffers) | PASS | Lines 193-202 |
| 4 draw passes with matching atlas textures | PASS | Lines 241-307 |
| Strikethrough overlay pass parallel to underline pass | PASS | Lines 329-345 |
| Strikethrough at cell mid-height, thickness 8% | PASS | Lines 218-228 |
| `lastSeenBellCount`, `lastBeepAt`, `bellMinInterval = 0.2` declared | PASS | Lines 52, 58-59 |
| Bell observer after snapshot read | PASS | Lines 127-136 |
| `lastSeenBellCount` always advanced (no backlog) | PASS | Line 130 |
| Rate limit: `NSSound.beep()` only when >= 200 ms elapsed | PASS | Lines 131-135 |
| `import AppKit` added explicitly | PASS | Line 21 |

One structural note on the bell observer placement: the plan spec (line 3650) says to add the bell block "after the snapshot read." The implementation places it at lines 127-136, which is after `let snapshot = screenModel.latestSnapshot()` at line 122 and before the vertex-building loop. This matches the plan's intent exactly.

---

## Checklist: AttributeProjection (`rTerm/AttributeProjection.swift`)

| Requirement | Status | Evidence |
|---|---|---|
| 2 helpers: `project(fg:bg:attributes:)` and `atlasVariant(for:)` | PASS | Lines 31, 46 |
| `project()` applies dim (RGB×0.5, alpha untouched) THEN reverse (swap) | PASS | Lines 34-42 |
| `atlasVariant()` covers all 4 bold/italic combinations | PASS | Lines 47-54 |
| `nonisolated` on enum | PASS | Line 18 |

### Plan Deviation: dim semantics — "alpha" vs "RGB"

The plan's Goal section (line 3258) states: "multiply fg **alpha** by 0.5 at projection time."

The Step 3 code block (lines 3373-3391) immediately contradicts this with: "Dim modifies the RGB channels (a darker color), not alpha" and implements `.x *= 0.5 / .y *= 0.5 / .z *= 0.5` (RGB channels only, alpha untouched).

The implementation follows the Step 3 code block and does RGB multiplication. This is the correct behavior:
- xterm `charproc.c` implements SGR 2 (faint/dim) as a darker color, not a translucent one.
- Alpha multiplication would cause the glyph to blend into whatever is behind it, which is visually incorrect and inconsistent with every reference terminal.
- The test at line 38-41 of `AttributeProjectionTests.swift` explicitly asserts `fg.w == 1` (alpha unchanged), locking in the correct behavior.

This is not a bug — it is a plan document error in the Goal summary that the Step 3 prose and code correct. The implementation is right.

---

## Checklist: AttributeProjectionTests (`rTermTests/AttributeProjectionTests.swift`)

| Requirement | Status | Evidence |
|---|---|---|
| 5 tests present | PASS | Lines 22, 29, 35, 44, 53 |
| `test_empty_passthrough`: fg==red, bg==blue with empty attributes | PASS | Lines 22-26 |
| `test_reverse_swap`: fg==blue, bg==red after `.reverse` | PASS | Lines 29-32 |
| `test_dim_rgb`: RGB halved, alpha==1, bg unchanged | PASS | Lines 35-42 |
| `test_dim_then_reverse`: dim-then-reverse composition | PASS | Lines 44-51 |
| `test_atlas_variant`: all 4 variant cases + non-atlas attribute ignored | PASS | Lines 53-61 |
| Uses Swift Testing framework (`@Test`, `#expect`) | PASS | Lines 10-11 |
| `@testable import rTerm` and `@testable import TermCore` | PASS | Lines 11-12 |

All 5 test functions match the plan's Step 4 code block exactly, including the comment text and assertion values in `test_dim_then_reverse`.

---

## File Scope Verification

The commit touches exactly 5 files:
1. `rTerm.xcodeproj/project.pbxproj` — adds PBXBuildFile + PBXFileReference entries for `AttributeProjection.swift` and `AttributeProjectionTests.swift`; no other target or build setting changes
2. `rTerm/AttributeProjection.swift` — new file
3. `rTerm/GlyphAtlas.swift` — modified
4. `rTerm/RenderCoordinator.swift` — modified
5. `rTermTests/AttributeProjectionTests.swift` — new file

The plan permits modifications only to the 4 source files and creation of the 2 new source files. The xcodeproj change is an implicit requirement (files must be registered to compile); no unplanned files were modified.

---

## Notable Implementation Details (not spec deviations)

**RenderCoordinator strikethrough `reserveCapacity` alignment:** The plan's Step 6 snippet (line 3570) reserves strikethrough capacity using `floatsPerCellVertex` (the glyph vertex size), not `floatsPerOverlayVertex` (the overlay vertex size). The implementation at line 159 correctly uses `floatsPerOverlayVertex` for the strikethrough reservation, which is consistent with how underline reservation is handled and matches actual usage. The plan snippet had a copy-paste error that the implementer silently corrected.

**RenderCoordinator strikethrough `setRenderPipelineState` placement:** The plan's Step 6 strikethrough draw block (line 3615) includes `renderEncoder.setRenderPipelineState(overlayPipelineState)` at the top of the if-block. The implementation at line 331 does the same. However, the underline pass at line 311 also switches to `overlayPipelineState`. Because the strikethrough pass executes after the underline pass, and the underline pass already switches to `overlayPipelineState`, the `setRenderPipelineState` call in the strikethrough block is technically redundant. It is not wrong — setting the same pipeline state twice is a no-op — and the explicit set makes the strikethrough pass self-contained, which is a readability improvement.

---

## Summary

All plan requirements are implemented correctly. The `nonisolated` amend is a valid isolation fix for the rTerm MainActor-defaulting target. The dim RGB-vs-alpha discrepancy between the plan's Goal summary and Step 3 is a plan document inconsistency; the implementation correctly follows Step 3 (RGB multiplication, matching xterm behavior). The strikethrough `reserveCapacity` fix silently corrects a plan copy-paste error.

No issues require remediation.
