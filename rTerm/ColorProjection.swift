//
//  ColorProjection.swift
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
import TermCore

/// Whether a `TerminalColor` is being resolved as a foreground or background.
/// Affects the `default` case (which routes to the palette's `defaultForeground`
/// or `defaultBackground`).
@frozen public enum ColorRole: Sendable, Equatable {
    case foreground
    case background
}

/// Pure functions that project a `TerminalColor` (max-fidelity model output) to
/// a concrete `RGBA` for the renderer. The projection respects the user's
/// chosen `ColorDepth` — quantizing truecolor down to 256/16 entries when the
/// user has opted into a lower-fidelity palette.
///
/// All members are `nonisolated`: the renderer calls these on the MainActor at
/// draw time, but tests and other consumers must be able to call them from any
/// isolation. They depend only on their parameters — no shared state.
public enum ColorProjection {

    /// Resolve a `TerminalColor` to a concrete `RGBA` according to the active
    /// depth + palette.
    ///
    /// - Parameters:
    ///   - color: Color stored in `CellStyle.foreground` / `.background`.
    ///   - role: Foreground vs background — controls the `.default` mapping.
    ///   - depth: Active color fidelity.
    ///   - palette: Active 16-slot ANSI palette + defaults.
    ///   - derivedPalette256: Pre-computed 256-color palette (must be derived
    ///     from `palette` via `derivePalette256(from:)`). Caller-managed cache
    ///     so we don't rebuild the cube on every cell.
    nonisolated public static func resolve(
        _ color: TerminalColor,
        role: ColorRole,
        depth: ColorDepth,
        palette: TerminalPalette,
        derivedPalette256: InlineArray<256, RGBA>
    ) -> RGBA {
        switch (color, depth) {
        case (.default, _):
            return role == .foreground ? palette.defaultForeground : palette.defaultBackground
        case (.ansi16(let i), _):
            return palette.ansi[Int(i)]
        case (.palette256(let i), .ansi16):
            return quantizeToAnsi16(derivedPalette256[Int(i)], palette: palette)
        case (.palette256(let i), _):
            return derivedPalette256[Int(i)]
        case (.rgb(let r, let g, let b), .ansi16):
            return quantizeToAnsi16(RGBA(r, g, b), palette: palette)
        case (.rgb(let r, let g, let b), .palette256):
            return quantizeTo256(RGBA(r, g, b), derivedPalette256: derivedPalette256)
        case (.rgb(let r, let g, let b), .truecolor):
            return RGBA(r, g, b)
        }
    }

    /// Build the standard xterm 256-color palette: slots 0–15 are taken from
    /// `palette.ansi`, slots 16–231 form a 6×6×6 RGB cube, and slots 232–255
    /// are a 24-step grayscale ramp.
    nonisolated public static func derivePalette256(from palette: TerminalPalette) -> InlineArray<256, RGBA> {
        var result = InlineArray<256, RGBA>(repeating: RGBA(0, 0, 0))
        for i in 0..<16 { result[i] = palette.ansi[i] }
        let cubeLevels: [UInt8] = [0, 95, 135, 175, 215, 255]
        var idx = 16
        for r in 0..<6 {
            for g in 0..<6 {
                for b in 0..<6 {
                    result[idx] = RGBA(cubeLevels[r], cubeLevels[g], cubeLevels[b])
                    idx += 1
                }
            }
        }
        for i in 0..<24 {
            let v = UInt8(8 + i * 10)
            result[232 + i] = RGBA(v, v, v)
        }
        return result
    }

    nonisolated private static func quantizeToAnsi16(_ c: RGBA, palette: TerminalPalette) -> RGBA {
        var best = 0
        var bestDist = Int.max
        for i in 0..<16 {
            let p = palette.ansi[i]
            let d = sqDist(c, p)
            if d < bestDist { bestDist = d; best = i }
        }
        return palette.ansi[best]
    }

    nonisolated private static func quantizeTo256(_ c: RGBA, derivedPalette256: InlineArray<256, RGBA>) -> RGBA {
        var best = 0
        var bestDist = Int.max
        for i in 0..<256 {
            let p = derivedPalette256[i]
            let d = sqDist(c, p)
            if d < bestDist { bestDist = d; best = i }
        }
        return derivedPalette256[best]
    }

    @inline(__always)
    nonisolated private static func sqDist(_ a: RGBA, _ b: RGBA) -> Int {
        let dr = Int(a.r) - Int(b.r)
        let dg = Int(a.g) - Int(b.g)
        let db = Int(a.b) - Int(b.b)
        return dr * dr + dg * dg + db * db
    }
}
