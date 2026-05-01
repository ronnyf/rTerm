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
final class TerminalMTKView: MTKView {

    private let log = Logger(subsystem: "rTerm", category: "TerminalMTKView")

    /// Called with the encoded byte sequence for each key-down event.
    var onKeyInput: ((Data) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let encoder = KeyEncoder()
        if let data = encoder.encode(event) {
            log.debug("keyDown: keyCode=\(event.keyCode), encoded \(data.count) bytes")
            onKeyInput?(data)
        } else {
            log.debug("keyDown: keyCode=\(event.keyCode), unhandled")
        }
        // Swallow all key events — do not call super.
    }
}

// MARK: - TermView

/// SwiftUI bridge that presents a Metal-backed terminal view with keyboard input.
struct TermView: NSViewRepresentable {

    let screenModel: ScreenModel
    let settings: AppSettings
    var onInput: ((Data) -> Void)?

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
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.onKeyInput = onInput
        nsView.clearColor = clearColor(for: settings.palette.defaultBackground)
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
