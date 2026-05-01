//
//  OSCCommand.swift
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

/// An OSC (Operating System Command) payload: `ESC ] Ps ; Pt ST`.
///
/// Non-`@frozen`: Phase 3 adds OSC 8 (hyperlinks) and OSC 52 (clipboard).
public enum OSCCommand: Sendable, Equatable {
    case setWindowTitle(String)        // OSC 0 and OSC 2 (aliased)
    case setIconName(String)           // OSC 1
    case unknown(ps: Int, pt: String)  // Everything else: OSC 8, 52, 7, iTerm, ...
}
