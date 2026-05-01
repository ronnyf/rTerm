//
//  ColorProjectionTests.swift
//  rTermTests
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

import Testing
@testable import rTerm
import TermCore

@Suite @MainActor struct ColorProjectionTests {

    private static let palette = TerminalPalette.xtermDefault
    private static let p256 = ColorProjection.derivePalette256(from: palette)

    @Test func truecolor_roundtrips_as_identity() {
        let out = ColorProjection.resolve(
            .rgb(10, 20, 30), role: .foreground,
            depth: .truecolor, palette: Self.palette, derivedPalette256: Self.p256
        )
        #expect(out == RGBA(10, 20, 30))
    }

    @Test func ansi_index_looks_up_palette_slot() {
        let out = ColorProjection.resolve(
            .ansi16(1), role: .foreground,
            depth: .truecolor, palette: Self.palette, derivedPalette256: Self.p256
        )
        #expect(out == Self.palette.ansi[1])
    }

    @Test func default_foreground_resolves_to_palette_default() {
        let out = ColorProjection.resolve(
            .default, role: .foreground,
            depth: .truecolor, palette: Self.palette, derivedPalette256: Self.p256
        )
        #expect(out == Self.palette.defaultForeground)
    }

    @Test func default_background_resolves_to_palette_default() {
        let out = ColorProjection.resolve(
            .default, role: .background,
            depth: .truecolor, palette: Self.palette, derivedPalette256: Self.p256
        )
        #expect(out == Self.palette.defaultBackground)
    }

    @Test func truecolor_quantizes_to_nearest_ansi() {
        let out = ColorProjection.resolve(
            .rgb(255, 0, 0), role: .foreground,
            depth: .ansi16, palette: Self.palette, derivedPalette256: Self.p256
        )
        #expect(out == Self.palette.ansi[9], "255,0,0 → bright red slot")
    }

    @Test func palette256_grayscale_ramp_derived_correctly() {
        #expect(Self.p256[232] == RGBA(8, 8, 8))
        #expect(Self.p256[255] == RGBA(238, 238, 238))
    }

    @Test func palette256_first_16_slots_match_ansi() {
        for i in 0..<16 {
            #expect(Self.p256[i] == Self.palette.ansi[i])
        }
    }

    @Test func palette256_cube_corner_is_white() {
        // Slot 231 = 16 + 5*36 + 5*6 + 5 — last cube cell at (5,5,5).
        #expect(Self.p256[231] == RGBA(255, 255, 255))
    }

    @Test func palette_codable_roundtrip() throws {
        let data = try JSONEncoder().encode(Self.palette)
        let decoded = try JSONDecoder().decode(TerminalPalette.self, from: data)
        for i in 0..<16 { #expect(decoded.ansi[i] == Self.palette.ansi[i]) }
        #expect(decoded.defaultForeground == Self.palette.defaultForeground)
        #expect(decoded.defaultBackground == Self.palette.defaultBackground)
        #expect(decoded.cursor == Self.palette.cursor)
    }

    @Test func palette_codable_rejects_wrong_count() {
        let bad = #"{"ansi":[],"defaultForeground":[0,0,0,255],"defaultBackground":[0,0,0,255],"cursor":[0,0,0,255]}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(TerminalPalette.self, from: bad.data(using: .utf8)!)
        }
    }
}
