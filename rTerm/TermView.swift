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
import SwiftUI
import TermCore

// MARK: - TerminalMTKView

/// An `MTKView` subclass that accepts first-responder status and forwards
/// keyboard input as raw `Data` through a closure.
final class TerminalMTKView: MTKView {

    /// Called with the encoded byte sequence for each key-down event.
    var onKeyInput: ((Data) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let encoder = KeyEncoder()
        if let data = encoder.encode(event) {
            onKeyInput?(data)
        }
        // Swallow all key events — do not call super.
    }
}

// MARK: - RenderCoordinator

/// Holds Metal state and renders the terminal grid each frame.
///
/// The coordinator reads from `ScreenModel.latestSnapshot()` (a `nonisolated`,
/// lock-protected accessor) on the render thread without `await`.
final class RenderCoordinator: NSObject, MTKViewDelegate {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState
    let cursorPipelineState: MTLRenderPipelineState
    let glyphAtlas: GlyphAtlas
    let screenModel: ScreenModel

    init(screenModel: ScreenModel) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("RenderCoordinator: Metal is not supported on this device")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("RenderCoordinator: failed to create command queue")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.glyphAtlas = GlyphAtlas(device: device)
        self.screenModel = screenModel

        // -- Glyph pipeline state ------------------------------------------------
        guard let library = device.makeDefaultLibrary() else {
            fatalError("RenderCoordinator: failed to load default Metal library")
        }
        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            fatalError("RenderCoordinator: missing shader functions vertex_main / fragment_main")
        }

        let glyphDescriptor = MTLRenderPipelineDescriptor()
        glyphDescriptor.vertexFunction = vertexFunction
        glyphDescriptor.fragmentFunction = fragmentFunction
        glyphDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        // Alpha blending so glyph alpha composites over the background.
        let glyphAttachment = glyphDescriptor.colorAttachments[0]!
        glyphAttachment.isBlendingEnabled = true
        glyphAttachment.sourceRGBBlendFactor = .sourceAlpha
        glyphAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        glyphAttachment.sourceAlphaBlendFactor = .sourceAlpha
        glyphAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: glyphDescriptor)
        } catch {
            fatalError("RenderCoordinator: failed to create glyph pipeline state — \(error)")
        }

        // -- Cursor pipeline state -----------------------------------------------
        guard let cursorFragment = library.makeFunction(name: "cursor_fragment") else {
            fatalError("RenderCoordinator: missing shader function cursor_fragment")
        }

        let cursorDescriptor = MTLRenderPipelineDescriptor()
        cursorDescriptor.vertexFunction = vertexFunction
        cursorDescriptor.fragmentFunction = cursorFragment
        cursorDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let cursorAttachment = cursorDescriptor.colorAttachments[0]!
        cursorAttachment.isBlendingEnabled = true
        cursorAttachment.sourceRGBBlendFactor = .sourceAlpha
        cursorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        cursorAttachment.sourceAlphaBlendFactor = .sourceAlpha
        cursorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.cursorPipelineState = try device.makeRenderPipelineState(descriptor: cursorDescriptor)
        } catch {
            fatalError("RenderCoordinator: failed to create cursor pipeline state — \(error)")
        }

        super.init()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // No-op for now.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let renderPassDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 1
        )

        // Read latest screen state (nonisolated, no await).
        let snapshot = screenModel.latestSnapshot()
        let rows = snapshot.rows
        let cols = snapshot.cols

        // -- Build glyph vertex data ---------------------------------------------
        // Each cell produces 2 triangles (6 vertices). Each vertex is 16 bytes:
        //   float2 position (clip space) + float2 texCoord = 4 floats = 16 bytes.
        // Total: rows * cols * 6 * 4 floats.
        let verticesPerCell = 6
        let floatsPerVertex = 4
        let totalCells = rows * cols
        let totalVertices = totalCells * verticesPerCell
        let totalFloats = totalVertices * floatsPerVertex

        var vertexData = [Float]()
        vertexData.reserveCapacity(totalFloats)

        for row in 0..<rows {
            for col in 0..<cols {
                let cell = snapshot[row, col]
                let uv = glyphAtlas.uvRect(for: cell.character)

                let x0 = Float(col) / Float(cols) * 2.0 - 1.0
                let x1 = Float(col + 1) / Float(cols) * 2.0 - 1.0
                let y0 = 1.0 - Float(row) / Float(rows) * 2.0
                let y1 = 1.0 - Float(row + 1) / Float(rows) * 2.0

                // Triangle 1: top-left, top-right, bottom-left
                vertexData.append(x0); vertexData.append(y0); vertexData.append(uv.u0); vertexData.append(uv.v0)
                vertexData.append(x1); vertexData.append(y0); vertexData.append(uv.u1); vertexData.append(uv.v0)
                vertexData.append(x0); vertexData.append(y1); vertexData.append(uv.u0); vertexData.append(uv.v1)

                // Triangle 2: top-right, bottom-right, bottom-left
                vertexData.append(x1); vertexData.append(y0); vertexData.append(uv.u1); vertexData.append(uv.v0)
                vertexData.append(x1); vertexData.append(y1); vertexData.append(uv.u1); vertexData.append(uv.v1)
                vertexData.append(x0); vertexData.append(y1); vertexData.append(uv.u0); vertexData.append(uv.v1)
            }
        }

        let glyphBufferSize = vertexData.count * MemoryLayout<Float>.size
        guard let glyphBuffer = device.makeBuffer(
            bytes: vertexData,
            length: glyphBufferSize,
            options: .storageModeShared
        ) else {
            return
        }

        // -- Encode glyph draw call ----------------------------------------------
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            return
        }

        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setVertexBuffer(glyphBuffer, offset: 0, index: 0)
        renderEncoder.setFragmentTexture(glyphAtlas.texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: totalVertices)

        // -- Cursor quad ---------------------------------------------------------
        let cursorRow = snapshot.cursor.row
        let cursorCol = snapshot.cursor.col

        let cx0 = Float(cursorCol) / Float(cols) * 2.0 - 1.0
        let cx1 = Float(cursorCol + 1) / Float(cols) * 2.0 - 1.0
        let cy0 = 1.0 - Float(cursorRow) / Float(rows) * 2.0
        let cy1 = 1.0 - Float(cursorRow + 1) / Float(rows) * 2.0

        // UV coords are unused by cursor_fragment but the vertex layout requires them.
        let cursorVertices: [Float] = [
            cx0, cy0, 0, 0,
            cx1, cy0, 0, 0,
            cx0, cy1, 0, 0,
            cx1, cy0, 0, 0,
            cx1, cy1, 0, 0,
            cx0, cy1, 0, 0,
        ]

        // 6 vertices * 16 bytes = 96 bytes — well under the 4 KB setVertexBytes limit.
        renderEncoder.setRenderPipelineState(cursorPipelineState)
        renderEncoder.setVertexBytes(
            cursorVertices,
            length: cursorVertices.count * MemoryLayout<Float>.size,
            index: 0
        )
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - TermView

/// SwiftUI bridge that presents a Metal-backed terminal view with keyboard input.
struct TermView: NSViewRepresentable {

    let screenModel: ScreenModel
    var onInput: ((Data) -> Void)?

    func makeCoordinator() -> RenderCoordinator {
        RenderCoordinator(screenModel: screenModel)
    }

    func makeNSView(context: Context) -> TerminalMTKView {
        let coordinator = context.coordinator
        let view = TerminalMTKView(frame: .zero, device: coordinator.device)
        view.delegate = coordinator
        view.preferredFramesPerSecond = 60
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.onKeyInput = onInput
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.onKeyInput = onInput
    }
}
