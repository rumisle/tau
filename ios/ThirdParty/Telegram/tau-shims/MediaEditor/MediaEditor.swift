// tau shim for Telegram's MediaEditor module (stories and the modern photo editor). The media picker lists the editor's
// saved drafts; tau has none.
import Foundation
import UIKit

public final class MediaEditorDraft: Equatable {
    public let path: String
    public let isVideo: Bool
    public let thumbnail: UIImage
    public let duration: Double?
    public let timestamp: Int32

    public init(path: String, isVideo: Bool, thumbnail: UIImage, duration: Double?, timestamp: Int32) {
        self.path = path
        self.isVideo = isVideo
        self.thumbnail = thumbnail
        self.duration = duration
        self.timestamp = timestamp
    }

    public static func ==(lhs: MediaEditorDraft, rhs: MediaEditorDraft) -> Bool {
        return lhs.path == rhs.path
    }
}

import Display

/// As in MediaEditor; only its gradient helpers, which the picker uses for video thumbnails.
public final class MediaEditor {
    public struct GradientColors {
        public let top: UIColor
        public let bottom: UIColor

        public init(top: UIColor, bottom: UIColor) {
            self.top = top
            self.bottom = bottom
        }

        public var array: [UIColor] {
            return [self.top, self.bottom]
        }
    }
}

public func mediaEditorGenerateGradientImage(size: CGSize, colors: [UIColor]) -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(size, false, 1.0)
    if let context = UIGraphicsGetCurrentContext() {
        let gradientColors = colors.map { $0.cgColor } as CFArray
        var locations: [CGFloat] = [0.0, 1.0]
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: gradientColors, locations: &locations)!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: CGGradientDrawingOptions())
    }
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
}

public func mediaEditorGetGradientColors(from image: UIImage) -> MediaEditor.GradientColors {
    let context = DrawingContext(size: CGSize(width: 5.0, height: 5.0), scale: 1.0, clear: false)!
    context.withFlippedContext({ context in
        if let cgImage = image.cgImage {
            context.draw(cgImage, in: CGRect(x: 0.0, y: 0.0, width: 5.0, height: 5.0))
        }
    })
    return MediaEditor.GradientColors(top: context.colorAt(CGPoint(x: 2.0, y: 0.0)), bottom: context.colorAt(CGPoint(x: 2.0, y: 4.0)))
}
