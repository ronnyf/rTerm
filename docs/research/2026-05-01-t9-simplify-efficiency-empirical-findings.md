# T9 Efficiency Review — Empirical Findings
Date: 2026-05-01
Commit: 9d168de
Reviewer: Claude Sonnet 4.6 (Senior Swift Code Reviewer)

## Scope

Per-frame draw hot path in `RenderCoordinator.draw(in:)`.
Target: 60 fps × 80 × 24 = 115,200 cell operations per second.
Files reviewed: `rTerm/RenderCoordinator.swift`, `rTerm/AttributeProjection.swift`,
`rTerm/GlyphAtlas.swift`, `rTermTests/AttributeProjectionTests.swift`.

---

## Finding 1: Double `switch variant` per cell — necessary, not redundant

`RenderCoordinator.swift` lines 166–171 and 193–202 each switch on the same
`GlyphAtlas.Variant` value. This looks like duplication, but is structurally
required: the first switch resolves `atlas` to call `atlas.uvRect(for:)` at
line 172, which must happen before vertex geometry is known. The second switch
dispatches the completed vertex data into the correct array. The two switches
cannot be collapsed without buffering `uv` separately, which would add an
intermediate allocation. No change recommended.

**Overhead at 60 fps:** An enum switch on a 4-case value is a single
integer compare/jump table with no heap activity. At 115k calls/s this is
immeasurable compared to `appendCellQuad` (12 Float appends to a growing
`[Float]`) or the Metal GPU work.

---

## Finding 2: `@inline(__always)` on `appendCellQuad` / `appendVertex` —
already present, no action needed

`appendCellQuad` (line 462) and `appendVertex` (line 477), `appendOverlayQuad`
(line 489), and `appendOverlayVertex` (line 501) all carry `@inline(__always)`.
These were present before this commit. T9 did not add or remove any `@inline`
annotations. The existing annotations are appropriate: each helper is tiny (2–12
scalar appends), called from a tight inner loop, and only from a single call site
per helper. No further annotation is needed or recommended.

---

## Finding 3: `AttributeProjection.atlasVariant` and `project` — `@inlinable`
question

Both helpers are `nonisolated static func` on a `nonisolated enum` in the same
module as their caller. Because `AttributeProjection` and `RenderCoordinator` are
in the same module (`rTerm`), the Swift optimizer can already inline these without
`@inlinable`. `@inlinable` only matters across module boundaries (it exposes the
body in the `.swiftmodule` for inlining by importers). No measurement evidence
exists to justify adding it; the existing spec review and quality review both
confirm the decision not to add it. No change recommended.

---

## Finding 4: `reserveCapacity` gap — `underlineVerts` missing pre-allocation

`RenderCoordinator.swift` lines 155–159 call `reserveCapacity` for
`regularVerts`, `boldVerts`, `italicVerts`, `boldItalicVerts`, and
`strikethroughVerts`. `underlineVerts` (line 153) has no corresponding
`reserveCapacity` call.

All six arrays are bounded by the same worst-case: `rows * cols * verticesPerCell
* floatsPerOverlayVertex` for overlay arrays. For an 80×24 terminal:
- 1,920 × 6 × 8 = 92,160 Floats = 360 KB.

In the common case (any underlined text present), `underlineVerts` will
reallocate at least once per frame when the first underlined cell is appended.
Reallocation in a 60 fps loop is avoidable.

This was noted in the T9 quality review doc
(`2026-05-01-t9-quality-review-empirical-findings.md`, section
"reserveCapacity gap for underlineVerts") and is the only actionable
efficiency finding in this commit.

**Fix:** Add after line 159:
```swift
underlineVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerOverlayVertex)
```
Severity: minor performance inconsistency (not a correctness bug). Can be
deferred to a cleanup commit alongside T10.

---

## Finding 5: 4 vertex arrays + 2 overlay arrays per frame — `ContiguousArray`
vs `[Float]`

The six `[Float]` locals (`Array<Float>` backed by `ContiguousArray`) are
reallocated from scratch every frame. `reserveCapacity` pre-allocates the
backing store, so subsequent frames after the first draw reuse the OS pages
(the allocator typically does not release them between frames at this size).
This is the standard Metal CPU-side approach and matches prior Phase 1 behavior
for the two vertex arrays already present. No change recommended.

---

## Finding 6: `device.makeBuffer` per non-empty draw batch — `.storageModeShared`

Each of the up to 6 draw batches calls `device.makeBuffer(bytes:length:options:)`
with `.storageModeShared`. On Apple Silicon this is a zero-copy blit path: Metal
maps the CPU buffer pointer directly without copying it to GPU memory. At 1,920
cells, the largest batch is ~360 KB. `makeBuffer` at this size is fast but is
still a Metal heap allocation per frame. Reusing persistent `MTLBuffer`s with
manual offset management would eliminate the per-frame heap cost, but that is
a larger refactor (triple-buffering or ring allocation). At 60 fps × 1,920 cells
this overhead is not the bottleneck — GPU tile work is. No change recommended
for this commit.

---

## Finding 7: Bell observer — `ProcessInfo.processInfo.systemUptime` on the
render thread

`systemUptime` at line 131 is called on `@MainActor` in the render loop.
`ProcessInfo.processInfo` is documented as thread-safe. `systemUptime` is a
simple `mach_continuous_time()` wrapping call — nanosecond-range overhead.
This is called at most once per frame only when `bellCount` increments (rare).
Not a hot-path concern.

---

## Finding 8: 4 GPU draw calls instead of 2 — dispatch overhead analysis

Phase 1 issued 2 glyph draw calls + 1 underline overlay = 3 per frame.
T9 issues up to 4 glyph + 2 overlay = 6, but empty batches are skipped.
In a typical terminal session (mostly regular text):
- 1 regular draw call (most cells)
- 0–1 bold draw call
- 0 italic / boldItalic draw calls
- 0–1 underline / strikethrough overlay calls

So the common case remains 1–3 draw calls, same as Phase 1. Worst case (text
with all four variants on screen simultaneously) is 6 calls. On Apple Silicon
the per-draw-call overhead is approximately 15–25 µs. At 6 calls per frame that
is ~120 µs worst-case GPU dispatch overhead per 16.7 ms frame budget — under 1%.
Not material.

---

## Finding 9: Italic font fallback at init — `~5 ms per atlas` claim

The commit message claims "~20 ms total" for 4 atlases. Each `GlyphAtlas.init`
performs:
- 1 `NSFont.monospacedSystemFont` call
- 1 `NSFontDescriptor.withSymbolicTraits` + `NSFont(descriptor:size:)` for italic variants
- 95 CoreText glyph draw calls (0x20–0x7E)
- 1 `CGContext` allocation + 1 `MTLTexture` creation and `replace(region:)`

The 5 ms estimate is reasonable for a 2x-scaled Retina atlas. This is one-time
at app startup (coordinator is not recreated during a session). No concern.

---

## Summary

| Finding | Type | Severity | Action |
|---------|------|----------|--------|
| Double switch on variant | Structural | None (necessary) | No change |
| `@inline(__always)` already present | Annotation | None | No change |
| `@inlinable` on AttributeProjection | Annotation | None (no evidence) | No change |
| `underlineVerts` missing `reserveCapacity` | Performance gap | Minor | Fix in cleanup |
| Per-frame `[Float]` array allocation | Memory | Acceptable | No change |
| `device.makeBuffer` per batch | Metal | Acceptable at scale | Defer |
| `systemUptime` in bell observer | Timing | None | No change |
| 6 GPU draw calls worst-case | GPU dispatch | ~0.7% frame budget | No change |
| 4× atlas init at startup | Startup latency | Acceptable (one-time) | No change |

**One actionable finding:** `underlineVerts` should receive a `reserveCapacity`
call matching the pattern established for the other five arrays. All other
efficiency characteristics of this commit are sound.
