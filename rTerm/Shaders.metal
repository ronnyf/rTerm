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

struct VertexIn {
    float2 position;   // clip-space x,y
    float2 texCoord;   // UV into glyph atlas
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// MARK: - Vertex Shader

vertex VertexOut vertex_main(const device VertexIn* vertices [[buffer(0)]],
                             uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texCoord = vertices[vid].texCoord;
    return out;
}

// MARK: - Fragment Shader (Glyph)

fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> glyphAtlas [[texture(0)]]) {
    constexpr sampler texSampler(mag_filter::linear,
                                 min_filter::linear);
    float alpha = glyphAtlas.sample(texSampler, in.texCoord).r;
    return float4(1.0, 1.0, 1.0, alpha);
}

// MARK: - Fragment Shader (Cursor)

fragment float4 cursor_fragment(VertexOut in [[stage_in]]) {
    return float4(1.0, 1.0, 1.0, 0.7);
}
