import UIKit

/// Telegram's typing dots (ChatTypingActivityIndicatorNode): three dots that swell in turn, from 3 to 4.5 pt across
/// and back in 0.7 s, more opaque as they grow, in a 24 × 16 box. Telegram draws them again on the CPU every frame,
/// which is nothing for the seconds someone types and a lot for the minutes an agent works (8 % of a core); here the
/// dots are drawn once and Core Animation runs the same curves, at a frame rate low enough for dots this small.
final class TypingDotsLayer: CALayer {
    static let size = CGSize(width: 24.0, height: 16.0)

    private static let duration: CFTimeInterval = 0.7
    private static let minDiameter: CGFloat = 3.0
    private static let maxDiameter: CGFloat = 4.5
    private static let minAlpha: Float = 0.75

    private let dots: [CALayer] = (0 ..< 3).map { _ in CALayer() }

    var color: UIColor = .white {
        didSet {
            self.updateColor()
        }
    }

    override init() {
        super.init()
        for (index, dot) in self.dots.enumerated() {
            let diameter = TypingDotsLayer.maxDiameter
            dot.bounds = CGRect(origin: .zero, size: CGSize(width: diameter, height: diameter))
            dot.cornerRadius = diameter / 2.0
            // As Telegram's: 6 pt in, 9 pt down, 5.5 pt apart.
            dot.position = CGPoint(x: 6.0 + CGFloat(index) * 5.5, y: 9.0)
            self.addSublayer(dot)
        }
        self.updateColor()
        self.addAnimations()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateColor() {
        for dot in self.dots {
            dot.backgroundColor = self.color.cgColor
        }
    }

    /// Telegram's curve over the cycle: the diameter grows to its largest by 0.4, shrinks back by 0.8 and rests; the
    /// alpha is 0.75 at the smallest and full from 4 pt up. The first dot is 0.4 of a cycle ahead, the second 0.2.
    private func addAnimations() {
        let small = TypingDotsLayer.minDiameter / TypingDotsLayer.maxDiameter
        // Where the diameter passes 4 pt, going up and coming down.
        let fullUp = 0.4 * (4.0 - 3.0) / 1.5
        let fullDown = 0.4 + 0.4 * (4.5 - 4.0) / 1.5
        for (index, dot) in self.dots.enumerated() {
            let ahead = [0.4, 0.2, 0.0][index]

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [small, 1.0, small, small]
            scale.keyTimes = [0.0, 0.4, 0.8, 1.0]

            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            opacity.values = [TypingDotsLayer.minAlpha, 1.0, 1.0, TypingDotsLayer.minAlpha, TypingDotsLayer.minAlpha]
            opacity.keyTimes = [0.0, NSNumber(value: fullUp), NSNumber(value: fullDown), 0.8, 1.0]

            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = TypingDotsLayer.duration
            group.repeatCount = .infinity
            group.timeOffset = ahead * TypingDotsLayer.duration
            group.isRemovedOnCompletion = false
            group.preferredFrameRateRange = CAFrameRateRange(minimum: 20.0, maximum: 60.0, preferred: 30.0)
            dot.add(group, forKey: "typing")
            dot.transform = CATransform3DMakeScale(small, small, 1.0)
            dot.opacity = TypingDotsLayer.minAlpha
        }
    }
}
