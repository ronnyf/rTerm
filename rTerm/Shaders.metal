//
//  Shaders.metal
//  rTerm
//
//  Created by Ronny F on 6/19/24.
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

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared Types

/// Per-vertex glyph cell input. The Swift side mirrors this layout exactly:
/// 12 floats per vertex (48 bytes), naturally aligned to 16 bytes by Metal.
///
///   position : clip-space xy (2 floats)
///   texCoord : UV into glyph atlas (2 floats)
///   fgColor  : foreground RGBA, normalized 0..1 (4 floats)
///   bgColor  : background RGBA, normalized 0..1 (4 floats)
struct VertexIn {
    float2 position;
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
};

/// Per-vertex layout for the cursor + underline pipelines: position only, plus
/// a flat color carried in the vertex stream so we can color overlays without
/// extra uniform buffers.
///
///   position : clip-space xy (2 floats)
///   _pad     : 2 floats unused (keeps the struct float4-aligned for clarity)
///   color    : RGBA normalized (4 floats)
struct OverlayVertexIn {
    float2 position;
    float2 _pad;
    float4 color;
};

struct OverlayVertexOut {
    float4 position [[position]];
    float4 color;
};

// MARK: - Glyph Vertex / Fragment

vertex VertexOut vertex_main(const device VertexIn* vertices [[buffer(0)]],
                             uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    out.fgColor  = vertices[vid].fgColor;
    out.bgColor  = vertices[vid].bgColor;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> glyphAtlas [[texture(0)]]) {
    constexpr sampler texSampler(mag_filter::linear,
                                 min_filter::linear);
    float glyphAlpha = glyphAtlas.sample(texSampler, in.texCoord).r;

    // Composite glyph fg over solid bg per the plan:
    //   rgb = mix(bg.rgb, fg.rgb, glyphAlpha)
    //   a   = max(bg.a, glyphAlpha)
    float3 rgb = mix(in.bgColor.rgb, in.fgColor.rgb, glyphAlpha);
    float  a   = max(in.bgColor.a, glyphAlpha);
    return float4(rgb, a);
}

// MARK: - Cursor / Underline (Overlay)

vertex OverlayVertexOut overlay_vertex(const device OverlayVertexIn* vertices [[buffer(0)]],
                                       uint vid [[vertex_id]]) {
    OverlayVertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.color    = vertices[vid].color;
    return out;
}

fragment float4 overlay_fragment(OverlayVertexOut in [[stage_in]]) {
    return in.color;
}

// MARK: - Cursor (legacy entry point — kept for compatibility)

fragment float4 cursor_fragment(OverlayVertexOut in [[stage_in]]) {
    // Cursor draws as a translucent overlay using the supplied color.
    return float4(in.color.rgb, in.color.a * 0.7);
}
