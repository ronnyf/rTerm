//
//  SGRAttribute.swift
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

/// A single SGR (Select Graphic Rendition) attribute: one parameter token
/// from `CSI … m`. A stream of these is applied in order to the pen.
///
/// Non-`@frozen`: future SGR extensions (e.g., curly/dotted underline) may add cases.
///
/// - Note: Allocation-on-parse is a known Phase 3 optimization target — see spec §3.
public enum SGRAttribute: Sendable, Equatable {
    case reset                                      // 0
    case bold                                       // 1
    case dim                                        // 2
    case italic                                     // 3
    case underline                                  // 4
    case blink                                      // 5
    case reverse                                    // 7
    case strikethrough                              // 9
    case resetIntensity                             // 22 (clears bold + dim)
    case resetItalic                                // 23
    case resetUnderline                             // 24
    case resetBlink                                 // 25
    case resetReverse                               // 27
    case resetStrikethrough                         // 29
    case foreground(TerminalColor)                  // 30-37, 38, 39, 90-97
    case background(TerminalColor)                  // 40-47, 48, 49, 100-107
}
