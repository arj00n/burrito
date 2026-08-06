#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

[[ stitchable ]] half4 Ripple(
    float2 position,
    SwiftUI::Layer layer,
    float2 origin,
    float time,
    float amplitude,
    float frequency,
    float decay,
    float speed
) {
    float distance = length(position - origin);
    float delay = distance / speed;
    time -= delay;
    time = max(0.0, time);
    
    float rippleAmount = amplitude * sin(frequency * time) * exp(-decay * time);
    float2 n = distance > 0.001 ? normalize(position - origin) : float2(0.0);
    float2 newPosition = position + rippleAmount * n;
    
    half4 color = layer.sample(newPosition);
    
    // Safety guard to prevent Divide By Zero crash
    if (amplitude > 0.001) {
        color.rgb += 0.3 * (rippleAmount / amplitude) * color.a;
    }
    
    return color;
}

[[ stitchable ]] half4 modernFluid(
    float2 position,
    SwiftUI::Layer layer,
    float t,
    float2 viewSize,
    float state
) {
    if (viewSize.x <= 0.1 || viewSize.y <= 0.1) {
        return layer.sample(position);
    }

    float2 uv = position / viewSize;
    float aspect = viewSize.x / max(viewSize.y, 1.0);
    float phase = t * 0.68;

    // Multiple offset flow fields keep the color movement fluid and visible.
    float2 flow = float2(
        sin(uv.y * 4.2 + phase * 0.50) + cos((uv.x + uv.y) * 2.7 - phase * 0.31),
        cos(uv.x * 3.8 - phase * 0.44) + sin((uv.x - uv.y) * 3.0 + phase * 0.27)
    ) * 0.024;
    float2 warpedUV = clamp(uv + flow, 0.0, 1.0);

    float2 p = warpedUV - 0.5;
    p.x *= aspect;

    float2 c1 = float2(-0.34 * aspect + sin(phase * 0.43) * 0.14, -0.13 + cos(phase * 0.37) * 0.18);
    float2 c2 = float2( 0.30 * aspect + cos(phase * 0.31) * 0.18,  0.17 + sin(phase * 0.47) * 0.16);
    float2 c3 = float2(sin(phase * 0.28 + 1.7) * 0.30 * aspect, cos(phase * 0.35 + 0.8) * 0.27);
    float2 c4 = float2(cos(phase * 0.24 + 2.4) * 0.38 * aspect, sin(phase * 0.33 + 2.1) * 0.24);

    float f1 = exp(-dot(p - c1, p - c1) * 3.7) * (0.78 + 0.22 * sin(phase * 0.62));
    float f2 = exp(-dot(p - c2, p - c2) * 4.1) * (0.80 + 0.20 * sin(phase * 0.55 + 1.8));
    float f3 = exp(-dot(p - c3, p - c3) * 4.6) * (0.76 + 0.24 * sin(phase * 0.49 + 3.4));
    float f4 = exp(-dot(p - c4, p - c4) * 5.0) * (0.80 + 0.20 * sin(phase * 0.58 + 4.7));

    float3 green = float3(0.10, 0.82, 0.40);
    float3 aqua = float3(0.06, 0.72, 0.58);
    float3 violet = float3(0.06, 0.57, 0.86);
    float3 rose = float3(0.16, 0.36, 0.96);

    if (state > 1.5) {
        green = float3(0.08, 0.68, 0.38);
        aqua = float3(0.06, 0.62, 0.62);
        violet = float3(0.10, 0.42, 0.90);
        rose = float3(0.20, 0.32, 0.88);
    } else if (state > 0.5) {
        green = float3(0.12, 0.92, 0.46);
        aqua = float3(0.08, 0.82, 0.66);
        violet = float3(0.08, 0.62, 0.92);
        rose = float3(0.16, 0.42, 0.98);
    }

    float field = max(max(f1, f2), max(f3, f4));
    float3 fluidColor = (green * f1 + aqua * f2 + violet * f3 + rose * f4)
        / max(f1 + f2 + f3 + f4, 0.001);

    float shimmerLine = abs(fract((warpedUV.x + warpedUV.y * 0.72) * 0.82 - phase * 0.075) - 0.5);
    float shimmer = pow(saturate(1.0 - shimmerLine * 1.8), 4.5);

    half4 base = layer.sample(warpedUV * viewSize);
    float colorAmount = saturate(0.16 + field * 0.31 + shimmer * 0.07);
    base.rgb = mix(base.rgb, half3(fluidColor), half(colorAmount));
    base.rgb += half3(shimmer * 0.045);
    base.a = max(base.a, half(0.14 + field * 0.22));

    return base;
}
