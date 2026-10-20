import UIKit
import Display
import ComponentFlow
import TelegramPresentationData

/// Telegram's input accessory panel (ChatInputMessageAccessoryPanel, iOS 26): inside the field's glass, an accent line,
/// a title, one line of text, and a close button. It shows the message being edited, or the first message queued for
/// the agent with its status: the clock while it is on its way, a check once the server holds it. Several queued
/// messages split the line into segments, as Telegram's pinned messages bar counts its messages.
final class InputAccessoryPanelView: UIView {
    enum Status: Equatable {
        case none
        case sending
        case queued
    }

    struct Content: Equatable {
        var id: String
        var title: String
        var text: String
        var status: Status
        var count: Int
    }

    private let lineContainer = UIView()
    private var segmentViews: [UIView] = []
    private let titleLabel = UILabel()
    private let textLabel = UILabel()
    private let statusView = MessageStatusView()
    private let closeButton = UIButton(type: .custom)
    private let closeIcon = UIImageView()
    private(set) var content: Content?
    private var accentColor: UIColor = .systemBlue
    var close: (() -> Void)?
    var tapped: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addSubview(self.lineContainer)
        self.addSubview(self.titleLabel)
        self.addSubview(self.statusView)
        self.addSubview(self.textLabel)
        self.addSubview(self.closeButton)
        self.closeButton.addSubview(self.closeIcon)
        self.closeIcon.isUserInteractionEnabled = false
        self.titleLabel.font = Font.medium(14.0)
        self.textLabel.font = Font.regular(14.0)
        self.textLabel.lineBreakMode = .byTruncatingTail
        self.closeIcon.image = generateImage(CGSize(width: 12.0, height: 12.0), contextGenerator: { size, context in
            context.clear(CGRect(origin: CGPoint(), size: size))
            context.setBlendMode(.copy)
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2.0)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: 1.0, y: 1.0))
            context.addLine(to: CGPoint(x: size.width - 1.0, y: size.height - 1.0))
            context.strokePath()
            context.move(to: CGPoint(x: size.width - 1.0, y: 1.0))
            context.addLine(to: CGPoint(x: 1.0, y: size.height - 1.0))
            context.strokePath()
        })?.withRenderingMode(.alwaysTemplate)
        self.closeButton.addTarget(self, action: #selector(self.closePressed), for: .touchUpInside)
        self.closeButton.accessibilityIdentifier = "accessoryClose"
        self.closeButton.accessibilityLabel = "Cancel"
        self.titleLabel.accessibilityIdentifier = "accessoryTitle"
        self.textLabel.accessibilityIdentifier = "accessoryText"
        self.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.tapGesture)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func closePressed() {
        self.close?()
    }

    @objc private func tapGesture() {
        self.tapped?()
    }

    func update(content: Content, theme: PresentationTheme, animated: Bool) {
        let previous = self.content
        self.content = content
        let colors = theme.chat.inputPanel
        self.accentColor = colors.panelControlAccentColor
        self.titleLabel.textColor = colors.panelControlAccentColor
        self.textLabel.textColor = colors.primaryTextColor
        self.closeIcon.tintColor = colors.inputControlColor
        self.statusView.update(status: content.status, color: colors.panelControlAccentColor)
        // Another message: the old text leaves upward and the new one comes in from below, as the pinned bar's does.
        if animated, let previous, previous.id != content.id, !self.bounds.isEmpty {
            for label in [self.titleLabel, self.textLabel] {
                if let snapshot = label.snapshotView(afterScreenUpdates: false) {
                    snapshot.frame = label.frame
                    self.addSubview(snapshot)
                    UIView.animate(withDuration: 0.2, animations: {
                        snapshot.alpha = 0.0
                        snapshot.frame = label.frame.offsetBy(dx: 0.0, dy: -10.0)
                    }, completion: { _ in
                        snapshot.removeFromSuperview()
                    })
                }
                label.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
                label.layer.animatePosition(from: CGPoint(x: 0.0, y: 10.0), to: CGPoint(), duration: 0.2, additive: true)
            }
        }
        self.titleLabel.text = content.title
        self.textLabel.text = content.text.replacingOccurrences(of: "\n", with: " ")
        if !self.bounds.isEmpty {
            self.layout(size: self.bounds.size, transition: .immediate)
        }
    }

    func layout(size: CGSize, transition: ComponentTransition) {
        // ChatInputMessageAccessoryPanel: 8 pt above and 6 pt below the line, which is 12 pt in; a 44 pt close button.
        let containerInsets = UIEdgeInsets(top: 8.0, left: 12.0, bottom: 6.0, right: 0.0)
        let lineFrame = CGRect(x: containerInsets.left, y: containerInsets.top, width: 2.0, height: size.height - containerInsets.top - containerInsets.bottom)
        transition.setFrame(view: self.lineContainer, frame: lineFrame)
        self.layoutSegments(size: lineFrame.size)

        let closeFrame = CGRect(x: size.width - 44.0, y: floor((size.height - 44.0) / 2.0), width: 44.0, height: 44.0)
        transition.setFrame(view: self.closeButton, frame: closeFrame)
        self.closeIcon.frame = CGRect(x: 16.0, y: 16.0, width: 12.0, height: 12.0)

        let textInsets = UIEdgeInsets(top: 10.0, left: 8.0, bottom: 0.0, right: 44.0)
        let textLeft = lineFrame.maxX + textInsets.left
        let maxWidth = max(1.0, size.width - textLeft - textInsets.right)
        let showsStatus = (self.content?.status ?? .none) != .none
        let titleSize = self.titleLabel.sizeThatFits(CGSize(width: maxWidth, height: 20.0))
        let titleFrame = CGRect(x: textLeft, y: textInsets.top - 2.0, width: min(maxWidth - (showsStatus ? 16.0 : 0.0), ceil(titleSize.width)), height: ceil(titleSize.height))
        self.titleLabel.frame = titleFrame
        self.statusView.frame = CGRect(x: titleFrame.maxX + 4.0, y: floor(titleFrame.midY - 6.0), width: 12.0, height: 12.0)
        self.statusView.isHidden = !showsStatus
        self.textLabel.frame = CGRect(x: textLeft, y: titleFrame.maxY + 1.0, width: maxWidth, height: 18.0)
    }

    /// One segment per queued message, up to four, the first in the accent color.
    private func layoutSegments(size: CGSize) {
        let count = min(4, max(1, self.content?.count ?? 1))
        while self.segmentViews.count < count {
            let view = UIView()
            view.layer.cornerRadius = 1.0
            self.lineContainer.addSubview(view)
            self.segmentViews.append(view)
        }
        while self.segmentViews.count > count {
            self.segmentViews.removeLast().removeFromSuperview()
        }
        let gap: CGFloat = count > 1 ? 2.0 : 0.0
        let height = (size.height - gap * CGFloat(count - 1)) / CGFloat(count)
        for (index, view) in self.segmentViews.enumerated() {
            view.frame = CGRect(x: 0.0, y: CGFloat(index) * (height + gap), width: size.width, height: height)
            view.backgroundColor = index == 0 ? self.accentColor : self.accentColor.withAlphaComponent(0.3)
        }
    }
}

/// Telegram's message status (ChatMessageDateAndStatusNode): a clock whose hands turn while the message is on its way,
/// one check once the server has it.
final class MessageStatusView: UIView {
    private let clockFrameView = UIImageView()
    private let clockMinView = UIImageView()
    private let checkView = UIImageView()
    private var status: InputAccessoryPanelView.Status?
    private var color: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for view in [self.clockFrameView, self.clockMinView, self.checkView] {
            self.addSubview(view)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(status: InputAccessoryPanelView.Status, color: UIColor) {
        if status == self.status && color == self.color {
            return
        }
        self.status = status
        self.color = color
        self.clockFrameView.image = generateClockFrameImage(color: color)
        self.clockMinView.image = generateClockMinImage(color: color)
        self.checkView.image = generateCheckImage(partial: false, color: color, width: 11.0)
        let sending = status == .sending
        self.clockFrameView.isHidden = !sending
        self.clockMinView.isHidden = !sending
        self.checkView.isHidden = status != .queued
        if sending {
            addClockAnimation(self.clockFrameView.layer, duration: 6.0)
            addClockAnimation(self.clockMinView.layer, duration: 1.0)
        }
        self.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
        for view in [self.clockFrameView, self.clockMinView] {
            view.bounds = CGRect(origin: CGPoint(), size: CGSize(width: 11.0, height: 11.0))
            view.center = center
        }
        self.checkView.frame = CGRect(x: center.x - 5.5, y: center.y - 4.5, width: 11.0, height: 9.0)
    }
}

// Telegram's status images (PresentationThemeEssentialGraphics.swift) and clock animation
// (ChatMessageDateAndStatusNode.swift).

func generateCheckImage(partial: Bool, color: UIColor, width: CGFloat) -> UIImage? {
    return generateImage(CGSize(width: width, height: floor(width * 9.0 / 11.0)), rotatedContext: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.scaleBy(x: width / 11.0, y: width / 11.0)
        context.translateBy(x: 1.0, y: 1.0)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(0.99)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if partial {
            let _ = try? drawSvgPath(context, path: "M0.5,7 L7,0 S ")
        } else {
            let _ = try? drawSvgPath(context, path: "M0,4 L2.95157047,6.95157047 L2.95157047,6.95157047 C2.97734507,6.97734507 3.01913396,6.97734507 3.04490857,6.95157047 C3.04548448,6.95099456 3.04604969,6.95040803 3.04660389,6.9498112 L9.5,0 S ")
        }
    })
}

func generateClockFrameImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 11.0, height: 11.0), contextGenerator: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        let strokeWidth: CGFloat = 1.0
        context.setLineWidth(strokeWidth)
        context.strokeEllipse(in: CGRect(x: strokeWidth / 2.0, y: strokeWidth / 2.0, width: size.width - strokeWidth, height: size.height - strokeWidth))
        context.fill(CGRect(x: (11.0 - strokeWidth) / 2.0, y: strokeWidth * 3.0, width: strokeWidth, height: 11.0 / 2.0 - strokeWidth * 3.0))
    })
}

func generateClockMinImage(color: UIColor) -> UIImage? {
    return generateImage(CGSize(width: 11.0, height: 11.0), contextGenerator: { size, context in
        context.clear(CGRect(origin: CGPoint(), size: size))
        context.setFillColor(color.cgColor)
        let strokeWidth: CGFloat = 1.0
        context.fill(CGRect(x: (11.0 - strokeWidth) / 2.0, y: (11.0 - strokeWidth) / 2.0, width: 11.0 / 2.0 - strokeWidth, height: strokeWidth))
    })
}

/// ChatMessageDateAndStatusNode's maybeAddRotationAnimation: the hour hand turns in 6 s, the minute hand in 1 s.
func addClockAnimation(_ layer: CALayer, duration: Double) {
    if layer.animation(forKey: "clockFrameAnimation") != nil {
        return
    }
    let animation = CABasicAnimation(keyPath: "transform.rotation.z")
    animation.duration = duration
    animation.fromValue = NSNumber(value: Float(0.0))
    animation.toValue = NSNumber(value: Float(Double.pi * 2.0))
    animation.repeatCount = Float.infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    animation.beginTime = 1.0
    layer.add(animation, forKey: "clockFrameAnimation")
}
