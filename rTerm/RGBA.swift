//
//  RGBA.swift
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
import simd

/// 32-bit RGBA color used by the renderer's color pipeline. Trivially copyable.
public struct RGBA: Sendable, Equatable, Codable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8
    public var a: UInt8

    nonisolated public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Pack into `SIMD4<Float>` normalized 0...1 for Metal uniforms / vertex attrs.
    public var simdNormalized: SIMD4<Float> {
        SIMD4<Float>(Float(r) / 255, Float(g) / 255, Float(b) / 255, Float(a) / 255)
    }

    nonisolated public static let black = RGBA(0, 0, 0)
    nonisolated public static let white = RGBA(255, 255, 255)
}
