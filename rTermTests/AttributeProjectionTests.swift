//
//  AttributeProjectionTests.swift
//  rTermTests
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import simd
import Testing
@testable import rTerm
@testable import TermCore

@Suite("AttributeProjection")
struct AttributeProjectionTests {

    private let red:   SIMD4<Float> = SIMD4(1, 0, 0, 1)
    private let blue:  SIMD4<Float> = SIMD4(0, 0, 1, 1)
    private let green: SIMD4<Float> = SIMD4(0, 1, 0, 1)

    @Test("Empty attributes returns inputs unchanged")
    func test_empty_passthrough() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [])
        #expect(fg == red)
        #expect(bg == blue)
    }

    @Test("Reverse swaps fg and bg")
    func test_reverse_swap() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [.reverse])
        #expect(fg == blue)
        #expect(bg == red)
    }

    @Test("Dim multiplies fg RGB by 0.5 (alpha unchanged)")
    func test_dim_rgb() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [.dim])
        #expect(fg.x == 0.5 && fg.y == 0 && fg.z == 0,
                "Dim halves RGB channels — dim red → dark red")
        #expect(fg.w == 1, "Alpha unchanged")
        #expect(bg == blue)
    }

    @Test("Dim + reverse: dim fg first (RGB darken), then reverse (swap with bg)")
    func test_dim_then_reverse() {
        let (fg, bg) = AttributeProjection.project(fg: red, bg: blue, attributes: [.reverse, .dim])
        // After dim: fg = (0.5, 0, 0, 1), bg = (0, 0, 1, 1).
        // After reverse: fg = (0, 0, 1, 1), bg = (0.5, 0, 0, 1).
        #expect(fg == SIMD4<Float>(0, 0, 1, 1), "Reverse moves the original bg into the fg slot")
        #expect(bg == SIMD4<Float>(0.5, 0, 0, 1), "Dim darkens the original fg, which then swaps to bg")
    }

    @Test("Atlas variant: 4-way bold/italic mapping")
    func test_atlas_variant() {
        #expect(AttributeProjection.atlasVariant(for: []) == .regular)
        #expect(AttributeProjection.atlasVariant(for: [.bold]) == .bold)
        #expect(AttributeProjection.atlasVariant(for: [.italic]) == .italic)
        #expect(AttributeProjection.atlasVariant(for: [.bold, .italic]) == .boldItalic)
        #expect(AttributeProjection.atlasVariant(for: [.bold, .underline]) == .bold,
                "Non-atlas attributes don't affect variant selection")
        #expect(AttributeProjection.atlasVariant(for: [.dim, .bold]) == .bold,
                "Dim does not affect atlas variant — only bold/italic matter")
    }
}
