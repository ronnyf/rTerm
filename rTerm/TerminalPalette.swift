//
//  TerminalPalette.swift
//  rTerm
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

/// User-defined palette providing concrete `RGBA` values for the 16 ANSI slots
/// plus the default foreground/background and the cursor color. Resolved colors
/// for `palette256` and `truecolor` are derived elsewhere (the 256-color cube
/// is built from ANSI-16 + a programmatic 6×6×6 + grayscale ramp; truecolor is
/// passed through unchanged unless `ColorDepth` quantization is enabled).
///
/// `Codable` is hand-coded because `InlineArray` is not `Codable`-synthesisable;
/// the `ansi` slot is encoded as a 16-element `[RGBA]` array on the wire.
public struct TerminalPalette: Sendable, Equatable, Codable {
    public var ansi: InlineArray<16, RGBA>
    public var defaultForeground: RGBA
    public var defaultBackground: RGBA
    public var cursor: RGBA

    nonisolated public init(ansi: InlineArray<16, RGBA>,
                defaultForeground: RGBA,
                defaultBackground: RGBA,
                cursor: RGBA) {
        self.ansi = ansi
        self.defaultForeground = defaultForeground
        self.defaultBackground = defaultBackground
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey {
        case ansi, defaultForeground, defaultBackground, cursor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let wire = try c.decode([RGBA].self, forKey: .ansi)
        guard wire.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .ansi, in: c,
                debugDescription: "ansi palette must have exactly 16 entries")
        }
        var inline = InlineArray<16, RGBA>(repeating: RGBA(0, 0, 0))
        for i in 0..<16 { inline[i] = wire[i] }
        self.ansi = inline
        self.defaultForeground = try c.decode(RGBA.self, forKey: .defaultForeground)
        self.defaultBackground = try c.decode(RGBA.self, forKey: .defaultBackground)
        self.cursor = try c.decode(RGBA.self, forKey: .cursor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        var wire = [RGBA]()
        wire.reserveCapacity(16)
        for i in 0..<16 { wire.append(ansi[i]) }
        try c.encode(wire, forKey: .ansi)
        try c.encode(defaultForeground, forKey: .defaultForeground)
        try c.encode(defaultBackground, forKey: .defaultBackground)
        try c.encode(cursor, forKey: .cursor)
    }

    /// Standard xterm color palette — the canonical 16-color set most ANSI
    /// programs assume by default.
    nonisolated public static let xtermDefault: TerminalPalette = {
        var ansi = InlineArray<16, RGBA>(repeating: RGBA(0, 0, 0))
        ansi[0]  = RGBA(0,   0,   0)
        ansi[1]  = RGBA(205, 0,   0)
        ansi[2]  = RGBA(0,   205, 0)
        ansi[3]  = RGBA(205, 205, 0)
        ansi[4]  = RGBA(0,   0,   238)
        ansi[5]  = RGBA(205, 0,   205)
        ansi[6]  = RGBA(0,   205, 205)
        ansi[7]  = RGBA(229, 229, 229)
        ansi[8]  = RGBA(127, 127, 127)
        ansi[9]  = RGBA(255, 0,   0)
        ansi[10] = RGBA(0,   255, 0)
        ansi[11] = RGBA(255, 255, 0)
        ansi[12] = RGBA(92,  92,  255)
        ansi[13] = RGBA(255, 0,   255)
        ansi[14] = RGBA(0,   255, 255)
        ansi[15] = RGBA(255, 255, 255)
        return TerminalPalette(ansi: ansi,
                               defaultForeground: RGBA(229, 229, 229),
                               defaultBackground: RGBA(0, 0, 0),
                               cursor: RGBA(229, 229, 229))
    }()
}
