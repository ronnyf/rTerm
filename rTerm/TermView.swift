//
//  TermView.swift
//  rTerm
//
//  Created by Ronny Falk on 7/9/24.
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

import MetalKit
import OSLog
import SwiftUI
import TermCore

// MARK: - TerminalMTKView

/// An `MTKView` subclass that accepts first-responder status and forwards
/// keyboard input as raw `Data` through a closure.
final class TerminalMTKView: MTKView, NSMenuItemValidation {

    private let log = Logger(subsystem: "rTerm", category: "TerminalMTKView")

    /// Called with the encoded byte sequence for each key-down event.
    var onKeyInput: ((Data) -> Void)?

    /// Called by `keyDown` to fetch the current DECCKM state. Returns
    /// `.normal` when nil. The closure is set by the SwiftUI bridge from
    /// `screenModel.latestSnapshot().cursorKeyApplication` at view-make time.
    var cursorKeyModeProvider: (() -> CursorKeyMode)?

    /// Called when the user invokes Edit > Paste (Cmd-V). The handler reads
    /// the system pasteboard's first plain-text item and forwards it.
    var onPaste: ((String) -> Void)?

    /// Called when the user scrolls inside the view (wheel, trackpad).
    var onScrollWheel: ((CGFloat) -> Void)?

    /// Page Up / Page Down handlers — return `true` if the gesture was consumed
    /// for scrollback navigation, `false` if it should fall through to the encoder.
    var onPageUp:   (() -> Bool)?
    var onPageDown: (() -> Bool)?

    /// Called when the user types — RenderCoordinator scrolls back to the
    /// bottom of the live grid before the input is sent.
    var onActiveInput: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Scrollback navigation hooks — Page Up / Page Down drive the
        // RenderCoordinator's scroll state when we're in the main buffer.
        // The hooks return true when they consume the event; false means
        // pass through to the encoder (and on to the shell).
        switch event.keyCode {
        case 116:  // kVK_PageUp
            if let h = onPageUp, h() { return }
        case 121:  // kVK_PageDown
            if let h = onPageDown, h() { return }
        default:
            break
        }
        let mode = cursorKeyModeProvider?() ?? .normal
        let encoder = KeyEncoder()
        if let data = encoder.encode(event, cursorKeyMode: mode) {
            onActiveInput?()
            log.debug("keyDown: keyCode=\(event.keyCode), encoded \(data.count) bytes")
            onKeyInput?(data)
        } else {
            log.debug("keyDown: keyCode=\(event.keyCode), unhandled")
        }
        // Swallow all key events — do not call super.
    }

    override func scrollWheel(with event: NSEvent) {
        // event.scrollingDeltaY is gesture-aware: with natural scrolling enabled
        // (macOS default), a two-finger trackpad gesture *up* gives positive
        // scrollingDeltaY — which matches "scroll back into history" intent.
        // With natural scrolling disabled (some Mighty Mouse users), the sign
        // flips to match physical wheel rotation. We pass the value through
        // unchanged; the user's "natural" preference governs both directions.
        let deltaY = event.scrollingDeltaY
        // Convert raw delta into row units. Trackpad emits precise sub-point
        // deltas (typically ~1-3 per gesture step); mouse wheel emits coarse
        // ~1.0 notches. ScrollViewState's accumulator aggregates fractions
        // across calls so trackpad gestures don't all round to zero.
        let rowsPerUnit: CGFloat = event.hasPreciseScrollingDeltas ? 0.05 : 1.0
        onScrollWheel?(deltaY * rowsPerUnit)
    }

    /// AppKit's standard paste action — picked up via responder-chain selector
    /// dispatch (not a method on MTKView/NSView, so no `override`). Reads the
    /// system pasteboard's first plain-text item and forwards it via `onPaste`.
    @objc
    func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        guard let str = pb.string(forType: .string), !str.isEmpty else { return }
        log.debug("paste: \(str.count) chars")
        onPaste?(str)
    }

    /// `NSMenuItemValidation` conformance — gates the Edit > Paste menu item
    /// on pasteboard availability. AppKit calls this via the formal protocol.
    @objc
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(paste(_:)) {
            return NSPasteboard.general.string(forType: .string) != nil
        }
        return true
    }
}

// MARK: - TermView

/// SwiftUI bridge that presents a Metal-backed terminal view with keyboard input.
struct TermView: NSViewRepresentable {

    let screenModel: ScreenModel
    let settings: AppSettings
    var onInput: ((Data) -> Void)?
    var onPaste: ((String) -> Void)?

    func makeCoordinator() -> RenderCoordinator {
        RenderCoordinator(screenModel: screenModel, settings: settings)
    }

    func makeNSView(context: Context) -> TerminalMTKView {
        let coordinator = context.coordinator
        let view = TerminalMTKView(frame: .zero, device: coordinator.device)
        view.delegate = coordinator
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = clearColor(for: settings.palette.defaultBackground)
        view.onKeyInput = onInput
        view.onPaste = onPaste
        view.cursorKeyModeProvider = makeCursorKeyModeProvider()
        view.onScrollWheel = { [weak view, weak coordinator] rowsBack in
            guard let view, let coordinator else { return }
            coordinator.handleScrollWheel(rowsBack: rowsBack, view: view)
        }
        view.onPageUp = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return false }
            // Only consume PgUp for scrollback when there IS history and we're on main.
            let snap = coordinator.screenModelForView.latestSnapshot()
            guard snap.activeBuffer == .main else { return false }
            let history = coordinator.screenModelForView.latestHistoryTail()
            guard history.count > 0 else { return false }
            return coordinator.handlePageUp(view: view)
        }
        view.onPageDown = { [weak view, weak coordinator] in
            guard let view, let coordinator else { return false }
            let snap = coordinator.screenModelForView.latestSnapshot()
            guard snap.activeBuffer == .main else { return false }
            guard coordinator.scrollState.offset > 0 else { return false }
            return coordinator.handlePageDown(view: view)
        }
        view.onActiveInput = { [weak coordinator] in
            coordinator?.scrollToBottom()
        }
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.onKeyInput = onInput
        nsView.onPaste = onPaste
        nsView.clearColor = clearColor(for: settings.palette.defaultBackground)
        nsView.cursorKeyModeProvider = makeCursorKeyModeProvider()
    }

    /// Build the closure that the view will call on each keyDown to decide
    /// between normal and application cursor-key encoding. Reads
    /// `cursorKeyApplication` from `latestSnapshot()` (nonisolated, lock-protected
    /// — safe from the AppKit responder chain). Centralising the closure here
    /// keeps `makeNSView` and `updateNSView` in lockstep as additional view
    /// callback hooks are added (e.g. T10's scroll handlers).
    private func makeCursorKeyModeProvider() -> () -> CursorKeyMode {
        let model = screenModel
        return { model.latestSnapshot().cursorKeyApplication ? .application : .normal }
    }

    private func clearColor(for rgba: RGBA) -> MTLClearColor {
        MTLClearColor(
            red:   Double(rgba.r) / 255.0,
            green: Double(rgba.g) / 255.0,
            blue:  Double(rgba.b) / 255.0,
            alpha: Double(rgba.a) / 255.0
        )
    }
}
