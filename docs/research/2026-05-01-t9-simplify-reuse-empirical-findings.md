# T9 Simplify/Reuse — Empirical Findings

Date: 2026-05-01
Commit: 9d168de ("renderer: italic + bold-italic + dim + reverse + strikethrough + bell (Phase 2 T9)")
Reviewer: Claude Sonnet 4.6

---

## Q1: Is there an existing render-pass abstraction that could replace 4 parallel vertex arrays + 4 draw passes?

No. There is no render-pass abstraction type in the codebase. A search for any
`struct`/`class`/`enum` with names containing `Pass`, `DrawPass`, `RenderPass`,
`atlasPass`, or `glyphPass` returned zero results across all Swift files.

The draw-call pattern in `RenderCoordinator.draw(in:)` is inline, repeated four
times for the four atlas variants (regular, bold, italic, boldItalic) at
`RenderCoordinator.swift:241–307`. Each block is structurally identical:

```swift
if !<variant>Verts.isEmpty {
    let buf = device.makeBuffer(bytes: <variant>Verts,
                                length: <variant>Verts.count * MemoryLayout<Float>.size,
                                options: .storageModeShared)
    if let buf {
        renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(<variant>Atlas.texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                     vertexCount: <variant>Verts.count / floatsPerCellVertex)
    }
}
```

A private helper with signature:

```swift
private func drawGlyphBatch(_ verts: [Float], atlas: GlyphAtlas,
                             floatsPerVertex: Int,
                             encoder: MTLRenderCommandEncoder)
```

would collapse the four blocks (approximately 56 lines) to four one-liners and
eliminate the repeated `makeBuffer` / `setVertexBuffer` / `setFragmentTexture` /
`drawPrimitives` sequence. No such helper exists today.

The overlay passes (underline, strikethrough, cursor) use a different pipeline
state (`overlayPipelineState`) and a different vertex stride (`floatsPerOverlayVertex`),
so they form a second group but follow the same structural pattern. A
`drawOverlayBatch` helper (without a texture argument, since the overlay shader
does not sample) could similarly collapse those three blocks.

**Verdict:** The pattern is real and the abstraction is worth introducing. The
duplication across four glyph-atlas passes (and separately across three overlay
passes) is not mitigated by any existing helper.

---

## Q2: Strikethrough overlay — does it share `appendOverlayQuad` with underline, or is each duplicating code?

Both share the same helper. `appendOverlayQuad` is a private method defined once
at `RenderCoordinator.swift:490–499`:

```swift
private func appendOverlayQuad(into out: inout [Float],
                               x0: Float, x1: Float, y0: Float, y1: Float,
                               color: SIMD4<Float>)
```

Call sites in the commit:

| Line | Caller |
|------|--------|
| 213  | underline vertex accumulation |
| 225  | strikethrough vertex accumulation |
| 360  | cursor quad |

The strikethrough addition correctly reused `appendOverlayQuad` rather than
duplicating the 6-vertex emission logic. The only difference between the underline
and strikethrough paths is the `y0`/`y1` geometry calculation (bottom of cell vs.
mid-cell); the helper itself is shared. No duplication here.

---

## Q3: Does `AttributeProjection.atlasVariant` reuse anything from `ColorProjection`? Both are projection-style enums.

They share the **design pattern** (`nonisolated enum` of pure static functions,
`TermCore`-aware, no actor state, callable from tests without a Metal device) but
there is no code reuse between them and none is expected.

`ColorProjection` (`rTerm/ColorProjection.swift`):
- Resolves a `TerminalColor` → concrete `RGBA` given depth/palette
- Has substantial logic: 256-color cube generation, two quantization paths,
  a `derivePalette256` cache builder
- Takes `TerminalColor`, `ColorRole`, `ColorDepth`, `TerminalPalette`,
  `ContiguousArray<RGBA>` as parameters
- Returns `RGBA` (byte-precision color)

`AttributeProjection` (`rTerm/AttributeProjection.swift`):
- Maps `CellAttributes` → `GlyphAtlas.Variant` (atlas selector)
- Maps `(SIMD4<Float>, SIMD4<Float>, CellAttributes)` → `(SIMD4<Float>, SIMD4<Float>)` (dim + reverse)
- Takes already-resolved SIMD floats; operates downstream of `ColorProjection`
- No quantization or palette logic

The two enums are sequential pipeline stages, not overlapping helpers. The
`nonisolated` + pure-static convention is the shared idiom. The docstring of
`AttributeProjection` makes the sequencing explicit: callers should call
`ColorProjection.resolve` first (to get `resolvedFg`/`resolvedBg`), then pass
those results to `AttributeProjection.project`. `RenderCoordinator.draw(in:)`
follows this order at lines 174–183.

No shared base type, protocol, or extracted helper is needed or missing.

---

## Q4: Does the bell observer's `ProcessInfo.processInfo.systemUptime` pattern exist anywhere else in the codebase?

No. `ProcessInfo.processInfo.systemUptime` appears in exactly one place:
`RenderCoordinator.swift`, in the bell rate-limiter added by T9.

A search for `systemUptime`, `ProcessInfo`, `CACurrentMediaTime`, `mach_absolute_time`,
`Date()`, `DispatchTime`, `lastSeen`, `lastBeep`, `lastRender`, `lastDraw`,
`rateLimit`, `minInterval`, `debounce`, and `throttle` across all Swift files found:

- `ProcessInfo.processInfo.systemUptime` — only in `RenderCoordinator.swift` (bell)
- `Session.createdAt` in `rtermd/Session.swift` — set to `ProcessInfo.processInfo.systemUptime`
  at session creation time (a timestamp, not a rate-limiter)
- No other rate-limiting pattern (debounce, throttle, min-interval guard) exists
  anywhere in the codebase

The `Session.createdAt` usage is structurally different: it records a monotonic
timestamp for a one-time event (session birth), not for a rate-limiting comparison.
The bell pattern (`lastBeepAt` compared against `now` with a minimum interval) is
novel in this codebase.

`systemUptime` is the correct choice here: it is monotonically increasing,
unaffected by wall-clock adjustments or sleep/wake cycles, and has sub-millisecond
resolution — appropriate for a 200 ms audio rate-limit guard. No alternative
timestamp source exists in the codebase that would be better.

---

## Summary

| Question | Finding |
|----------|---------|
| Draw-pass abstraction | None exists. 4 glyph-atlas draw blocks + 3 overlay draw blocks are each inlined. A `drawGlyphBatch` / `drawOverlayBatch` helper would reduce ~56 lines of repetition. |
| `appendOverlayQuad` sharing | Shared correctly. Underline, strikethrough, and cursor all call the same helper. No duplication. |
| `AttributeProjection` vs `ColorProjection` reuse | Sequential pipeline stages, not overlapping. `nonisolated` pure-static convention is shared; no code extraction needed. |
| `systemUptime` rate-limit precedent | Unique to the bell observer in T9. `Session.createdAt` also uses `systemUptime` but as a one-time timestamp, not a rate-limit guard. Pattern is new to the codebase. |
