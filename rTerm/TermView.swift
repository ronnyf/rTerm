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

// MARK: - RenderCoordinator

/// Holds Metal state and renders the terminal grid each frame.
///
/// The coordinator reads from `ScreenModel.latestSnapshot()` (a `nonisolated`,
/// lock-protected accessor) on the render thread without `await`.
///
/// Marked `@MainActor` explicitly even though `rTerm` defaults to MainActor
/// isolation — `MTKViewDelegate` itself is not isolated in the SDK, so being
/// explicit at the type level documents the intent. Under
/// `SWIFT_APPROACHABLE_CONCURRENCY = YES` the compiler accepts a `@MainActor`
/// class conforming to the nonisolated `MTKViewDelegate` protocol.
@MainActor
final class RenderCoordinator: NSObject, MTKViewDelegate {

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let glyphPipelineState: MTLRenderPipelineState
    let overlayPipelineState: MTLRenderPipelineState
    let regularAtlas: GlyphAtlas
    let boldAtlas: GlyphAtlas
    let screenModel: ScreenModel
    let settings: AppSettings

    /// Cached 256-color palette derived from `settings.palette`. Recomputed only
    /// when the palette identity changes (cheap object-equality check).
    private var derivedPalette256: InlineArray<256, RGBA>
    private var palette256Source: TerminalPalette

    init(screenModel: ScreenModel, settings: AppSettings) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("RenderCoordinator: Metal is not supported on this device")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("RenderCoordinator: failed to create command queue")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.regularAtlas = GlyphAtlas(device: device, variant: .regular)
        self.boldAtlas = GlyphAtlas(device: device, variant: .bold)
        self.screenModel = screenModel
        self.settings = settings
        self.palette256Source = settings.palette
        self.derivedPalette256 = ColorProjection.derivePalette256(from: settings.palette)

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
            self.glyphPipelineState = try device.makeRenderPipelineState(descriptor: glyphDescriptor)
        } catch {
            fatalError("RenderCoordinator: failed to create glyph pipeline state — \(error)")
        }

        // -- Overlay pipeline state (cursor + underline) -------------------------
        guard let overlayVertex = library.makeFunction(name: "overlay_vertex"),
              let overlayFragment = library.makeFunction(name: "overlay_fragment") else {
            fatalError("RenderCoordinator: missing shader functions overlay_vertex / overlay_fragment")
        }

        let overlayDescriptor = MTLRenderPipelineDescriptor()
        overlayDescriptor.vertexFunction = overlayVertex
        overlayDescriptor.fragmentFunction = overlayFragment
        overlayDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let overlayAttachment = overlayDescriptor.colorAttachments[0]!
        overlayAttachment.isBlendingEnabled = true
        overlayAttachment.sourceRGBBlendFactor = .sourceAlpha
        overlayAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        overlayAttachment.sourceAlphaBlendFactor = .sourceAlpha
        overlayAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            self.overlayPipelineState = try device.makeRenderPipelineState(descriptor: overlayDescriptor)
        } catch {
            fatalError("RenderCoordinator: failed to create overlay pipeline state — \(error)")
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

        // Refresh derived 256-color palette cache only on identity change.
        if palette256Source != settings.palette {
            palette256Source = settings.palette
            derivedPalette256 = ColorProjection.derivePalette256(from: settings.palette)
        }
        let palette = settings.palette
        let depth = settings.colorDepth
        let p256 = derivedPalette256

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red:   Double(palette.defaultBackground.r) / 255.0,
            green: Double(palette.defaultBackground.g) / 255.0,
            blue:  Double(palette.defaultBackground.b) / 255.0,
            alpha: Double(palette.defaultBackground.a) / 255.0
        )

        // Read latest screen state (nonisolated, no await).
        let snapshot = screenModel.latestSnapshot()
        let rows = snapshot.rows
        let cols = snapshot.cols

        // -- Build glyph vertex data ---------------------------------------------
        // Each cell produces 2 triangles (6 vertices). Each vertex is 12 floats:
        //   float2 position + float2 texCoord + float4 fgColor + float4 bgColor
        // = 48 bytes per vertex. Each cell is partitioned into a regular or bold
        // batch so a single draw call can use one atlas at a time. Underlines
        // are collected in their own buffer for a second overlay-pipeline pass.
        let floatsPerCellVertex = 12
        let floatsPerOverlayVertex = 8
        let verticesPerCell = 6

        var regularVerts = [Float]()
        var boldVerts = [Float]()
        var underlineVerts = [Float]()
        regularVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
        boldVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)

        for row in 0..<rows {
            for col in 0..<cols {
                let cell = snapshot[row, col]
                let isBold = cell.style.attributes.contains(.bold)
                let atlas = isBold ? boldAtlas : regularAtlas
                let uv = atlas.uvRect(for: cell.character)

                let fg = ColorProjection.resolve(
                    cell.style.foreground, role: .foreground,
                    depth: depth, palette: palette, derivedPalette256: p256
                ).simdNormalized
                let bg = ColorProjection.resolve(
                    cell.style.background, role: .background,
                    depth: depth, palette: palette, derivedPalette256: p256
                ).simdNormalized

                let x0 = Float(col)     / Float(cols) * 2.0 - 1.0
                let x1 = Float(col + 1) / Float(cols) * 2.0 - 1.0
                let y0 = 1.0 - Float(row)     / Float(rows) * 2.0
                let y1 = 1.0 - Float(row + 1) / Float(rows) * 2.0

                if isBold {
                    appendCellQuad(into: &boldVerts,
                                   x0: x0, x1: x1, y0: y0, y1: y1,
                                   uv: uv, fg: fg, bg: bg)
                } else {
                    appendCellQuad(into: &regularVerts,
                                   x0: x0, x1: x1, y0: y0, y1: y1,
                                   uv: uv, fg: fg, bg: bg)
                }

                if cell.style.attributes.contains(.underline) {
                    // Thin underline at ~10% of cell height, positioned just
                    // above the cell's bottom edge. In our clip-space mapping
                    // y0 (top of cell) > y1 (bottom of cell), so adding to y1
                    // moves upward inside the cell.
                    let cellHeight = y0 - y1
                    let thickness = cellHeight * 0.1
                    let uy1 = y1 + thickness * 0.4
                    let uy0 = uy1 + thickness
                    appendOverlayQuad(into: &underlineVerts,
                                      x0: x0, x1: x1, y0: uy0, y1: uy1,
                                      color: fg)
                }
            }
        }

        // -- Encode draw calls ---------------------------------------------------
        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(
            descriptor: renderPassDescriptor
        ) else {
            return
        }

        renderEncoder.setRenderPipelineState(glyphPipelineState)

        if !regularVerts.isEmpty {
            let buf = device.makeBuffer(
                bytes: regularVerts,
                length: regularVerts.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            if let buf {
                renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
                renderEncoder.setFragmentTexture(regularAtlas.texture, index: 0)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: regularVerts.count / floatsPerCellVertex
                )
            }
        }

        if !boldVerts.isEmpty {
            let buf = device.makeBuffer(
                bytes: boldVerts,
                length: boldVerts.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            if let buf {
                renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
                renderEncoder.setFragmentTexture(boldAtlas.texture, index: 0)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: boldVerts.count / floatsPerCellVertex
                )
            }
        }

        // -- Underline pass (overlay pipeline) -----------------------------------
        if !underlineVerts.isEmpty {
            renderEncoder.setRenderPipelineState(overlayPipelineState)
            // Underline buffers can be large; route through MTLBuffer rather than
            // setVertexBytes (which is capped at 4 KB).
            let buf = device.makeBuffer(
                bytes: underlineVerts,
                length: underlineVerts.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            if let buf {
                renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: underlineVerts.count / floatsPerOverlayVertex
                )
            }
        }

        // -- Cursor quad ---------------------------------------------------------
        if snapshot.cursorVisible {
            let cursorRow = snapshot.cursor.row
            let cursorCol = snapshot.cursor.col

            let cx0 = Float(cursorCol)     / Float(cols) * 2.0 - 1.0
            let cx1 = Float(cursorCol + 1) / Float(cols) * 2.0 - 1.0
            let cy0 = 1.0 - Float(cursorRow)     / Float(rows) * 2.0
            let cy1 = 1.0 - Float(cursorRow + 1) / Float(rows) * 2.0

            let cursorRGBA = palette.cursor.simdNormalized
            var cursorVerts = [Float]()
            cursorVerts.reserveCapacity(6 * 8)
            appendOverlayQuad(into: &cursorVerts,
                              x0: cx0, x1: cx1, y0: cy0, y1: cy1,
                              color: cursorRGBA)

            renderEncoder.setRenderPipelineState(overlayPipelineState)
            // 6 vertices * 32 bytes = 192 bytes — well under the 4 KB
            // setVertexBytes limit.
            renderEncoder.setVertexBytes(
                cursorVerts,
                length: cursorVerts.count * MemoryLayout<Float>.size,
                index: 0
            )
            renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        renderEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Vertex append helpers

    /// Append a 6-vertex glyph quad (two triangles) into the buffer.
    /// Each vertex: `[x, y, u, v, fg.x, fg.y, fg.z, fg.w, bg.x, bg.y, bg.z, bg.w]`.
    @inline(__always)
    private func appendCellQuad(into out: inout [Float],
                                x0: Float, x1: Float, y0: Float, y1: Float,
                                uv: (u0: Float, v0: Float, u1: Float, v1: Float),
                                fg: SIMD4<Float>, bg: SIMD4<Float>) {
        // Triangle 1: top-left, top-right, bottom-left
        appendVertex(into: &out, x: x0, y: y0, u: uv.u0, v: uv.v0, fg: fg, bg: bg)
        appendVertex(into: &out, x: x1, y: y0, u: uv.u1, v: uv.v0, fg: fg, bg: bg)
        appendVertex(into: &out, x: x0, y: y1, u: uv.u0, v: uv.v1, fg: fg, bg: bg)
        // Triangle 2: top-right, bottom-right, bottom-left
        appendVertex(into: &out, x: x1, y: y0, u: uv.u1, v: uv.v0, fg: fg, bg: bg)
        appendVertex(into: &out, x: x1, y: y1, u: uv.u1, v: uv.v1, fg: fg, bg: bg)
        appendVertex(into: &out, x: x0, y: y1, u: uv.u0, v: uv.v1, fg: fg, bg: bg)
    }

    @inline(__always)
    private func appendVertex(into out: inout [Float],
                              x: Float, y: Float, u: Float, v: Float,
                              fg: SIMD4<Float>, bg: SIMD4<Float>) {
        out.append(x);    out.append(y)
        out.append(u);    out.append(v)
        out.append(fg.x); out.append(fg.y); out.append(fg.z); out.append(fg.w)
        out.append(bg.x); out.append(bg.y); out.append(bg.z); out.append(bg.w)
    }

    /// Append a 6-vertex overlay quad (cursor / underline). Each vertex:
    /// `[x, y, _pad, _pad, color.x, color.y, color.z, color.w]`.
    @inline(__always)
    private func appendOverlayQuad(into out: inout [Float],
                                   x0: Float, x1: Float, y0: Float, y1: Float,
                                   color: SIMD4<Float>) {
        appendOverlayVertex(into: &out, x: x0, y: y0, color: color)
        appendOverlayVertex(into: &out, x: x1, y: y0, color: color)
        appendOverlayVertex(into: &out, x: x0, y: y1, color: color)
        appendOverlayVertex(into: &out, x: x1, y: y0, color: color)
        appendOverlayVertex(into: &out, x: x1, y: y1, color: color)
        appendOverlayVertex(into: &out, x: x0, y: y1, color: color)
    }

    @inline(__always)
    private func appendOverlayVertex(into out: inout [Float],
                                     x: Float, y: Float, color: SIMD4<Float>) {
        out.append(x);       out.append(y)
        out.append(0);       out.append(0)
        out.append(color.x); out.append(color.y); out.append(color.z); out.append(color.w)
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
        let bg = settings.palette.defaultBackground
        view.clearColor = MTLClearColor(
            red:   Double(bg.r) / 255.0,
            green: Double(bg.g) / 255.0,
            blue:  Double(bg.b) / 255.0,
            alpha: Double(bg.a) / 255.0
        )
        view.onKeyInput = onInput
        return view
    }

    func updateNSView(_ nsView: TerminalMTKView, context: Context) {
        nsView.onKeyInput = onInput
    }
}
