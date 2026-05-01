//
//  CellStyle.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

import Foundation

/// SGR attribute bitfield — compact representation for the per-cell style.
@frozen public struct CellAttributes: OptionSet, Sendable, Equatable, Codable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let bold          = CellAttributes(rawValue: 1 << 0)
    public static let dim           = CellAttributes(rawValue: 1 << 1)
    public static let italic        = CellAttributes(rawValue: 1 << 2)
    public static let underline     = CellAttributes(rawValue: 1 << 3)
    public static let blink         = CellAttributes(rawValue: 1 << 4)
    public static let reverse       = CellAttributes(rawValue: 1 << 5)
    public static let strikethrough = CellAttributes(rawValue: 1 << 6)
}

/// Per-cell visual style. Mirrors the "current pen" state that SGR modifies.
public struct CellStyle: Sendable, Equatable, Codable {
    public var foreground: TerminalColor
    public var background: TerminalColor
    public var attributes: CellAttributes

    public init(foreground: TerminalColor = .default,
                background: TerminalColor = .default,
                attributes: CellAttributes = []) {
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
    }

    public static let `default` = CellStyle()
}
