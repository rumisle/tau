import UIKit
import AsyncDisplayKit
import Display

/// What the transcript shows where the answer will be, while the agent works and has written nothing yet: a τ that a
/// pen keeps tracing over its faint outline, from the bar to the end of the stem, then lifting off the same way.
final class ChatWaitingNode: ASDisplayNode {
    static let size = CGSize(width: 24.0, height: 24.0)

    private let trackLayer = CAShapeLayer()
    private let strokeLayer = CAShapeLayer()
    private var color: UIColor?

    override init() {
        super.init()
        self.isUserInteractionEnabled = false
        self.isAccessibilityElement = true
        self.accessibilityLabel = "Working"
        self.accessibilityIdentifier = "waitingTau"
        for layer in [self.trackLayer, self.strokeLayer] {
            layer.path = ChatWaitingNode.tauPath()
            layer.fillColor = nil
            layer.lineWidth = 2.2
            layer.lineCap = .round
            layer.lineJoin = .round
            self.layer.addSublayer(layer)
        }
        self.strokeLayer.strokeEnd = 0.0
    }

    /// A lowercase tau in 24 pt: the bar with its left end hooked down, and the stem curling to the right at its foot.
    private static func tauPath() -> CGPath {
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 3.2, y: 10.0))
        path.addQuadCurve(to: CGPoint(x: 7.0, y: 6.6), controlPoint: CGPoint(x: 3.9, y: 6.7))
        path.addLine(to: CGPoint(x: 20.6, y: 6.6))
        path.move(to: CGPoint(x: 12.6, y: 6.6))
        path.addLine(to: CGPoint(x: 11.9, y: 15.2))
        path.addQuadCurve(to: CGPoint(x: 16.6, y: 19.4), controlPoint: CGPoint(x: 11.5, y: 19.7))
        return path.cgPath
    }

    func update(color: UIColor) {
        guard color != self.color else {
            return
        }
        self.color = color
        self.trackLayer.strokeColor = color.withAlphaComponent(0.18).cgColor
        self.strokeLayer.strokeColor = color.cgColor
    }

    override func layout() {
        super.layout()
        let frame = CGRect(origin: CGPoint(), size: ChatWaitingNode.size)
        self.trackLayer.frame = frame
        self.strokeLayer.frame = frame
    }

    override func didEnterHierarchy() {
        super.didEnterHierarchy()
        self.startAnimating()
    }

    override func didExitHierarchy() {
        super.didExitHierarchy()
        self.strokeLayer.removeAllAnimations()
        self.layer.removeAllAnimations()
    }

    /// Drawn in 0.8 s, held, lifted off from its start in 0.7 s, and again: a 1.9 s cycle on Telegram's ease-in-out.
    private func startAnimating() {
        guard self.strokeLayer.animation(forKey: "trace") == nil else {
            return
        }
        let timing = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.25, 1.0)
        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0.0
        draw.toValue = 1.0
        draw.duration = 0.8
        draw.timingFunction = timing
        draw.fillMode = .forwards
        let lift = CABasicAnimation(keyPath: "strokeStart")
        lift.fromValue = 0.0
        lift.toValue = 1.0
        lift.beginTime = 1.05
        lift.duration = 0.7
        lift.timingFunction = timing
        lift.fillMode = .both
        let end = CABasicAnimation(keyPath: "strokeEnd")
        end.fromValue = 1.0
        end.toValue = 1.0
        end.beginTime = 0.8
        end.duration = 1.1
        let group = CAAnimationGroup()
        group.animations = [draw, end, lift]
        group.duration = 1.9
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        self.strokeLayer.add(group, forKey: "trace")

        // The whole glyph comes in with a small spring, as Telegram's typing indicators do.
        self.layer.animateSpring(from: 0.6 as NSNumber, to: 1.0 as NSNumber, keyPath: "transform.scale", duration: 0.5)
    }
}
