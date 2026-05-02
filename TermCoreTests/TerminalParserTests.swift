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
        #expect(events == [.csi(.cursorPosition(row: 4, col: 9))])
    }

    @Test func csi_split_across_chunks_is_coherent() {
        var parser = TerminalParser()
        let first = parser.parse(Data([0x1B, 0x5B, 0x35]))
        let second = parser.parse(Data([0x3B, 0x31, 0x30, 0x48]))
        #expect(first.isEmpty)
        #expect(second == [.csi(.cursorPosition(row: 4, col: 9))])
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
        // Second sequence uses final 0x6E ('n', DSR) — stays .unknown because
        // it's not in mapCSI's typed set. 0x6D ('m') would parse as SGR.
        let events = parser.parse(Data([0x1B, 0x5B, 0x31, 0x32, 0x1B, 0x5B, 0x33, 0x6E]))
        #expect(events == [.csi(.unknown(params: [3], intermediates: [], final: 0x6E))])
    }

    @Test func osc_terminated_by_st_emits_window_title() {
        var parser = TerminalParser()
        // ESC ] 0 ; h i ESC \
        let events = parser.parse(Data([0x1B, 0x5D, 0x30, 0x3B, 0x68, 0x69, 0x1B, 0x5C]))
        #expect(events == [.osc(.setWindowTitle("hi"))])
    }

    @Test func osc_terminated_by_bel_emits_window_title() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x07]))
        #expect(events == [.osc(.setWindowTitle("x"))])
    }

    @Test func osc_payload_cap_truncates() {
        var parser = TerminalParser()
        var bytes: [UInt8] = [0x1B, 0x5D, 0x30, 0x3B]
        bytes.append(contentsOf: [UInt8](repeating: 0x41, count: 5000))
        bytes.append(0x07)
        let events = parser.parse(Data(bytes))
        guard case .osc(.setWindowTitle(let pt)) = events[0] else {
            Issue.record("expected .osc(.setWindowTitle(...))"); return
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
        // Final 0x6E ('n', DSR) stays .unknown so we can inspect raw params.
        bytes.append(0x6E)
        let events = parser.parse(Data(bytes))
        guard case .csi(.unknown(let params, _, _)) = events[0] else {
            Issue.record("expected .csi(.unknown(...))"); return
        }
        #expect(params.count <= 16)
    }

    @Test func osc_split_across_chunks_via_bel_terminator() {
        var parser = TerminalParser()
        // ESC ] 0 ; h i — first chunk
        let first = parser.parse(Data([0x1B, 0x5D, 0x30, 0x3B, 0x68, 0x69]))
        // BEL — second chunk
        let second = parser.parse(Data([0x07]))
        #expect(first.isEmpty)
        #expect(second == [.osc(.setWindowTitle("hi"))])
    }

    @Test func osc_split_between_esc_and_backslash() {
        var parser = TerminalParser()
        // ESC ] 0 ; x ESC — first chunk ends mid-ST
        let first = parser.parse(Data([0x1B, 0x5D, 0x30, 0x3B, 0x78, 0x1B]))
        // \ — second chunk completes the ST
        let second = parser.parse(Data([0x5C]))
        #expect(first.isEmpty)
        #expect(second == [.osc(.setWindowTitle("x"))])
    }

    @Test func dcs_split_across_chunks_drops_cleanly() {
        var parser = TerminalParser()
        // ESC P q data... — first chunk
        let first = parser.parse(Data([0x1B, 0x50, 0x71, 0x64, 0x61, 0x74]))
        // ESC \ — second chunk terminates DCS, followed by a printable 'A'
        let second = parser.parse(Data([0x1B, 0x5C, 0x41]))
        #expect(first.isEmpty)
        #expect(second == [.printable("A")], "DCS contents dropped; only the trailing 'A' emits")
    }

    @Test func lf_mid_csi_executes_and_csi_completes() {
        var parser = TerminalParser()
        // ESC [ 1 ; 3 LF n — LF should execute and the CSI should continue.
        // Final 0x6E ('n', DSR) stays .unknown; 0x6D ('m') would parse as SGR.
        let events = parser.parse(Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x0A, 0x6E]))
        #expect(events == [
            .c0(.lineFeed),
            .csi(.unknown(params: [1, 3], intermediates: [], final: 0x6E))
        ])
    }

    @Test func bs_mid_csi_executes() {
        var parser = TerminalParser()
        // ESC [ 5 BS A — backspace should execute between the 5 and the A final
        let events = parser.parse(Data([0x1B, 0x5B, 0x35, 0x08, 0x41]))
        #expect(events == [
            .c0(.backspace),
            .csi(.cursorUp(5))
        ])
    }

    @Test func private_marker_after_params_is_dropped() {
        var parser = TerminalParser()
        // ESC [ 2 5 ? h — malformed (? must precede params). Drop sequence silently.
        // Then feed 'B' as a printable sanity check.
        let events = parser.parse(Data([0x1B, 0x5B, 0x32, 0x35, 0x3F, 0x68, 0x42]))
        #expect(events == [.printable("B")])
    }

    @Test func private_marker_before_params_is_preserved() {
        var parser = TerminalParser()
        // ESC [ ? 2 5 h — canonical DECSET 25 (cursor visible). Phase 2 T1 wires
        // this to .csi(.setMode(.cursorVisible, enabled: true)).
        let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x32, 0x35, 0x68]))
        #expect(events == [.csi(.setMode(.cursorVisible, enabled: true))])
    }
}

// MARK: - DEC private modes (Phase 2)

extension TerminalParserStateMachineTests {

    @Test("ESC[?1h emits setMode(cursorKeyApplication, enabled: true)")
    func test_csi_decset_cursorKeyApplication_on() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x31, 0x68]))  // ESC [ ? 1 h
        #expect(events == [.csi(.setMode(.cursorKeyApplication, enabled: true))])
    }

    @Test("ESC[?1l emits setMode(cursorKeyApplication, enabled: false)")
    func test_csi_decreset_cursorKeyApplication_off() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x31, 0x6C]))  // ESC [ ? 1 l
        #expect(events == [.csi(.setMode(.cursorKeyApplication, enabled: false))])
    }

    @Test("All known DEC private modes decode to the correct case")
    func test_csi_decset_known_modes() {
        let cases: [(payload: [UInt8], mode: DECPrivateMode)] = [
            ([0x37],                     .autoWrap),                 // "7"  → DECAWM
            ([0x32, 0x35],               .cursorVisible),            // 25
            ([0x34, 0x37],               .alternateScreen47),        // 47
            ([0x31, 0x30, 0x34, 0x37],   .alternateScreen1047),      // 1047
            ([0x31, 0x30, 0x34, 0x38],   .saveCursor1048),           // 1048
            ([0x31, 0x30, 0x34, 0x39],   .alternateScreen1049),      // 1049
            ([0x32, 0x30, 0x30, 0x34],   .bracketedPaste),           // 2004
        ]
        for (payload, expected) in cases {
            var parser = TerminalParser()
            var bytes: [UInt8] = [0x1B, 0x5B, 0x3F]
            bytes.append(contentsOf: payload)
            bytes.append(0x68)  // 'h'
            let events = parser.parse(Data(bytes))
            #expect(events == [.csi(.setMode(expected, enabled: true))],
                    "Failed for mode \(expected)")
        }
    }

    @Test("Unknown DEC mode preserves the parameter")
    func test_csi_decset_unknown_mode() {
        var parser = TerminalParser()
        // ESC [ ? 9999 h
        let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x39, 0x39, 0x39, 0x39, 0x68]))
        #expect(events == [.csi(.setMode(.unknown(9999), enabled: true))])
    }

    @Test("Multi-param DEC mode emits one .setMode event per param")
    func test_csi_decset_multi_param() {
        var parser = TerminalParser()
        // ESC [ ? 1 ; 7 h — DECSET grammar allows compound mode lists; tmux/vim
        // startup pipelines compound DECSET, so the parser emits one .setMode
        // per param (preserves the singular .setMode(_, enabled:) signature
        // by looping at the dispatch site).
        let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x37, 0x68]))
        #expect(events == [
            .csi(.setMode(.cursorKeyApplication, enabled: true)),
            .csi(.setMode(.autoWrap, enabled: true)),
        ])
    }

    @Test("Multi-param DEC mode reset (l) emits one .setMode event per param")
    func test_csi_decreset_multi_param() {
        var parser = TerminalParser()
        // ESC [ ? 1 ; 7 ; 25 l — three modes, all reset
        let bytes: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x3B, 0x37, 0x3B, 0x32, 0x35, 0x6C]
        let events = parser.parse(Data(bytes))
        #expect(events == [
            .csi(.setMode(.cursorKeyApplication, enabled: false)),
            .csi(.setMode(.autoWrap, enabled: false)),
            .csi(.setMode(.cursorVisible, enabled: false)),
        ])
    }

    @Test("DEC mode set survives byte-boundary chunking (cross-chunk path)")
    func test_csi_decset_cross_chunk() {
        var parser = TerminalParser()
        // ESC [ ? 1 0 4 9 h — fed one byte at a time; identical final result.
        let bytes: [UInt8] = [0x1B, 0x5B, 0x3F, 0x31, 0x30, 0x34, 0x39, 0x68]
        var events: [TerminalEvent] = []
        for byte in bytes {
            events.append(contentsOf: parser.parse(Data([byte])))
        }
        #expect(events == [.csi(.setMode(.alternateScreen1049, enabled: true))])
    }

    @Test("CSI?0h emits .setMode(.unknown(0), enabled: true)")
    func test_csi_decset_zero_param_unknown() {
        var parser = TerminalParser()
        // Param "0" is not a defined DEC private mode — must round-trip via .unknown.
        let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x30, 0x68]))
        #expect(events == [.csi(.setMode(.unknown(0), enabled: true))])
    }

    @Test("CSI?h (no param digits) emits .setMode(.unknown(0), enabled: true)")
    func test_csi_decset_bare_h_no_digit() {
        var parser = TerminalParser()
        // 1B 5B 3F 68 — '?' followed immediately by 'h', no param digits.
        // Empty param list defaults to [0] at the dispatch site, so this lands
        // on the same .unknown(0) event as CSI?0h but via the empty-params path.
        let events = parser.parse(Data([0x1B, 0x5B, 0x3F, 0x68]))
        #expect(events == [.csi(.setMode(.unknown(0), enabled: true))])
    }
}

// MARK: - DECSTBM scroll region (Phase 2)

extension TerminalParserStateMachineTests {

    @Test("ESC[r resets scroll region (both nil)")
    func test_csi_decstbm_reset() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x72]))  // ESC [ r
        #expect(events == [.csi(.setScrollRegion(top: nil, bottom: nil))])
    }

    @Test("ESC[5;20r sets top=5 bottom=20 (parser stays VT 1-indexed; ScreenModel shifts)")
    func test_csi_decstbm_set() {
        var parser = TerminalParser()
        // ESC [ 5 ; 2 0 r
        let events = parser.parse(Data([0x1B, 0x5B, 0x35, 0x3B, 0x32, 0x30, 0x72]))
        #expect(events == [.csi(.setScrollRegion(top: 5, bottom: 20))])
    }

    @Test("ESC[;15r sets only bottom (top nil = use top of screen)")
    func test_csi_decstbm_only_bottom() {
        var parser = TerminalParser()
        // ESC [ ; 1 5 r
        let events = parser.parse(Data([0x1B, 0x5B, 0x3B, 0x31, 0x35, 0x72]))
        #expect(events == [.csi(.setScrollRegion(top: nil, bottom: 15))])
    }

    @Test("DECSTBM with top > bottom passes through unchanged (parser doesn't validate)")
    func test_csi_decstbm_top_gt_bottom_passes_through() {
        var parser = TerminalParser()
        // ESC [ 6 ; 3 r — parser pass-through; ScreenModel rejects in T5.
        let events = parser.parse(Data([0x1B, 0x5B, 0x36, 0x3B, 0x33, 0x72]))
        #expect(events == [.csi(.setScrollRegion(top: 6, bottom: 3))])
    }
}

// MARK: - ESC 7 / ESC 8 (DECSC / DECRC) — Phase 2

extension TerminalParserStateMachineTests {

    @Test("ESC 7 emits .csi(.saveCursor) (DECSC == CSI s)")
    func test_esc_7_decsc() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x37]))  // ESC 7
        #expect(events == [.csi(.saveCursor)])
    }

    @Test("ESC 8 emits .csi(.restoreCursor) (DECRC == CSI u)")
    func test_esc_8_decrc() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x38]))  // ESC 8
        #expect(events == [.csi(.restoreCursor)])
    }
}

// MARK: - CSI cursor motion + erase parser tests

struct CSICursorParseTests {

    @Test func cursor_up_default_1() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x41])) == [.csi(.cursorUp(1))])
    }

    @Test func cursor_up_5() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x35, 0x41])) == [.csi(.cursorUp(5))])
    }

    @Test func cursor_position_normalizes_origin() {
        var parser = TerminalParser()
        // ESC [ 5 ; 10 H  →  (row: 4, col: 9) 0-indexed
        #expect(parser.parse(Data([0x1B, 0x5B, 0x35, 0x3B, 0x31, 0x30, 0x48]))
                == [.csi(.cursorPosition(row: 4, col: 9))])
    }

    @Test func cursor_position_empty_is_origin() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x48]))
                == [.csi(.cursorPosition(row: 0, col: 0))])
    }

    @Test func erase_in_display_to_end() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x4A])) == [.csi(.eraseInDisplay(.toEnd))])
    }

    @Test func erase_in_display_all() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x32, 0x4A])) == [.csi(.eraseInDisplay(.all))])
    }

    @Test func erase_in_line_to_begin() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x31, 0x4B])) == [.csi(.eraseInLine(.toBegin))])
    }

    @Test func save_and_restore_cursor() {
        var parser = TerminalParser()
        let events = parser.parse(Data([0x1B, 0x5B, 0x73, 0x1B, 0x5B, 0x75]))
        #expect(events == [.csi(.saveCursor), .csi(.restoreCursor)])
    }

    @Test func cursor_horizontal_absolute() {
        var parser = TerminalParser()
        // ESC [ 12 G  →  cursorHorizontalAbsolute(12) — parser carries VT 1-indexed value.
        #expect(parser.parse(Data([0x1B, 0x5B, 0x31, 0x32, 0x47]))
                == [.csi(.cursorHorizontalAbsolute(12))])
    }

    @Test func cursor_up_zero_param_is_default_one() {
        var parser = TerminalParser()
        // ESC [ 0 A — VT spec: 0 is equivalent to "no parameter" → default of 1.
        #expect(parser.parse(Data([0x1B, 0x5B, 0x30, 0x41])) == [.csi(.cursorUp(1))])
    }

    @Test func cursor_position_zero_col_is_default_one() {
        var parser = TerminalParser()
        // ESC [ 5 ; 0 H — second param is 0, should be treated as 1 → col 0 after pre-shift.
        // Expected: cursorPosition(row: 4, col: 0).
        #expect(parser.parse(Data([0x1B, 0x5B, 0x35, 0x3B, 0x30, 0x48]))
                == [.csi(.cursorPosition(row: 4, col: 0))])
    }
}

// MARK: - SGR

struct SGRParseTests {

    @Test func empty_sgr_is_reset() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x6D])) == [.csi(.sgr([.reset]))])
    }

    @Test func sgr_bold() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x31, 0x6D])) == [.csi(.sgr([.bold]))])
    }

    @Test func sgr_foreground_red() {
        var parser = TerminalParser()
        // ESC [ 31 m
        #expect(parser.parse(Data([0x1B, 0x5B, 0x33, 0x31, 0x6D]))
                == [.csi(.sgr([.foreground(.ansi16(1))]))])
    }

    @Test func sgr_bold_red_combined() {
        var parser = TerminalParser()
        // ESC [ 1 ; 31 m
        #expect(parser.parse(Data([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x31, 0x6D]))
                == [.csi(.sgr([.bold, .foreground(.ansi16(1))]))])
    }

    @Test func sgr_bright_foreground() {
        var parser = TerminalParser()
        // ESC [ 91 m  → fg .ansi16(9)
        #expect(parser.parse(Data([0x1B, 0x5B, 0x39, 0x31, 0x6D]))
                == [.csi(.sgr([.foreground(.ansi16(9))]))])
    }

    @Test func sgr_palette256_foreground() {
        var parser = TerminalParser()
        // ESC [ 38 ; 5 ; 196 m
        #expect(parser.parse(Data([0x1B, 0x5B, 0x33, 0x38, 0x3B, 0x35, 0x3B, 0x31, 0x39, 0x36, 0x6D]))
                == [.csi(.sgr([.foreground(.palette256(196))]))])
    }

    @Test func sgr_truecolor_background() {
        var parser = TerminalParser()
        // ESC [ 48 ; 2 ; 255 ; 128 ; 0 m
        let bytes: [UInt8] = [0x1B, 0x5B, 0x34, 0x38, 0x3B, 0x32, 0x3B,
                              0x32, 0x35, 0x35, 0x3B, 0x31, 0x32, 0x38, 0x3B, 0x30, 0x6D]
        #expect(parser.parse(Data(bytes))
                == [.csi(.sgr([.background(.rgb(255, 128, 0))]))])
    }

    @Test func sgr_default_foreground() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5B, 0x33, 0x39, 0x6D]))
                == [.csi(.sgr([.foreground(.default)]))])
    }
}

// MARK: - OSC typed mapping

struct OSCParseTests {

    @Test func osc_0_sets_window_title() {
        var parser = TerminalParser()
        // ESC ] 0 ; h i BEL
        #expect(parser.parse(Data([0x1B, 0x5D, 0x30, 0x3B, 0x68, 0x69, 0x07]))
                == [.osc(.setWindowTitle("hi"))])
    }

    @Test func osc_2_sets_window_title() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5D, 0x32, 0x3B, 0x54, 0x65, 0x73, 0x74, 0x07]))
                == [.osc(.setWindowTitle("Test"))])
    }

    @Test func osc_1_sets_icon_name() {
        var parser = TerminalParser()
        #expect(parser.parse(Data([0x1B, 0x5D, 0x31, 0x3B, 0x78, 0x07]))
                == [.osc(.setIconName("x"))])
    }

    @Test func osc_unknown_preserved() {
        var parser = TerminalParser()
        // ESC ] 8 ; ; http://x BEL  (hyperlink — Phase 3)
        let bytes: [UInt8] = [0x1B, 0x5D, 0x38, 0x3B, 0x3B, 0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F, 0x2F, 0x78, 0x07]
        #expect(parser.parse(Data(bytes)) == [.osc(.unknown(ps: 8, pt: ";http://x"))])
    }
}
