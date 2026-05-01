//
//  TerminalParser.swift
//  TermCore
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

import Foundation

/// A stateful parser that converts raw bytes from a PTY into ``TerminalEvent`` values.
///
/// `TerminalParser` is value-typed. Each copy carries its own in-flight state
/// buffer — partial UTF-8, collected CSI params, OSC accumulator. Callers must
/// own **one instance per PTY stream**, held inside an actor or other serialized
/// context. Copying the parser mid-stream duplicates and silently diverges
/// buffered bytes.
public struct TerminalParser: Sendable {

    // MARK: - State machine

    /// Paul Williams VT state machine states — see `vt100.net/emu/dec_ansi_parser`
    /// for the canonical diagram. Associated values hold in-flight collection.
    private enum VTState: Sendable, Equatable {
        case ground
        case escape
        case csiEntry
        case csiParam(params: [Int], current: Int?, intermediates: [UInt8])
        case csiIntermediate(params: [Int], intermediates: [UInt8])
        case csiIgnore
        case oscString(ps: Int?, accumulator: String, pendingST: Bool)
        /// Collected until ST; Phase 3 parses sixel / kitty images.
        /// `pendingST` tracks whether the previous byte was ESC, awaiting a `\`
        /// to complete the String Terminator.
        case dcsIgnore(pendingST: Bool)
    }

    private enum Limits {
        static let csiParams = 16
        static let csiIntermediates = 2
        static let oscPayload = 4096
    }

    /// Current VT state machine state.
    private var state: VTState = .ground

    /// Holds the leading bytes of an incomplete UTF-8 sequence between calls.
    /// A valid incomplete sequence is at most 3 bytes (waiting for the final byte
    /// of a 4-byte sequence). Only drained inside `.ground`.
    private var utf8Buffer: [UInt8] = []

    public init() {}

    // MARK: - Public API

    /// Parse `data` into an array of ``TerminalEvent`` values.
    ///
    /// - Parameter data: Raw bytes as received from the PTY.
    /// - Returns: All events decoded from this chunk, combined with any previously
    ///   buffered incomplete sequence state. Returns `[]` when `data` contributes
    ///   only the leading bytes of a not-yet-complete multi-byte/escape sequence.
    ///
    /// - Complexity: O(*n*) in `data.count`. The result array is pre-reserved to
    ///   `data.count` to avoid incremental reallocations on the common path.
    public mutating func parse(_ data: Data) -> [TerminalEvent] {
        var events: [TerminalEvent] = []
        events.reserveCapacity(data.count)

        // Materialize to a flat byte array so `.ground` can use lookahead
        // for multi-byte UTF-8 without fighting Data's slicing/indexing.
        // Prepend any UTF-8 leading bytes stashed on the previous chunk.
        let bytes: [UInt8]
        if utf8Buffer.isEmpty {
            bytes = Array(data)
        } else {
            bytes = utf8Buffer + data
            utf8Buffer = []
        }

        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]

            switch state {
            case .ground:
                // The .ground arm owns UTF-8 handling (which may consume more
                // than one byte and may buffer a partial sequence).
                handleGroundByte(byte, bytes: bytes, index: &index, events: &events)

            case .escape:
                handleEscapeByte(byte, events: &events)
                index = bytes.index(after: index)

            case .csiEntry:
                handleCSIEntryByte(byte, events: &events)
                index = bytes.index(after: index)

            case .csiParam(let params, let current, let intermediates):
                handleCSIParamByte(
                    byte,
                    params: params,
                    current: current,
                    intermediates: intermediates,
                    events: &events
                )
                index = bytes.index(after: index)

            case .csiIntermediate(let params, let intermediates):
                handleCSIIntermediateByte(
                    byte,
                    params: params,
                    intermediates: intermediates,
                    events: &events
                )
                index = bytes.index(after: index)

            case .csiIgnore:
                handleCSIIgnoreByte(byte, events: &events)
                index = bytes.index(after: index)

            case .oscString(let ps, let accumulator, let pendingST):
                handleOSCByte(
                    byte,
                    ps: ps,
                    accumulator: accumulator,
                    pendingST: pendingST,
                    events: &events
                )
                index = bytes.index(after: index)

            case .dcsIgnore(let pendingST):
                handleDCSIgnoreByte(byte, pendingST: pendingST, events: &events)
                index = bytes.index(after: index)
            }
        }

        return events
    }

    // MARK: - Byte classification

    @inline(__always) private static func isCSIParamDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) private static func isCSIParamSep(_ b: UInt8) -> Bool { b == 0x3B || b == 0x3A }  // ';' or ':'
    @inline(__always) private static func isCSIIntermediate(_ b: UInt8) -> Bool { b >= 0x20 && b <= 0x2F }
    @inline(__always) private static func isCSIFinal(_ b: UInt8) -> Bool { b >= 0x40 && b <= 0x7E }

    // MARK: - .ground handling (preserves existing UTF-8 buffering)

    /// Handles a single byte while in `.ground`. May consume multiple bytes
    /// for a UTF-8 sequence, and advances `index` accordingly. If the byte
    /// is ESC (0x1B), transitions state and advances by one.
    private mutating func handleGroundByte(
        _ byte: UInt8,
        bytes: [UInt8],
        index: inout Array<UInt8>.Index,
        events: inout [TerminalEvent]
    ) {
        // ESC starts an escape sequence — transition out of ground.
        if byte == 0x1B {
            state = .escape
            index = bytes.index(after: index)
            return
        }

        if byte < 0x80 {
            // Single-byte ASCII range — route through the control table.
            events.append(Self.asciiEvent(byte))
            index = bytes.index(after: index)
            return
        }

        // Multi-byte UTF-8 sequence. Determine the expected total length
        // from the leading byte's bit pattern, then consume that many bytes.
        guard let seqLen = utf8SequenceLength(leadByte: byte) else {
            // Not a valid UTF-8 lead byte (e.g. a stray continuation byte
            // 0x80–0xBF, or an invalid byte 0xF8–0xFF).
            events.append(.unrecognized(byte))
            index = bytes.index(after: index)
            return
        }

        let remaining = bytes.distance(from: index, to: bytes.endIndex)
        guard remaining >= seqLen else {
            // We have the lead byte but not all continuation bytes yet.
            // Buffer the available bytes and wait for the next chunk.
            utf8Buffer = Array(bytes[index...])
            index = bytes.endIndex
            return
        }

        let seqSlice = bytes[index ..< index + seqLen]
        if let scalar = decodeUTF8Scalar(bytes: seqSlice) {
            events.append(.printable(Character(scalar)))
        } else {
            // The bytes form a structurally valid length but encode an
            // invalid scalar (e.g. overlong encoding, surrogate, out of range).
            // Emit each byte individually as unrecognized.
            for b in seqSlice { events.append(.unrecognized(b)) }
        }
        index += seqLen
    }

    // MARK: - .escape handling

    private mutating func handleEscapeByte(_ byte: UInt8, events: inout [TerminalEvent]) {
        switch byte {
        case 0x5B:  // '['
            state = .csiEntry
        case 0x5D:  // ']'
            state = .oscString(ps: nil, accumulator: "", pendingST: false)
        case 0x50:  // 'P'
            state = .dcsIgnore(pendingST: false)
        case 0x18, 0x1A:  // CAN, SUB
            state = .ground
        case 0x1B:  // ESC restart
            state = .escape
        default:
            events.append(.unrecognized(byte))
            state = .ground
        }
    }

    // MARK: - .csiEntry handling

    private mutating func handleCSIEntryByte(_ byte: UInt8, events: inout [TerminalEvent]) {
        // Per Paul Williams VT parser spec: C0 controls mid-CSI execute
        // (emit their normal event) and leave the state machine in the
        // current state. Only bytes >= 0x20 participate in CSI parameter
        // / intermediate / final dispatch.
        if byte < 0x20 {
            // 0x18 CAN and 0x1A SUB are sequence-cancel, not execute.
            if byte == 0x18 || byte == 0x1A {
                state = .ground
                return
            }
            // 0x1B ESC starts a fresh escape sequence (existing behavior).
            if byte == 0x1B {
                state = .escape
                return
            }
            // All other C0 (0x00-0x17, 0x19, 0x1C-0x1F): execute and stay in state.
            events.append(Self.asciiEvent(byte))
            return
        }

        if Self.isCSIParamDigit(byte) {
            state = .csiParam(params: [], current: Int(byte - 0x30), intermediates: [])
            return
        }
        if Self.isCSIParamSep(byte) {
            // Leading separator — first implicit param is 0.
            state = .csiParam(params: [0], current: nil, intermediates: [])
            return
        }
        if byte >= 0x3C && byte <= 0x3F {
            // Private-mode markers (`<`, `=`, `>`, `?`). Stash in intermediates
            // so mapCSI (Task 4) can still see them.
            state = .csiParam(params: [], current: nil, intermediates: [byte])
            return
        }
        if Self.isCSIIntermediate(byte) {
            state = .csiIntermediate(params: [], intermediates: [byte])
            return
        }
        if Self.isCSIFinal(byte) {
            events.append(.csi(.unknown(params: [], intermediates: [], final: byte)))
            state = .ground
            return
        }
        state = .csiIgnore
    }

    // MARK: - .csiParam handling

    private mutating func handleCSIParamByte(
        _ byte: UInt8,
        params: [Int],
        current: Int?,
        intermediates: [UInt8],
        events: inout [TerminalEvent]
    ) {
        // Per Paul Williams VT parser spec: C0 controls mid-CSI execute
        // (emit their normal event) and leave the state machine in the
        // current state. Only bytes >= 0x20 participate in CSI parameter
        // / intermediate / final dispatch.
        if byte < 0x20 {
            // 0x18 CAN and 0x1A SUB are sequence-cancel, not execute.
            if byte == 0x18 || byte == 0x1A {
                state = .ground
                return
            }
            // 0x1B ESC starts a fresh escape sequence (existing behavior).
            if byte == 0x1B {
                state = .escape
                return
            }
            // All other C0 (0x00-0x17, 0x19, 0x1C-0x1F): execute and stay in state.
            events.append(Self.asciiEvent(byte))
            return
        }

        if Self.isCSIParamDigit(byte) {
            let next = (current ?? 0) &* 10 &+ Int(byte - 0x30)
            state = .csiParam(params: params, current: next, intermediates: intermediates)
            return
        }
        if Self.isCSIParamSep(byte) {
            var newParams = params
            if newParams.count < Limits.csiParams {
                newParams.append(current ?? 0)
            }
            state = .csiParam(params: newParams, current: nil, intermediates: intermediates)
            return
        }
        if byte >= 0x3C && byte <= 0x3F {
            // Private markers (< = > ?) are only legal at CSI entry, not after
            // params. Williams spec treats this as malformed — drop the sequence.
            state = .csiIgnore
            return
        }
        if Self.isCSIIntermediate(byte) {
            var flushed = params
            if let cur = current, flushed.count < Limits.csiParams {
                flushed.append(cur)
            }
            if intermediates.count + 1 > Limits.csiIntermediates {
                state = .csiIgnore
            } else {
                state = .csiIntermediate(params: flushed, intermediates: intermediates + [byte])
            }
            return
        }
        if Self.isCSIFinal(byte) {
            var flushed = params
            if let cur = current, flushed.count < Limits.csiParams {
                flushed.append(cur)
            }
            events.append(.csi(.unknown(params: flushed, intermediates: intermediates, final: byte)))
            state = .ground
            return
        }
        state = .csiIgnore
    }

    // MARK: - .csiIntermediate handling

    private mutating func handleCSIIntermediateByte(
        _ byte: UInt8,
        params: [Int],
        intermediates: [UInt8],
        events: inout [TerminalEvent]
    ) {
        // Per Paul Williams VT parser spec: C0 controls mid-CSI execute
        // (emit their normal event) and leave the state machine in the
        // current state. Only bytes >= 0x20 participate in CSI parameter
        // / intermediate / final dispatch.
        if byte < 0x20 {
            // 0x18 CAN and 0x1A SUB are sequence-cancel, not execute.
            if byte == 0x18 || byte == 0x1A {
                state = .ground
                return
            }
            // 0x1B ESC starts a fresh escape sequence (existing behavior).
            if byte == 0x1B {
                state = .escape
                return
            }
            // All other C0 (0x00-0x17, 0x19, 0x1C-0x1F): execute and stay in state.
            events.append(Self.asciiEvent(byte))
            return
        }

        if Self.isCSIIntermediate(byte) {
            if intermediates.count + 1 > Limits.csiIntermediates {
                state = .csiIgnore
            } else {
                state = .csiIntermediate(params: params, intermediates: intermediates + [byte])
            }
            return
        }
        if Self.isCSIFinal(byte) {
            events.append(.csi(.unknown(params: params, intermediates: intermediates, final: byte)))
            state = .ground
            return
        }
        // Includes param digits/separators appearing after intermediates —
        // structurally invalid per Williams, drop the sequence.
        state = .csiIgnore
    }

    // MARK: - .csiIgnore handling

    private mutating func handleCSIIgnoreByte(_ byte: UInt8, events: inout [TerminalEvent]) {
        // Per Paul Williams VT parser spec: C0 controls mid-CSI execute
        // (emit their normal event) and leave the state machine in the
        // current state. Only bytes >= 0x20 participate in CSI parameter
        // / intermediate / final dispatch.
        if byte < 0x20 {
            // 0x18 CAN and 0x1A SUB are sequence-cancel, not execute.
            if byte == 0x18 || byte == 0x1A {
                state = .ground
                return
            }
            // 0x1B ESC starts a fresh escape sequence (existing behavior).
            if byte == 0x1B {
                state = .escape
                return
            }
            // All other C0 (0x00-0x17, 0x19, 0x1C-0x1F): execute and stay in state.
            events.append(Self.asciiEvent(byte))
            return
        }

        if Self.isCSIFinal(byte) {
            state = .ground
            return
        }
        // silently consume non-final bytes >= 0x20
    }

    // MARK: - .oscString handling

    private mutating func handleOSCByte(
        _ byte: UInt8,
        ps: Int?,
        accumulator: String,
        pendingST: Bool,
        events: inout [TerminalEvent]
    ) {
        // Completion via ESC \ (String Terminator).
        if pendingST {
            if byte == 0x5C {
                emitOSC(ps: ps, accumulator: accumulator, events: &events)
                state = .ground
            } else {
                // ESC followed by non-\: drop the OSC and route the new
                // byte through the escape state machine.
                state = .escape
                handleEscapeByte(byte, events: &events)
            }
            return
        }

        switch byte {
        case 0x07:  // BEL — terminator for OSC
            emitOSC(ps: ps, accumulator: accumulator, events: &events)
            state = .ground
            return
        case 0x18, 0x1A:  // CAN, SUB — drop the OSC
            state = .ground
            return
        case 0x1B:  // ESC — potential ST lead
            state = .oscString(ps: ps, accumulator: accumulator, pendingST: true)
            return
        default:
            break
        }

        // Semantics:
        //   `ps == nil`
        //       → we are collecting the Ps field. Digits accumulate into
        //         `accumulator` (repurposed as digit-work-area); `;` commits
        //         the parsed integer to `ps` and clears `accumulator` which
        //         then accumulates Pt.
        //   `ps != nil`
        //       → Ps was committed; subsequent bytes append to Pt (the
        //         accumulator), capped at Limits.oscPayload.
        if ps == nil {
            // Still collecting Ps.
            if byte >= 0x30 && byte <= 0x39 {  // digit — append to Ps work area
                var acc = accumulator
                acc.append(Character(UnicodeScalar(byte)))
                state = .oscString(ps: nil, accumulator: acc, pendingST: false)
                return
            }
            if byte == 0x3B {  // ';' finalizes Ps and transitions to Pt
                let parsedPs = Int(accumulator) ?? 0
                state = .oscString(ps: parsedPs, accumulator: "", pendingST: false)
                return
            }
            // Non-digit, non-semicolon byte before Ps termination — the
            // spec is lenient here; treat the stream as if Ps=0 and the
            // byte is the first byte of Pt.
            let parsedPs = Int(accumulator) ?? 0
            var pt = ""
            if let scalar = Unicode.Scalar(UInt32(byte)) {
                pt.append(Character(scalar))
            }
            state = .oscString(ps: parsedPs, accumulator: pt, pendingST: false)
            return
        }

        // Ps already committed — accumulate into Pt.
        var pt = accumulator
        if pt.count < Limits.oscPayload,
           let scalar = Unicode.Scalar(UInt32(byte)) {
            pt.append(Character(scalar))
        }
        // else: silently drop overflow bytes; keep collecting until terminator.
        state = .oscString(ps: ps, accumulator: pt, pendingST: false)
    }

    /// Emit a completed OSC event. If `ps` is nil, the terminator arrived before
    /// any `;`, so `accumulator` holds digits for Ps (or garbage, treated as 0)
    /// and Pt is empty.
    private func emitOSC(
        ps: Int?,
        accumulator: String,
        events: inout [TerminalEvent]
    ) {
        let resolvedPs: Int
        let pt: String
        if let ps = ps {
            resolvedPs = ps
            pt = accumulator
        } else {
            resolvedPs = Int(accumulator) ?? 0
            pt = ""
        }
        events.append(.osc(.unknown(ps: resolvedPs, pt: pt)))
    }

    // MARK: - .dcsIgnore handling

    private mutating func handleDCSIgnoreByte(
        _ byte: UInt8,
        pendingST: Bool,
        events: inout [TerminalEvent]
    ) {
        // Consume everything until ESC \ (ST) or CAN/SUB.
        if pendingST {
            // Prior byte was ESC. Only `\` completes the String Terminator;
            // anything else aborts the DCS and falls into that byte's handling
            // via the escape state.
            if byte == 0x5C {
                state = .ground
            } else {
                state = .escape
                handleEscapeByte(byte, events: &events)
            }
            return
        }

        switch byte {
        case 0x18, 0x1A:
            state = .ground
        case 0x1B:
            state = .dcsIgnore(pendingST: true)
        default:
            break  // silently consume payload bytes
        }
    }

    // MARK: - ASCII control table

    /// Map a single ASCII byte (value < 0x80) to a ``TerminalEvent``.
    private static func asciiEvent(_ byte: UInt8) -> TerminalEvent {
        switch byte {
        case 0x00: return .c0(.nul)
        case 0x07: return .c0(.bell)
        case 0x08: return .c0(.backspace)
        case 0x09: return .c0(.horizontalTab)
        case 0x0A: return .c0(.lineFeed)
        case 0x0B: return .c0(.verticalTab)
        case 0x0C: return .c0(.formFeed)
        case 0x0D: return .c0(.carriageReturn)
        case 0x0E: return .c0(.shiftOut)
        case 0x0F: return .c0(.shiftIn)
        case 0x20 ... 0x7E: return .printable(Character(UnicodeScalar(byte)))
        case 0x7F: return .c0(.delete)
        default: return .unrecognized(byte)
        }
    }

    // MARK: - UTF-8 decoding helpers

    /// Return the total byte count of a UTF-8 sequence starting with `leadByte`,
    /// or `nil` if `leadByte` is not a valid UTF-8 lead byte.
    private func utf8SequenceLength(leadByte: UInt8) -> Int? {
        switch leadByte {
        case 0xC2 ... 0xDF: return 2
        case 0xE0 ... 0xEF: return 3
        case 0xF0 ... 0xF7: return 4
        default: return nil  // 0x80–0xBF (continuation) or 0xF8+ (invalid)
        }
    }

    /// Decode a slice of exactly the right number of UTF-8 bytes into a Unicode scalar.
    /// Returns `nil` for invalid encodings (overlong, surrogate halves, out-of-range).
    private func decodeUTF8Scalar(bytes: ArraySlice<UInt8>) -> Unicode.Scalar? {
        // Use Swift's String initializer as the canonical decoder.
        guard let str = String(bytes: bytes, encoding: .utf8),
              str.unicodeScalars.count == 1,
              let scalar = str.unicodeScalars.first
        else { return nil }
        return scalar
    }
}
