//
//  TerminalEvent.swift
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

/// Top-level terminal event. Subfamilies (C0, CSI, OSC) are grouped into
/// nested enums so exhaustive switching happens at two levels — see §3 of
/// the Phase-1 spec.
///
/// This enum is intentionally **not** `@frozen`: phases may legitimately add
/// top-level cases. Consumers should `switch` exhaustively. Future additions
/// will be either new `.unknown(...)` variants inside subfamilies or new top-
/// level cases, which are a deliberate breaking change at the phase boundary.
public enum TerminalEvent: Sendable, Equatable {
    case printable(Character)
    case c0(C0Control)
    case csi(CSICommand)
    case osc(OSCCommand)
    case unrecognized(UInt8)
}
