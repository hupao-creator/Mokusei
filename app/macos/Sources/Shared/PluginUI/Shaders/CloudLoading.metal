#include <metal_stdlib>
using namespace metal;

// Matches the original Canvas radial-gradient stops in a linear working space.
static float cloudFalloff(float radius) {
    if (radius >= 1.0f) return 0.0f;
    if (radius < 0.22f) return mix(1.0f, 0.82f, radius / 0.22f);
    if (radius < 0.52f) return mix(0.82f, 0.36f, (radius - 0.22f) / 0.30f);
    if (radius < 0.80f) return mix(0.36f, 0.08f, (radius - 0.52f) / 0.28f);
    return mix(0.08f, 0.0f, (radius - 0.80f) / 0.20f);
}

// Both presentation paths use the same linear, premultiplied field. Each light
// is center.xy, radius.xy, energy; seeded motion remains on the CPU in Double.
static half4 cloudField(float2 position, device const float *lights, int count,
                        device const half4 *colors, int colorCount) {
    float4 field = 0.0f;
    for (int index = 0; index < colorCount && index * 5 + 4 < count; ++index) {
        int offset = index * 5;
        float2 center = float2(lights[offset], lights[offset + 1]);
        float2 radius = float2(lights[offset + 2], lights[offset + 3]);
        if (any(radius <= 0.0f)) continue;
        float4 color = float4(colors[index]);
        if (color.a <= 0.0f) continue;
        float alpha = clamp(lights[offset + 4] * color.a, 0.0f, 1.0f)
            * cloudFalloff(length((position - center) / radius));
        field += float4(color.rgb / color.a * alpha, alpha);
    }
    field = clamp(field, 0.0f, 1.0f);
    return half4(field);
}

[[ stitchable ]] half4 cloudLoading(float2 position,
                                   device const float *lights, int count,
                                   device const half4 *colors, int colorCount) {
    // colorArray supplies premultiplied colors in the linear Canvas's space.
    return cloudField(position, lights, count, colors, colorCount);
}

// The Overview native path supplies the same premultiplied linear half colors
// and converts drawable pixel centers back into the field's logical points.
struct NativeCloudUniforms {
    float2 pointsPerPixel;
    uint geometryCount;
    uint colorCount;
};

vertex float4 nativeCloudVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = {float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)};
    return float4(positions[vertexID], 0.0, 1.0);
}

fragment half4 nativeCloudFragment(float4 position [[position]],
                                   constant NativeCloudUniforms &uniforms [[buffer(0)]],
                                   device const float *lights [[buffer(1)]],
                                   device const half4 *colors [[buffer(2)]]) {
    return cloudField(position.xy * uniforms.pointsPerPixel, lights,
                      int(uniforms.geometryCount), colors, int(uniforms.colorCount));
}
