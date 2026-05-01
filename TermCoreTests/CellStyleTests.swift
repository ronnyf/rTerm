//
//  CellStyleTests.swift
//  TermCoreTests
//
//  Created by Ronny Falk on 4/30/26.
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

import Foundation
import Testing
@testable import TermCore

struct CellStyleTests {

    @Test func defaults_are_neutral() {
        let s = CellStyle.default
        #expect(s.foreground == .default)
        #expect(s.background == .default)
        #expect(s.attributes == [])
    }

    @Test func option_set_composition() {
        let a: CellAttributes = [.bold, .underline]
        #expect(a.contains(.bold))
        #expect(a.contains(.underline))
        #expect(!a.contains(.italic))
    }

    @Test func codable_roundtrip_default_omits_style() throws {
        let c = Cell(character: "A")
        let data = try JSONEncoder().encode(c)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj != nil)
        #expect(obj?["style"] == nil, "default style should be omitted from encoded JSON")

        let decoded = try JSONDecoder().decode(Cell.self, from: data)
        #expect(decoded == c)
    }

    @Test func codable_roundtrip_with_style() throws {
        let c = Cell(character: "A",
                     style: CellStyle(foreground: .rgb(255, 128, 0),
                                      background: .ansi16(4),
                                      attributes: [.bold, .underline]))
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(Cell.self, from: data)
        #expect(decoded == c)
    }

    @Test func codable_decodes_legacy_cell_without_style() throws {
        let legacy = #"{"character":"Z"}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Cell.self, from: legacy)
        #expect(decoded.character == "Z")
        #expect(decoded.style == .default)
    }

    @Test func terminal_color_codable_roundtrip() throws {
        let colors: [TerminalColor] = [.default, .ansi16(7), .palette256(196), .rgb(10, 20, 30)]
        for c in colors {
            let data = try JSONEncoder().encode(c)
            let decoded = try JSONDecoder().decode(TerminalColor.self, from: data)
            #expect(decoded == c)
        }
    }
}
