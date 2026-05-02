//
//  RenderCoordinator.swift
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

import AppKit
import MetalKit
import TermCore

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

    private(set) var device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let glyphPipelineState: MTLRenderPipelineState
    private let overlayPipelineState: MTLRenderPipelineState
    private let regularAtlas: GlyphAtlas
    private let boldAtlas: GlyphAtlas
    private let italicAtlas: GlyphAtlas
    private let boldItalicAtlas: GlyphAtlas
    private let screenModel: ScreenModel
    private let settings: AppSettings

    /// Last bell count we saw on a snapshot. When the snapshot's bellCount
    /// exceeds this AND the rate limiter allows, we play the system beep
    /// and update.
    private var lastSeenBellCount: UInt64 = 0

    /// Wall-clock timestamp of the most recent NSSound.beep() call. Bells
    /// arriving within `bellMinInterval` seconds of the last beep collapse
    /// silently — protects against runaway BEL spam (e.g. `yes $'\a'` or a
    /// program looping on permission errors with bells).
    private var lastBeepAt: TimeInterval = 0

    /// 200 ms minimum between successive beeps; loosely matches xterm's BEL
    /// rate-limit heuristic and absorbs runaway BEL spam without losing the
    /// signal that a bell event happened (lastSeenBellCount still advances).
    private static let bellMinInterval: TimeInterval = 0.2

    /// Per-vertex layout constants for the glyph and overlay pipelines.
    /// Static so private helpers (e.g. `drawOverlayPass`) can read them
    /// without per-call parameter plumbing.
    private static let floatsPerCellVertex = 12
    private static let floatsPerOverlayVertex = 8
    private static let verticesPerCell = 6

    /// Cached 256-color palette derived from `settings.palette`. Recomputed only
    /// when the palette identity changes (cheap object-equality check).
    ///
    /// Stored as `ContiguousArray<RGBA>` rather than `InlineArray<256, RGBA>`
    /// because the deployment target is macOS 15 and `InlineArray` (SE-0453)
    /// requires macOS 26. See `TerminalPalette` and `ColorProjection` for the
    /// matching note.
    private var derivedPalette256: ContiguousArray<RGBA>
    private var palette256Source: TerminalPalette

    init(screenModel: ScreenModel, settings: AppSettings) {
        let device = Self.makeDevice()
        let commandQueue = Self.makeCommandQueue(device: device)
        let library = Self.makeLibrary(device: device)

        self.device = device
        self.commandQueue = commandQueue
        self.regularAtlas    = GlyphAtlas(device: device, variant: .regular)
        self.boldAtlas       = GlyphAtlas(device: device, variant: .bold)
        self.italicAtlas     = GlyphAtlas(device: device, variant: .italic)
        self.boldItalicAtlas = GlyphAtlas(device: device, variant: .boldItalic)
        self.screenModel = screenModel
        self.settings = settings
        self.palette256Source = settings.palette
        self.derivedPalette256 = ColorProjection.derivePalette256(from: settings.palette)
        self.glyphPipelineState = Self.makeGlyphPipelineState(device: device, library: library)
        self.overlayPipelineState = Self.makeOverlayPipelineState(device: device, library: library)

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

        // -- Bell observer -------------------------------------------------------
        if snapshot.bellCount > lastSeenBellCount {
            // Always advance lastSeenBellCount so we don't backlog beeps when
            // multiple BELs arrive between draw frames.
            lastSeenBellCount = snapshot.bellCount
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastBeepAt > Self.bellMinInterval {
                lastBeepAt = now
                NSSound.beep()
            }
        }

        // -- Build glyph vertex data ---------------------------------------------
        // Each cell produces 2 triangles (6 vertices). Each vertex is 12 floats:
        //   float2 position + float2 texCoord + float4 fgColor + float4 bgColor
        // = 48 bytes per vertex. Each cell is partitioned into regular, bold,
        // italic, or boldItalic batch so a single draw call can use one atlas at
        // a time. Underlines and strikethroughs are collected in their own buffers
        // for additional overlay-pipeline passes.
        let floatsPerCellVertex = Self.floatsPerCellVertex
        let floatsPerOverlayVertex = Self.floatsPerOverlayVertex
        let verticesPerCell = Self.verticesPerCell

        var regularVerts = [Float]()
        var boldVerts = [Float]()
        var italicVerts = [Float]()
        var boldItalicVerts = [Float]()
        var underlineVerts = [Float]()
        var strikethroughVerts = [Float]()
        regularVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
        boldVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
        italicVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
        boldItalicVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerCellVertex)
        underlineVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerOverlayVertex)
        strikethroughVerts.reserveCapacity(rows * cols * verticesPerCell * floatsPerOverlayVertex)

        for row in 0..<rows {
            for col in 0..<cols {
                let cell = snapshot[row, col]
                let variant = AttributeProjection.atlasVariant(for: cell.style.attributes)
                let atlas: GlyphAtlas
                switch variant {
                case .regular:    atlas = regularAtlas
                case .bold:       atlas = boldAtlas
                case .italic:     atlas = italicAtlas
                case .boldItalic: atlas = boldItalicAtlas
                }
                let uv = atlas.uvRect(for: cell.character)

                let resolvedFg = ColorProjection.resolve(
                    cell.style.foreground, role: .foreground,
                    depth: depth, palette: palette, derivedPalette256: p256
                ).simdNormalized
                let resolvedBg = ColorProjection.resolve(
                    cell.style.background, role: .background,
                    depth: depth, palette: palette, derivedPalette256: p256
                ).simdNormalized
                let (fg, bg) = AttributeProjection.project(
                    fg: resolvedFg,
                    bg: resolvedBg,
                    attributes: cell.style.attributes
                )

                let x0 = Float(col)     / Float(cols) * 2.0 - 1.0
                let x1 = Float(col + 1) / Float(cols) * 2.0 - 1.0
                let y0 = 1.0 - Float(row)     / Float(rows) * 2.0
                let y1 = 1.0 - Float(row + 1) / Float(rows) * 2.0

                switch variant {
                case .regular:
                    appendCellQuad(into: &regularVerts, x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
                case .bold:
                    appendCellQuad(into: &boldVerts,    x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
                case .italic:
                    appendCellQuad(into: &italicVerts,  x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
                case .boldItalic:
                    appendCellQuad(into: &boldItalicVerts, x0: x0, x1: x1, y0: y0, y1: y1, uv: uv, fg: fg, bg: bg)
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

                if cell.style.attributes.contains(.strikethrough) {
                    // Mid-height thin line.
                    let cellHeight = y0 - y1
                    let thickness = cellHeight * 0.08
                    let mid = (y0 + y1) * 0.5
                    let sy0 = mid + thickness * 0.5
                    let sy1 = mid - thickness * 0.5
                    appendOverlayQuad(into: &strikethroughVerts,
                                      x0: x0, x1: x1, y0: sy0, y1: sy1,
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

        if !italicVerts.isEmpty {
            let buf = device.makeBuffer(
                bytes: italicVerts,
                length: italicVerts.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            if let buf {
                renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
                renderEncoder.setFragmentTexture(italicAtlas.texture, index: 0)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: italicVerts.count / floatsPerCellVertex
                )
            }
        }

        if !boldItalicVerts.isEmpty {
            let buf = device.makeBuffer(
                bytes: boldItalicVerts,
                length: boldItalicVerts.count * MemoryLayout<Float>.size,
                options: .storageModeShared
            )
            if let buf {
                renderEncoder.setVertexBuffer(buf, offset: 0, index: 0)
                renderEncoder.setFragmentTexture(boldItalicAtlas.texture, index: 0)
                renderEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: boldItalicVerts.count / floatsPerCellVertex
                )
            }
        }

        // -- Underline + strikethrough passes (overlay pipeline) -----------------
        // Both share the same overlay pipeline; only the y-geometry differs.
        // The pipeline state is set once outside the helper.
        if !underlineVerts.isEmpty || !strikethroughVerts.isEmpty {
            renderEncoder.setRenderPipelineState(overlayPipelineState)
            drawOverlayPass(verts: underlineVerts, into: renderEncoder)
            drawOverlayPass(verts: strikethroughVerts, into: renderEncoder)
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

    // MARK: - Init helpers

    private static func makeDevice() -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("RenderCoordinator: Metal is not supported on this device")
        }
        return device
    }

    private static func makeCommandQueue(device: MTLDevice) -> MTLCommandQueue {
        guard let queue = device.makeCommandQueue() else {
            fatalError("RenderCoordinator: failed to create command queue")
        }
        return queue
    }

    private static func makeLibrary(device: MTLDevice) -> MTLLibrary {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("RenderCoordinator: failed to load default Metal library")
        }
        return library
    }

    /// Build the glyph pipeline state — atlas-textured cell quads with alpha
    /// blending so glyph alpha composites over the background.
    private static func makeGlyphPipelineState(device: MTLDevice,
                                               library: MTLLibrary) -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: "vertex_main"),
              let fragmentFunction = library.makeFunction(name: "fragment_main") else {
            fatalError("RenderCoordinator: missing shader functions vertex_main / fragment_main")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("RenderCoordinator: failed to create glyph pipeline state — \(error)")
        }
    }

    /// Build the overlay pipeline state used for cursor + underline passes.
    private static func makeOverlayPipelineState(device: MTLDevice,
                                                 library: MTLLibrary) -> MTLRenderPipelineState {
        guard let vertexFunction = library.makeFunction(name: "overlay_vertex"),
              let fragmentFunction = library.makeFunction(name: "overlay_fragment") else {
            fatalError("RenderCoordinator: missing shader functions overlay_vertex / overlay_fragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .sourceAlpha
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("RenderCoordinator: failed to create overlay pipeline state — \(error)")
        }
    }

    // MARK: - Vertex append helpers

    /// Encode one overlay-pipeline draw call from a vertex array. Caller is
    /// responsible for setting `overlayPipelineState` on the encoder once;
    /// this helper is a no-op when `verts` is empty so callers can issue
    /// underline + strikethrough back-to-back without per-array guards.
    private func drawOverlayPass(verts: [Float], into encoder: MTLRenderCommandEncoder) {
        guard !verts.isEmpty,
              let buf = device.makeBuffer(
                bytes: verts,
                length: verts.count * MemoryLayout<Float>.size,
                options: .storageModeShared)
        else { return }
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: verts.count / Self.floatsPerOverlayVertex
        )
    }

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
