//
//  TerminalModes.swift
//  TermCore
//
//  This file is part of rTerm.
//  Licensed under GPLv3 — see project LICENSE.
//

/// Terminal-wide mode flags that persist across alt-screen buffer swaps.
///
/// `autoWrap` and `cursorVisible` default `true` (the standard VT power-on state).
/// `cursorKeyApplication` and `bracketedPaste` default `false`.
///
/// Internal to TermCore — only `ScreenModel` mutates it. Callers outside the
/// framework read mode state through `ScreenSnapshot`'s individual fields.
struct TerminalModes: Sendable, Equatable, Codable {
    var autoWrap: Bool
    var cursorVisible: Bool
    var cursorKeyApplication: Bool
    var bracketedPaste: Bool

    init(autoWrap: Bool = true,
         cursorVisible: Bool = true,
         cursorKeyApplication: Bool = false,
         bracketedPaste: Bool = false) {
        self.autoWrap = autoWrap
        self.cursorVisible = cursorVisible
        self.cursorKeyApplication = cursorKeyApplication
        self.bracketedPaste = bracketedPaste
    }

    static let `default` = TerminalModes()
}
