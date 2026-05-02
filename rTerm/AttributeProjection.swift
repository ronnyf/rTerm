//
//  AttributeProjection.swift
//  rTerm
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import simd
import TermCore

/// Pure helpers that map a `Cell`'s SGR attributes onto the effective fg/bg
/// SIMD colors the renderer hands to the shader. Kept renderer-adjacent (not
/// shader code) so tests can validate without a Metal device.
///
/// `nonisolated` so tests in a non-MainActor context can call these freely;
/// the helpers touch no actor state.
nonisolated enum AttributeProjection {

    /// Apply `dim` (fg RGB × 0.5) and `reverse` (fg/bg swap) to a pair of
    /// already-resolved SIMD colors. Order: dim first, then reverse — matches
    /// xterm `charproc.c` / iTerm2 `iTermTextDrawingHelper`, where SGR 2
    /// (faint) darkens the foreground attribute, and SGR 7 (reverse) is the
    /// final swap of resolved fg/bg colors. Reverse-then-dim would dim the
    /// post-swap fg (i.e., the original bg), which doesn't match either
    /// reference implementation.
    ///
    /// Dim modifies the RGB channels (a darker color), not alpha — `dim` in
    /// xterm renders as a darker foreground color, not a translucent glyph
    /// blended onto whatever happens to be in the background slot.
    static func project(fg: SIMD4<Float>, bg: SIMD4<Float>, attributes: CellAttributes) -> (fg: SIMD4<Float>, bg: SIMD4<Float>) {
        var resultFg = fg
        var resultBg = bg
        if attributes.contains(.dim) {
            resultFg.x *= 0.5
            resultFg.y *= 0.5
            resultFg.z *= 0.5
        }
        if attributes.contains(.reverse) {
            swap(&resultFg, &resultBg)
        }
        return (resultFg, resultBg)
    }

    /// Pick which of the four atlases applies for a given attribute set.
    static func atlasVariant(for attributes: CellAttributes) -> GlyphAtlas.Variant {
        let bold = attributes.contains(.bold)
        let italic = attributes.contains(.italic)
        switch (bold, italic) {
        case (true, true):   return .boldItalic
        case (true, false):  return .bold
        case (false, true):  return .italic
        case (false, false): return .regular
        }
    }
}
