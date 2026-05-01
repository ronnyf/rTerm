//
//  TerminalColor.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation

/// Terminal foreground or background color — always stored at maximum fidelity.
///
/// The parser emits colors exactly as received. The renderer projects to the
/// user's chosen ``ColorDepth`` at draw time; the model itself is depth-agnostic.
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
