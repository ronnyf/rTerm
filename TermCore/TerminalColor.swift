//
//  TerminalColor.swift
//  TermCore
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

/// Terminal foreground or background color — always stored at maximum fidelity.
///
/// The parser emits colors exactly as received. The renderer projects to the
/// user's chosen color depth at draw time; the model itself is depth-agnostic.
///
/// - `default`: resolves to the palette's default fg/bg at render time.
/// - `ansi16(UInt8)`: range `0..<16`. Parser is responsible for keeping the
///   payload in this range; renderer may use `palette.ansi[Int(i)]` without masking.
/// - `palette256(UInt8)`: xterm 256-color palette index.
/// - `rgb(UInt8, UInt8, UInt8)`: 24-bit truecolor.
public enum TerminalColor: Sendable, Equatable, Codable {
    case `default`
    case ansi16(UInt8)
    case palette256(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}
