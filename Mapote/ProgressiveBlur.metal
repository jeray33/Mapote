#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

inline half gaussian(half distance, half sigma) {
    const half gaussianExponent = -(distance * distance) / (2.0h * sigma * sigma);
    return (1.0h / (2.0h * M_PI_H * sigma * sigma)) * exp(gaussianExponent);
}

half4 gaussianBlur1D(float2 position, SwiftUI::Layer layer, half radius, half2 axisMultiplier, half maxSamples) {
    const half interval = max(1.0h, radius / maxSamples);
    const half weight = gaussian(0.0h, radius / 2.0h);
    half4 weightedColorSum = layer.sample(position) * weight;
    half totalWeight = weight;

    if (interval <= radius) {
        for (half distance = interval; distance <= radius; distance += interval) {
            const half2 offsetDistance = axisMultiplier * distance;
            const half sampleWeight = gaussian(distance, radius / 2.0h);
            totalWeight += sampleWeight * 2.0h;

            weightedColorSum += layer.sample(float2(half2(position) + offsetDistance)) * sampleWeight;
            weightedColorSum += layer.sample(float2(half2(position) - offsetDistance)) * sampleWeight;
        }
    }

    return weightedColorSum / totalWeight;
}

[[ stitchable ]] half4 progressiveTopBlur(
    float2 position,
    SwiftUI::Layer layer,
    float4 boundingRect,
    float radius,
    float maxSamples,
    float fadeHeight,
    float vertical
) {
    const float y = position.y - boundingRect.y;
    const float safeFadeHeight = max(fadeHeight, 1.0);
    const half strength = half(clamp(1.0 - (y / safeFadeHeight), 0.0, 1.0));
    const half pixelRadius = strength * half(radius);

    if (pixelRadius >= 1.0h) {
        const half2 axisMultiplier = vertical == 0.0 ? half2(1, 0) : half2(0, 1);
        return gaussianBlur1D(position, layer, pixelRadius, axisMultiplier, half(maxSamples));
    }

    return layer.sample(position);
}
