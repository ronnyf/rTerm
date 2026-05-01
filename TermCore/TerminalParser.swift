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
/// `TerminalParser` is a value type. Its only mutable state is a small buffer that
/// holds the leading byte(s) of an incomplete multi-byte UTF-8 sequence; this buffer
/// is drained as soon as the sequence is completed on a subsequent `parse(_:)` call.
///
/// Because the type is a struct, callers own their parser and there is no shared
/// mutable state between callers. Mark the owning storage `var` and call `parse`
/// with `mutating` semantics.
public struct TerminalParser: Sendable {

    /// Holds the leading bytes of an incomplete UTF-8 sequence between calls.
    /// A valid incomplete sequence is at most 3 bytes (waiting for the final byte
    /// of a 4-byte sequence).
    private var utf8Buffer: [UInt8] = []

    public init() {}

    // MARK: - Public API

    /// Parse `data` into an array of ``TerminalEvent`` values.
    ///
    /// - Parameter data: Raw bytes as received from the PTY.
    /// - Returns: All events decoded from this chunk, combined with any previously
    ///   buffered incomplete UTF-8 prefix. Returns `[]` when `data` contributes
    ///   only the leading bytes of a not-yet-complete multi-byte sequence.
    ///
    /// - Complexity: O(*n*) in `data.count`. The result array is pre-reserved to
    ///   `data.count` to avoid incremental reallocations on the common path.
    public mutating func parse(_ data: Data) -> [TerminalEvent] {
        // Prepend any bytes from a previously incomplete multi-byte sequence.
        let bytes: [UInt8]
        if utf8Buffer.isEmpty {
            bytes = Array(data)
        } else {
            bytes = utf8Buffer + data
            utf8Buffer = []
        }

        var events: [TerminalEvent] = []
        events.reserveCapacity(bytes.count)

        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]

            if byte < 0x80 {
                // Single-byte ASCII range — route through the control table.
                events.append(Self.asciiEvent(byte))
                bytes.formIndex(after: &index)
            } else {
                // Multi-byte UTF-8 sequence. Determine the expected total length
                // from the leading byte's bit pattern, then consume that many bytes.
                guard let seqLen = utf8SequenceLength(leadByte: byte) else {
                    // Not a valid UTF-8 lead byte (e.g. a stray continuation byte
                    // 0x80–0xBF, or an invalid byte 0xF8–0xFF).
                    events.append(.unrecognized(byte))
                    bytes.formIndex(after: &index)
                    continue
                }

                let remaining = bytes.distance(from: index, to: bytes.endIndex)
                guard remaining >= seqLen else {
                    // We have the lead byte but not all continuation bytes yet.
                    // Buffer the available bytes and wait for the next chunk.
                    utf8Buffer = Array(bytes[index...])
                    return events
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
        }

        return events
    }

    // MARK: - Private helpers

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
