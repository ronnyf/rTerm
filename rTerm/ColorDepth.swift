//
//  ColorDepth.swift
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

/// User-selectable color fidelity for renderer projection.
///
/// The terminal model preserves color at maximum fidelity (`TerminalColor`).
/// `ColorDepth` controls how the renderer projects each cell color to the final
/// pixel — quantizing down to a 16- or 256-entry palette, or passing the
/// original 24-bit RGB through unchanged.
@frozen public enum ColorDepth: Sendable, Equatable, Codable {
    case ansi16
    case palette256
    case truecolor
}
