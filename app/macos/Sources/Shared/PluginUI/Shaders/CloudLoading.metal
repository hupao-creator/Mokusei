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

// Each light: center.xy, radius.xy, energy. CPU-side motion retains
// the original Double-precision, seeded timeline; the GPU shades the light field.
[[ stitchable ]] half4 cloudLoading(float2 position,
                                   device const float *lights, int count,
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
    // colorArray supplies premultiplied colors in the destination's working
    // space, including the linear Canvas. No manual sRGB conversion is needed.
    return half4(field);
}
