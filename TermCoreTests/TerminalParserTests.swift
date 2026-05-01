//
//  TerminalParserTests.swift
//  TermCoreTests
//
//  Created by Ronny Falk on 4/6/26.
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
@testable import TermCore

struct TerminalParserTests {

    // MARK: - ASCII text

    @Test func asciiText() {
        var parser = TerminalParser()
        let events = parser.parse(Data("Hello".utf8))
        #expect(events == [
            .printable("H"),
            .printable("e"),
            .printable("l"),
            .printable("l"),
            .printable("o"),
        ])
    }

    // MARK: - Control characters

    @Test func controlCharacters() {
        var parser = TerminalParser()
        let input = Data([0x0A, 0x0D, 0x08, 0x09, 0x07])
        let events = parser.parse(input)
        #expect(events == [.c0(.lineFeed), .c0(.carriageReturn), .c0(.backspace), .c0(.horizontalTab), .c0(.bell)])
    }

    // MARK: - Mixed text and controls

    @Test func mixedTextAndControls() {
        var parser = TerminalParser()
        let input = Data("AB".utf8) + Data([0x0A]) + Data("C".utf8)
        let events = parser.parse(input)
        #expect(events == [
            .printable("A"),
            .printable("B"),
            .c0(.lineFeed),
            .printable("C"),
        ])
    }

    // MARK: - Unrecognized byte

    @Test func unrecognizedByte() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x01]))
        #expect(events == [.unrecognized(0x01)])
    }

    // MARK: - Multi-byte UTF-8

    @Test func multiByteCombined() {
        var parser = TerminalParser()
        // "é" is U+00E9, encoded as 0xC3 0xA9 in UTF-8
        let events = parser.parse(Data("é".utf8))
        #expect(events == [.printable("é")])
    }

    // MARK: - Split multi-byte UTF-8 across parse calls

    @Test func splitMultiByteUTF8() {
        var parser = TerminalParser()
        // First chunk: only the leading byte of "é" (0xC3)
        let firstEvents = parser.parse(Data([0xC3]))
        #expect(firstEvents == [], "Incomplete sequence should produce no events")

        // Second chunk: the continuation byte (0xA9)
        let secondEvents = parser.parse(Data([0xA9]))
        #expect(secondEvents == [.printable("é")])
    }

    // MARK: - CR+LF sequence

    @Test func crlfSequence() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x0D, 0x0A]))
        #expect(events == [.c0(.carriageReturn), .c0(.lineFeed)])
    }

    // MARK: - Empty input

    @Test func emptyInput() {
        var parser = TerminalParser()
        let events = parser.parse(Data())
        #expect(events == [], "Empty input should produce no events")
    }

    // MARK: - 3-byte UTF-8 (CJK)

    @Test func threeByteUTF8() {
        var parser = TerminalParser()
        // "中" is U+4E2D, encoded as 0xE4 0xB8 0xAD
        let events = parser.parse(Data("中".utf8))
        #expect(events == [.printable("中")])
    }

    // MARK: - 4-byte UTF-8 (emoji)

    @Test func fourByteUTF8() {
        var parser = TerminalParser()
        // "😀" is U+1F600, encoded as 0xF0 0x9F 0x98 0x80
        let events = parser.parse(Data("😀".utf8))
        #expect(events == [.printable("😀")])
    }

    // MARK: - Split 3-byte UTF-8 across chunks

    @Test func splitThreeByteUTF8() {
        var parser = TerminalParser()
        // "中" = 0xE4 0xB8 0xAD — split after the first byte
        let first = parser.parse(Data([0xE4]))
        #expect(first == [], "Incomplete 3-byte sequence produces no events")

        let second = parser.parse(Data([0xB8, 0xAD]))
        #expect(second == [.printable("中")])
    }

    // MARK: - Split 4-byte UTF-8 across chunks

    @Test func splitFourByteUTF8() {
        var parser = TerminalParser()
        // "😀" = 0xF0 0x9F 0x98 0x80 — split after the second byte
        let first = parser.parse(Data([0xF0, 0x9F]))
        #expect(first == [], "Incomplete 4-byte sequence produces no events")

        let second = parser.parse(Data([0x98, 0x80]))
        #expect(second == [.printable("😀")])
    }

    // MARK: - Overlong 2-byte lead bytes rejected

    @Test func overlongLeadBytesRejected() {
        var parser = TerminalParser()
        // 0xC0 and 0xC1 are overlong lead bytes — must be rejected immediately.
        // Input [0xC0, 0xA0] should produce two unrecognized events.
        let events = parser.parse(Data([0xC0, 0xA0]))
        #expect(events == [.unrecognized(0xC0), .unrecognized(0xA0)])
    }

    @Test func verticalTab_is_c0_verticalTab() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x0B])) == [.c0(.verticalTab)])
    }

    @Test func formFeed_is_c0_formFeed() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x0C])) == [.c0(.formFeed)])
    }

    @Test func nul_is_c0_nul() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x00])) == [.c0(.nul)])
    }

    @Test func del_is_c0_delete() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x7F])) == [.c0(.delete)])
    }

    @Test func shiftOut_and_shiftIn() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x0E, 0x0F])) == [.c0(.shiftOut), .c0(.shiftIn)])
    }
}

// MARK: - VT state machine tests

struct TerminalParserStateMachineTests {

    @Test func esc_then_csi_then_final_emits_unknown_csi() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x35, 0x3B, 0x31, 0x30, 0x48]))
        #expect(events == [.csi(.unknown(params: [5, 10], intermediates: [], final: 0x48))])
    }

    @Test func csi_split_across_chunks_is_coherent() {
        var parser = TerminalParser()
        let first = parser.parse(Data([0x1B, 0x5B, 0x35]))
        let second = parser.parse(Data([0x3B, 0x31, 0x30, 0x48]))
        #expect(first.isEmpty)
        #expect(second == [.csi(.unknown(params: [5, 10], intermediates: [], final: 0x48))])
    }

    @Test func can_mid_csi_returns_to_ground() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x33, 0x31, 0x18, 0x41]))
        #expect(events == [.printable("A")])
    }

    @Test func sub_mid_csi_returns_to_ground() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x33, 0x31, 0x1A, 0x42]))
        #expect(events == [.printable("B")])
    }

    @Test func unterminated_csi_then_esc_drops_first_sequence() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x31, 0x32, 0x1B, 0x5B, 0x33, 0x6D]))
        #expect(events == [.csi(.unknown(params: [3], intermediates: [], final: 0x6D))])
    }

    @Test func osc_terminated_by_st_emits_unknown_osc() {
        var parser = TerminalParser()
        // ESC ] 0 ; h i ESC \
        let events = parser.parse(Data([0x1B, 0x5D, 0x30, 0x3B, 0x68, 0x69, 0x1B, 0x5C]))
        #expect(events == [.osc(.unknown(ps: 0, pt: "hi"))])
    }

    @Test func osc_terminated_by_bel_emits_unknown_osc() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x07]))
        #expect(events == [.osc(.unknown(ps: 0, pt: "x"))])
    }

    @Test func osc_payload_cap_truncates() {
        var parser = TerminalParser()
        var bytes: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B]
        bytes.append(contentsOf: [UInt8](repeating: 0x41, count: 5000))
        bytes.append(0x07)
        let events = parser.parse(Data(bytes))
        guard case .osc(.unknown(_, let pt)) = events[0] else {
            Issue.record("expected .osc(.unknown(...))"); return
        }
        #expect(pt.count == 4096, "payload should be truncated to 4096 chars")
    }

    @Test func csi_param_cap_drops_overflowing_params() {
        var parser = TerminalParser()
        var bytes: [UInt8] = [0x1B, 0x5B]
        for i in 0..<20 {
            if i > 0 { bytes.append(0x3B) }
            bytes.append(0x31)
        }
        bytes.append(0x6D)
        let events = parser.parse(Data(bytes))
        guard case .csi(.unknown(let params, _, _)) = events[0] else {
            Issue.record("expected .csi(.unknown(...))"); return
        }
        #expect(params.count <= 16)
    }
}
