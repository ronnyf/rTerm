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
/// Storage note: `ansi` is a `ContiguousArray<RGBA>` (canonical, always 16
/// entries — validated by `init` and `Codable`). `InlineArray<16, RGBA>`
/// (SE-0453) would be the natural fit for fixed-size in-line storage, but it
/// requires macOS 26 while this binary must run on macOS 15. Callers that
/// want the in-line representation on newer OS versions can read the
/// `@available(macOS 26.0, *)` `ansiInline` accessor.
///
/// Wire format: `ansi` is encoded as a 16-element JSON array of `RGBA`
/// quadruples — unchanged from the previous (InlineArray-based) shape.
public struct TerminalPalette: Sendable, Equatable, Codable {
    /// ANSI 16-color slots, indices `0..<16`. Always exactly 16 entries —
    /// `init` and `Codable` decoding both reject any other count.
    public var ansi: ContiguousArray<RGBA>
    public var defaultForeground: RGBA
    public var defaultBackground: RGBA
    public var cursor: RGBA

    /// Number of ANSI palette slots — always 16. Use as a clarity-improving
    /// constant in tight loops instead of a literal.
    public static let ansiCount: Int = 16

    /// Designated initializer. Traps if `ansi.count != 16` so the invariant is
    /// caught at the call site rather than later in the renderer.
    nonisolated public init(ansi: ContiguousArray<RGBA>,
                            defaultForeground: RGBA,
                            defaultBackground: RGBA,
                            cursor: RGBA) {
        precondition(ansi.count == Self.ansiCount,
                     "TerminalPalette.ansi must have exactly \(Self.ansiCount) entries; got \(ansi.count)")
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
        guard wire.count == Self.ansiCount else {
            throw DecodingError.dataCorruptedError(forKey: .ansi, in: c,
                debugDescription: "ansi palette must have exactly \(Self.ansiCount) entries")
        }
        self.ansi = ContiguousArray(wire)
        self.defaultForeground = try c.decode(RGBA.self, forKey: .defaultForeground)
        self.defaultBackground = try c.decode(RGBA.self, forKey: .defaultBackground)
        self.cursor = try c.decode(RGBA.self, forKey: .cursor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Array(ansi), forKey: .ansi)
        try c.encode(defaultForeground, forKey: .defaultForeground)
        try c.encode(defaultBackground, forKey: .defaultBackground)
        try c.encode(cursor, forKey: .cursor)
    }

    /// In-line representation of the 16 ANSI slots for callers that prefer the
    /// fixed-size storage (e.g. for tight inner loops). Available on macOS 26+.
    @available(macOS 26.0, *)
    public var ansiInline: InlineArray<16, RGBA> {
        var out = InlineArray<16, RGBA>(repeating: RGBA(0, 0, 0))
        for i in 0..<Self.ansiCount { out[i] = ansi[i] }
        return out
    }

    /// Standard xterm color palette — the canonical 16-color set most ANSI
    /// programs assume by default.
    nonisolated public static let xtermDefault: TerminalPalette = {
        let ansi: ContiguousArray<RGBA> = [
            RGBA(0,   0,   0),
            RGBA(205, 0,   0),
            RGBA(0,   205, 0),
            RGBA(205, 205, 0),
            RGBA(0,   0,   238),
            RGBA(205, 0,   205),
            RGBA(0,   205, 205),
            RGBA(229, 229, 229),
            RGBA(127, 127, 127),
            RGBA(255, 0,   0),
            RGBA(0,   255, 0),
            RGBA(255, 255, 0),
            RGBA(92,  92,  255),
            RGBA(255, 0,   255),
            RGBA(0,   255, 255),
            RGBA(255, 255, 255),
        ]
        return TerminalPalette(ansi: ansi,
                               defaultForeground: RGBA(229, 229, 229),
                               defaultBackground: RGBA(0, 0, 0),
                               cursor: RGBA(229, 229, 229))
    }()
}
