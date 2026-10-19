import UIKit
import AsyncDisplayKit
import Display
import SwiftSignalKit
import TelegramCore
import GradientBackground
import GZip
import Svg

/// The chat wallpaper, composed as Telegram's WallpaperBackgroundNode (WallpaperBackgroundNode/Sources/
/// WallpaperBackgroundNode.swift) does for the built-in themes: a solid color, a two-color linear gradient, or
/// Telegram's four-color animated gradient (GradientBackgroundNode, copied) under the pattern. A positive pattern
/// intensity soft-lights the pattern over the gradient; a negative one shows the gradient only through the pattern, on
/// black, at that opacity (Night). Telegram downloads the pattern; tau bundles the default one (ThirdParty/tdesktop).
final class WallpaperNode: ASDisplayNode {
    private let contentLayer = CALayer()
    private var gradientNode: GradientBackgroundNode?
    private let patternLayer = CALayer()

    private var wallpaper: TelegramWallpaper?
    private var size: CGSize?
    private var patternKey: PatternKey?
    private let patternDisposable = MetaDisposable()

    private struct PatternKey: Equatable {
        var size: CGSize
        var inverted: Bool
        var black: Bool
    }

    override init() {
        super.init()
        self.isLayerBacked = false
        self.clipsToBounds = true
        self.layer.addSublayer(self.contentLayer)
        self.patternLayer.contentsGravity = .resizeAspectFill
        self.layer.addSublayer(self.patternLayer)
    }

    deinit {
        self.patternDisposable.dispose()
    }

    func update(wallpaper: TelegramWallpaper, animated: Bool) {
        if self.wallpaper == wallpaper {
            return
        }
        if animated, self.wallpaper != nil, let snapshot = self.view.snapshotView(afterScreenUpdates: false) {
            self.view.addSubview(snapshot)
            snapshot.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak snapshot] _ in
                snapshot?.removeFromSuperview()
            })
        }
        self.wallpaper = wallpaper

        var colors: [UInt32] = []
        var rotation: Int32 = 0
        switch wallpaper {
        case let .color(color):
            colors = [color]
        case let .gradient(gradient):
            colors = gradient.colors
            rotation = gradient.settings.rotation ?? 0
        case let .file(file) where file.isPattern || file.file.mimeType == "application/x-tgwallpattern":
            colors = file.settings.colors
            rotation = file.settings.rotation ?? 0
        default:
            colors = [0xffffff]
        }

        if colors.count >= 3 {
            let mapped = colors.map { UIColor(rgb: $0) }
            if let gradientNode = self.gradientNode {
                gradientNode.updateColors(colors: mapped)
            } else {
                let gradientNode = createGradientBackgroundNode(colors: mapped, useSharedAnimationPhase: true)
                self.gradientNode = gradientNode
                self.insertSubnode(gradientNode, at: 0)
            }
            self.contentLayer.contents = nil
            self.contentLayer.backgroundColor = nil
        } else {
            if let gradientNode = self.gradientNode {
                self.gradientNode = nil
                gradientNode.removeFromSupernode()
            }
            if colors.count == 2 {
                let top = UIColor(rgb: colors[0])
                let bottom = UIColor(rgb: colors[1])
                let image = generateImage(CGSize(width: 100.0, height: 200.0), rotatedContext: { size, context in
                    var locations: [CGFloat] = [0.0, 1.0]
                    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top.cgColor, bottom.cgColor] as CFArray, locations: &locations)!
                    context.translateBy(x: size.width / 2.0, y: size.height / 2.0)
                    context.rotate(by: CGFloat(rotation) * CGFloat.pi / 180.0)
                    context.translateBy(x: -size.width / 2.0, y: -size.height / 2.0)
                    context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
                })
                self.contentLayer.contents = image?.cgImage
                self.contentLayer.backgroundColor = nil
            } else {
                self.contentLayer.contents = nil
                self.contentLayer.backgroundColor = UIColor(rgb: colors.first ?? 0xffffff).cgColor
            }
        }
        self.updatePattern()
    }

    /// Telegram rotates the four-color gradient one step when a message is sent.
    func animateEvent() {
        self.gradientNode?.animateEvent(transition: .animated(duration: 0.5, curve: .spring), extendAnimation: false, backwards: false, completion: {})
    }

    func updateLayout(size: CGSize, transition: ContainedViewLayoutTransition) {
        let bounds = CGRect(origin: CGPoint(), size: size)
        transition.updateFrame(layer: self.contentLayer, frame: bounds)
        transition.updateFrame(layer: self.patternLayer, frame: bounds)
        if let gradientNode = self.gradientNode {
            transition.updateFrame(node: gradientNode, frame: bounds)
            gradientNode.updateLayout(size: size, transition: transition, extendAnimation: false, backwards: false, completion: {})
        }
        if self.size != size {
            self.size = size
            self.updatePattern()
        }
    }

    private func updatePattern() {
        guard let size = self.size, size.width > 1.0, case let .file(file)? = self.wallpaper, file.settings.colors.count > 0 else {
            self.patternLayer.isHidden = true
            self.patternLayer.contents = nil
            self.patternKey = nil
            self.backgroundColor = nil
            self.gradientNode?.contentView.alpha = 1.0
            self.contentLayer.opacity = 1.0
            return
        }
        let intensity = CGFloat(file.settings.intensity ?? 50) / 100.0
        let inverted = intensity < 0.0
        let brightness = UIColor.average(of: file.settings.colors.map { UIColor(rgb: $0) }).hsb.b
        let black = brightness <= 0.01

        self.patternLayer.isHidden = false
        if inverted {
            self.backgroundColor = .black
            self.gradientNode?.contentView.alpha = abs(intensity)
            self.contentLayer.opacity = Float(abs(intensity))
            self.patternLayer.compositingFilter = nil
            self.patternLayer.opacity = 1.0
        } else {
            self.backgroundColor = nil
            self.gradientNode?.contentView.alpha = 1.0
            self.contentLayer.opacity = 1.0
            self.patternLayer.compositingFilter = black ? nil : "softLightBlendMode"
            self.patternLayer.opacity = Float(intensity)
        }

        let key = PatternKey(size: size, inverted: inverted, black: black)
        if self.patternKey == key {
            return
        }
        self.patternKey = key
        let foreground: UIColor = black ? .white : .black
        self.patternDisposable.set((WallpaperNode.patternImage(size: size, inverted: inverted, foreground: foreground) |> deliverOnMainQueue).start(next: { [weak self] image in
            self?.patternLayer.contents = image?.cgImage
        }))
    }

    private static let patternData: Data? = {
        guard let url = Bundle.main.url(forResource: "background", withExtension: "tgv"), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return TGGUnzipData(data, 8 * 1024 * 1024)
    }()

    private static var cache: [String: UIImage] = [:]

    /// The pattern drawn to fill `size`: `foreground` shapes on clear, or when inverted, black with the shapes cut out.
    private static func patternImage(size: CGSize, inverted: Bool, foreground: UIColor) -> Signal<UIImage?, NoError> {
        let key = "\(size.width)x\(size.height)-\(inverted)-\(foreground.rgb)"
        if let image = WallpaperNode.cache[key] {
            return .single(image)
        }
        return Signal { subscriber in
            let scale = min(2.0, UIScreenScale)
            // The pattern is drawn at its aspect ratio and cropped to fill, as Telegram's aspect-fill display mode does.
            let patternSize = CGSize(width: 1440.0, height: 2960.0).aspectFilled(size)
            guard let data = WallpaperNode.patternData, let shapes = drawSvgImage(data: data, size: patternSize, backgroundColor: .clear, foregroundColor: inverted ? .black : foreground, scale: scale, opaque: false) else {
                subscriber.putNext(nil)
                subscriber.putCompletion()
                return EmptyDisposable
            }
            let rect = CGRect(origin: CGPoint(x: (size.width - patternSize.width) / 2.0, y: (size.height - patternSize.height) / 2.0), size: patternSize)
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            format.opaque = false
            let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
                if inverted {
                    UIColor.black.setFill()
                    context.fill(CGRect(origin: CGPoint(), size: size))
                    shapes.draw(in: rect, blendMode: .destinationOut, alpha: 1.0)
                } else {
                    shapes.draw(in: rect)
                }
            }
            Queue.mainQueue().async {
                WallpaperNode.cache[key] = image
            }
            subscriber.putNext(image)
            subscriber.putCompletion()
            return EmptyDisposable
        } |> runOn(Queue.concurrentDefaultQueue())
    }
}

extension TelegramWallpaper {
    var isPlainColor: Bool {
        if case .color = self {
            return true
        }
        return false
    }
}
