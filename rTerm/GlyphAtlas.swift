//
//  GlyphAtlas.swift
//  rTerm
//
//  Created by Ronny F on 6/19/24.
//
//  This file is part of rTerm.
//
//  Terminal App is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Terminal App is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with Terminal App. If not, see <https://www.gnu.org/licenses/>.
//

import AppKit
import CoreText
import Metal
import OSLog

/// Rasterizes printable ASCII glyphs (0x20...0x7E) into a single-channel Metal
/// texture atlas using Core Text.  The atlas is laid out as a 16-column x 6-row
/// grid of equally-sized character cells.  A 2x scale factor is baked in so
/// glyphs render crisply on Retina displays.
struct GlyphAtlas {

    // MARK: - Constants

    /// Number of tile columns in the atlas grid.
    private static let columns = 16
    /// Number of tile rows in the atlas grid.
    private static let rows = 6
    /// First printable ASCII code point included in the atlas.
    private static let firstGlyph: UInt8 = 0x20
    /// Last printable ASCII code point included in the atlas.
    private static let lastGlyph: UInt8 = 0x7E

    // MARK: - Public properties

    /// The grayscale (.r8Unorm) texture containing all rasterized glyphs.
    let texture: MTLTexture
    /// Width of a single character cell in points (not pixels).
    let cellWidth: CGFloat
    /// Height of a single character cell in points (not pixels).
    let cellHeight: CGFloat

    // MARK: - Private properties

    /// Pixel dimensions of the atlas texture (cellWidth * scale * columns, etc.).
    private let atlasPixelWidth: Int
    private let atlasPixelHeight: Int
    /// The backing scale factor used when rasterizing (2x for Retina).
    private let scaleFactor: CGFloat

    // MARK: - Initializer

    /// Creates a glyph atlas for printable ASCII characters.
    ///
    /// - Parameters:
    ///   - device: The Metal device used to create the texture.
    ///   - fontSize: The font size in points.  Defaults to 14.
    init(device: MTLDevice, fontSize: CGFloat = 14.0) {
        let scale: CGFloat = 2.0

        // -- 1. Font ----------------------------------------------------------
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let ctFont = font as CTFont

        // -- 2. Cell metrics --------------------------------------------------
        let ascent  = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)

        // Measure the advance width of a reference glyph ("M").
        var refUnichars: [UniChar] = Array("M".utf16)
        var refGlyphs: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(ctFont, &refUnichars, &refGlyphs, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, &refGlyphs, &advance, 1)

        let rawCellW = advance.width
        let rawCellH = ascent + descent + leading

        // Round up to whole points so tiles align on pixel boundaries after
        // scaling.
        let cellW = ceil(rawCellW)
        let cellH = ceil(rawCellH)

        self.cellWidth  = cellW
        self.cellHeight = cellH
        self.scaleFactor = scale

        // -- 3. Atlas layout --------------------------------------------------
        let pixelCellW = Int(cellW * scale)
        let pixelCellH = Int(cellH * scale)
        let atlasW = Self.columns * pixelCellW
        let atlasH = Self.rows    * pixelCellH
        self.atlasPixelWidth  = atlasW
        self.atlasPixelHeight = atlasH

        // -- 4. CGContext (8-bit grayscale) ------------------------------------
        let colorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
        guard let ctx = CGContext(
            data: nil,
            width: atlasW,
            height: atlasH,
            bitsPerComponent: 8,
            bytesPerRow: atlasW,  // 1 byte per pixel, tightly packed
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            fatalError("GlyphAtlas: failed to create CGContext")
        }

        // Scale the context so Core Text draws at Retina resolution.
        ctx.scaleBy(x: scale, y: scale)

        // Black background (already zeroed by CGContext, but explicit for
        // clarity).
        ctx.setFillColor(CGColor(gray: 0.0, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0,
                         width: CGFloat(atlasW) / scale,
                         height: CGFloat(atlasH) / scale))

        // White text.
        ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))

        // Draw each glyph.
        for code in Self.firstGlyph...Self.lastGlyph {
            let index = Int(code - Self.firstGlyph)
            let col = index % Self.columns
            let row = index / Self.columns

            // Tile origin in point coordinates.  Core Graphics has its origin
            // at the bottom-left, so row 0 is the bottom of the bitmap.  We
            // flip rows so that ASCII 0x20 ends up at the top-left of the
            // texture (which has its origin at the top-left in Metal UV space).
            let flippedRow = (Self.rows - 1) - row
            let originX = CGFloat(col) * cellW
            let originY = CGFloat(flippedRow) * cellH

            // Baseline position within the tile.
            let baselineY = originY + descent

            var unichars: [UniChar] = [UniChar(code)]
            var glyphs: [CGGlyph] = [0]
            CTFontGetGlyphsForCharacters(ctFont, &unichars, &glyphs, 1)

            var positions = [CGPoint(x: originX, y: baselineY)]
            CTFontDrawGlyphs(ctFont, &glyphs, &positions, 1, ctx)
        }

        // -- 5. MTLTexture from bitmap data -----------------------------------
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasW,
            height: atlasH,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .managed

        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("GlyphAtlas: failed to create MTLTexture")
        }

        // The CGContext stores pixels top-to-bottom when the coordinate system
        // has been flipped via our row calculation.  Metal textures also store
        // data top-to-bottom, so the bitmap data can be copied directly.
        guard let bitmapData = ctx.data else {
            fatalError("GlyphAtlas: CGContext has no backing data")
        }

        tex.replace(
            region: MTLRegionMake2D(0, 0, atlasW, atlasH),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: atlasW
        )

        self.texture = tex
    }

    // MARK: - UV lookup

    /// Returns normalized UV coordinates for the tile containing `character`.
    ///
    /// Characters outside the printable ASCII range (0x20...0x7E) are mapped to
    /// "?" as a fallback.
    ///
    /// - Returns: A tuple of `(u0, v0, u1, v1)` where `(u0, v0)` is the
    ///   top-left corner and `(u1, v1)` is the bottom-right corner, both in
    ///   the `[0, 1]` range.
    func uvRect(for character: Character) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        let code: UInt8
        if let ascii = character.asciiValue,
           ascii >= Self.firstGlyph,
           ascii <= Self.lastGlyph {
            code = ascii
        } else {
            // Fallback to '?'
            code = UInt8(ascii: "?")
        }

        let index = Int(code - Self.firstGlyph)
        let col = index % Self.columns
        let row = index / Self.columns

        let u0 = Float(col)     / Float(Self.columns)
        let v0 = Float(row)     / Float(Self.rows)
        let u1 = Float(col + 1) / Float(Self.columns)
        let v1 = Float(row + 1) / Float(Self.rows)

        return (u0, v0, u1, v1)
    }
}
