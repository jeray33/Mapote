import SwiftUI

extension View {
    func progressiveTopBlur(
        radius: CGFloat,
        fadeHeight: CGFloat,
        maxSampleCount: Int = 24,
        verticalPassFirst: Bool = false,
        isEnabled: Bool = true
    ) -> some View {
        if #available(iOS 17.0, *) {
            return AnyView(
                self.visualEffect { content, _ in
                    content.progressiveTopBlur(
                        radius: radius,
                        fadeHeight: fadeHeight,
                        maxSampleCount: maxSampleCount,
                        verticalPassFirst: verticalPassFirst,
                        isEnabled: isEnabled
                    )
                }
            )
        } else {
            return AnyView(self)
        }
    }
}

@available(iOS 17.0, *)
extension VisualEffect {
    func progressiveTopBlur(
        radius: CGFloat,
        fadeHeight: CGFloat,
        maxSampleCount: Int = 24,
        verticalPassFirst: Bool = false,
        isEnabled: Bool = true
    ) -> some VisualEffect {
        self.layerEffect(
            ShaderLibrary.progressiveTopBlur(
                .boundingRect,
                .float(radius),
                .float(CGFloat(maxSampleCount)),
                .float(fadeHeight),
                .float(verticalPassFirst ? 1 : 0)
            ),
            maxSampleOffset: CGSize(width: radius, height: radius),
            isEnabled: isEnabled
        )
        .layerEffect(
            ShaderLibrary.progressiveTopBlur(
                .boundingRect,
                .float(radius),
                .float(CGFloat(maxSampleCount)),
                .float(fadeHeight),
                .float(verticalPassFirst ? 0 : 1)
            ),
            maxSampleOffset: CGSize(width: radius, height: radius),
            isEnabled: isEnabled
        )
    }
}
