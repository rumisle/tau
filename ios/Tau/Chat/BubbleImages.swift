import UIKit
import Display

/// Which sides of a bubble touch the bubble above or below it, as Telegram names them.
enum MessageBubbleImageNeighbors: Hashable {
    case none
    case top(side: Bool)
    case bottom
    case both
}

private let minRadiusForFullTailCorner: CGFloat = 14.0

/// Copied from Telegram-iOS TelegramPresentationData/Sources/ChatMessageBubbleImages.swift (`messageBubbleImage`),
/// keeping the fill path: the same corner radii per neighbor case, the same tail curves, the same stretch points. Dropped:
/// knockout (wallpaper cut-outs), shadow, and outline variants.
func messageBubbleImage(maxCornerRadius: CGFloat, minCornerRadius: CGFloat, incoming: Bool, fillColor: UIColor, neighbors: MessageBubbleImageNeighbors) -> UIImage {
    let topLeftRadius: CGFloat
    let topRightRadius: CGFloat
    let bottomLeftRadius: CGFloat
    let bottomRightRadius: CGFloat
    let drawTail: Bool

    switch neighbors {
    case .none:
        topLeftRadius = maxCornerRadius
        topRightRadius = maxCornerRadius
        bottomLeftRadius = maxCornerRadius
        bottomRightRadius = maxCornerRadius
        drawTail = true
    case .both:
        topLeftRadius = maxCornerRadius
        topRightRadius = minCornerRadius
        bottomLeftRadius = maxCornerRadius
        bottomRightRadius = minCornerRadius
        drawTail = false
    case .bottom:
        topLeftRadius = maxCornerRadius
        topRightRadius = minCornerRadius
        bottomLeftRadius = maxCornerRadius
        bottomRightRadius = maxCornerRadius
        drawTail = true
    case let .top(side):
        topLeftRadius = maxCornerRadius
        topRightRadius = maxCornerRadius
        bottomLeftRadius = side ? minCornerRadius : maxCornerRadius
        bottomRightRadius = minCornerRadius
        drawTail = false
    }

    let fixedMainDiameter: CGFloat = 33.0
    let innerSize = CGSize(width: fixedMainDiameter + 6.0, height: fixedMainDiameter)
    let strokeInset: CGFloat = 1.0
    let sourceRawSize = CGSize(width: innerSize.width + strokeInset * 2.0, height: innerSize.height + strokeInset * 2.0)
    let additionalInset: CGFloat = 1.0
    let imageSize = CGSize(width: sourceRawSize.width + additionalInset * 2.0, height: sourceRawSize.height + additionalInset * 2.0)
    let outgoingStretchPoint: (x: Int, y: Int) = (Int(additionalInset + strokeInset + round(fixedMainDiameter / 2.0)) - 1, Int(additionalInset + strokeInset + round(fixedMainDiameter / 2.0)))
    let incomingStretchPoint: (x: Int, y: Int) = (Int(sourceRawSize.width) - outgoingStretchPoint.x + Int(additionalInset), outgoingStretchPoint.y)

    let rawSize = imageSize

    let bottomEllipse = CGRect(origin: CGPoint(x: 24.0, y: 16.0), size: CGSize(width: 27.0, height: 17.0))
    let topEllipse = CGRect(origin: CGPoint(x: 33.0, y: 14.0), size: CGSize(width: 23.0, height: 21.0))

    let formContext = DrawingContext(size: imageSize)!
    formContext.withFlippedContext { context in
        context.clear(CGRect(origin: CGPoint(), size: rawSize))
        context.translateBy(x: additionalInset + strokeInset, y: additionalInset + strokeInset)

        context.setFillColor(UIColor.black.cgColor)

        context.move(to: CGPoint(x: 0.0, y: topLeftRadius))
        context.addArc(tangent1End: CGPoint(x: 0.0, y: 0.0), tangent2End: CGPoint(x: topLeftRadius, y: 0.0), radius: topLeftRadius)
        context.addLine(to: CGPoint(x: fixedMainDiameter - topRightRadius, y: 0.0))
        context.addArc(tangent1End: CGPoint(x: fixedMainDiameter, y: 0.0), tangent2End: CGPoint(x: fixedMainDiameter, y: topRightRadius), radius: topRightRadius)
        context.addLine(to: CGPoint(x: fixedMainDiameter, y: fixedMainDiameter - bottomRightRadius))
        context.addArc(tangent1End: CGPoint(x: fixedMainDiameter, y: fixedMainDiameter), tangent2End: CGPoint(x: fixedMainDiameter - bottomRightRadius, y: fixedMainDiameter), radius: bottomRightRadius)
        context.addLine(to: CGPoint(x: bottomLeftRadius, y: fixedMainDiameter))
        context.addArc(tangent1End: CGPoint(x: 0.0, y: fixedMainDiameter), tangent2End: CGPoint(x: 0.0, y: fixedMainDiameter - bottomLeftRadius), radius: bottomLeftRadius)
        context.addLine(to: CGPoint(x: 0.0, y: topLeftRadius))
        context.fillPath()

        if drawTail {
            if maxCornerRadius >= minRadiusForFullTailCorner {
                context.move(to: CGPoint(x: bottomEllipse.minX, y: bottomEllipse.midY))
                context.addQuadCurve(to: CGPoint(x: bottomEllipse.midX, y: bottomEllipse.maxY), control: CGPoint(x: bottomEllipse.minX, y: bottomEllipse.maxY))
                context.addQuadCurve(to: CGPoint(x: bottomEllipse.maxX, y: bottomEllipse.midY), control: CGPoint(x: bottomEllipse.maxX, y: bottomEllipse.maxY))
                context.fillPath()
            } else {
                context.fill(CGRect(origin: CGPoint(x: bottomEllipse.minX - 2.0, y: bottomEllipse.midY), size: CGSize(width: bottomEllipse.width + 2.0, height: bottomEllipse.height / 2.0)))
            }
            context.fill(CGRect(origin: CGPoint(x: fixedMainDiameter / 2.0, y: floor(fixedMainDiameter / 2.0)), size: CGSize(width: fixedMainDiameter / 2.0, height: ceil(bottomEllipse.midY) - floor(fixedMainDiameter / 2.0))))
            context.setFillColor(UIColor.clear.cgColor)
            context.setBlendMode(.copy)
            context.fillEllipse(in: topEllipse)
        }
    }
    let formImage = formContext.generateImage()!

    let drawingContext = DrawingContext(size: imageSize)!
    drawingContext.withFlippedContext { context in
        context.clear(CGRect(origin: CGPoint(), size: rawSize))
        context.setBlendMode(.normal)
        context.setFillColor(fillColor.cgColor)

        context.saveGState()
        context.translateBy(x: rawSize.width / 2.0, y: rawSize.height / 2.0)
        context.scaleBy(x: incoming ? -1.0 : 1.0, y: -1.0)
        context.translateBy(x: -rawSize.width / 2.0, y: -rawSize.height / 2.0)
        context.clip(to: CGRect(origin: CGPoint(), size: rawSize), mask: formImage.cgImage!)
        context.fill(CGRect(origin: CGPoint(), size: rawSize))
        context.restoreGState()
    }

    return drawingContext.generateImage()!.stretchableImage(withLeftCapWidth: incoming ? incomingStretchPoint.x : outgoingStretchPoint.x, topCapHeight: incoming ? incomingStretchPoint.y : outgoingStretchPoint.y)
}

/// Bubble images are drawn once per (color, neighbors) and shared, as Telegram's PresentationResourcesChat does.
final class BubbleImageCache {
    static let shared = BubbleImageCache()

    private struct Key: Hashable {
        let incoming: Bool
        let neighbors: MessageBubbleImageNeighbors
        let color: UInt32
    }

    private var images: [Key: UIImage] = [:]
    private let lock = NSLock()

    /// Telegram's default bubble corners: 16 pt, and 8 pt where bubbles merge.
    func image(incoming: Bool, neighbors: MessageBubbleImageNeighbors, color: UIColor) -> UIImage {
        let key = Key(incoming: incoming, neighbors: neighbors, color: color.argb)
        self.lock.lock()
        defer { self.lock.unlock() }
        if let image = self.images[key] {
            return image
        }
        let image = messageBubbleImage(maxCornerRadius: 16.0, minCornerRadius: 8.0, incoming: incoming, fillColor: color, neighbors: neighbors)
        self.images[key] = image
        return image
    }
}
