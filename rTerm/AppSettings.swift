//
//  AppSettings.swift
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

/// Mutable user preferences that influence the renderer. SwiftUI views observe
/// changes via `@Observable`; the renderer caches derived state (e.g. the
/// 256-color palette) and only recomputes when `palette` identity changes.
///
/// Marked `@MainActor` explicitly even though the `rTerm` target defaults to
/// MainActor isolation — this makes the contract obvious at the type level.
@Observable @MainActor
public final class AppSettings {
    public var colorDepth: ColorDepth = .truecolor
    public var palette: TerminalPalette = .xtermDefault

    public init() {}
}
