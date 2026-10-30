import UIKit
import AsyncDisplayKit
import Display

/// Letter avatar in Telegram's style: a vertical two-color gradient circle with rounded bold initials.
/// Colors and drawing follow Telegram-iOS AvatarNode/Sources/AvatarNode.swift.
enum Avatar {
    static let gradientColors: [[UIColor]] = LetterAvatar.palette.map { [UIColor(rgb: $0.0), UIColor(rgb: $0.1)] }

    static func font(size: CGFloat) -> UIFont {
        return Font.with(size: size, design: .round, weight: .bold)
    }

    static func letters(_ title: String) -> String {
        return LetterAvatar.letters(title)
    }

    /// Rows lay out on background queues, several lists at once while folders are swiped: the cache is shared.
    private static let lock = NSLock()
    private static var cache: [String: UIImage] = [:]

    static func image(letters: String, colorIndex: Int, diameter: CGFloat) -> UIImage? {
        let colors = gradientColors[abs(colorIndex) % gradientColors.count]
        return self.image(letters: letters, key: "\(colorIndex)", colors: colors, letterColor: .white, diameter: diameter)
    }

    /// tau's own τ, in the accent: Telegram's avatar gradient made from it, the accent at the bottom and a lighter tint
    /// of it on top, so accents without an avatar palette (yellow, gray) have one too. White (Night's) goes from white
    /// down to a light gray under a dark τ, which would not show on it in white; black (Day's) lightens to a dark gray.
    static func image(letters: String, accent: UInt32, diameter: CGFloat) -> UIImage? {
        let red = CGFloat((accent >> 16) & 0xff) / 255.0
        let green = CGFloat((accent >> 8) & 0xff) / 255.0
        let blue = CGFloat(accent & 0xff) / 255.0
        let luminance = 0.299 * red + 0.587 * green + 0.114 * blue
        let mixed = { (amount: CGFloat, toward: CGFloat) -> UIColor in
            return UIColor(red: red + (toward - red) * amount, green: green + (toward - green) * amount, blue: blue + (toward - blue) * amount, alpha: 1.0)
        }
        let colors: [UIColor]
        let letterColor: UIColor
        if luminance > 0.85 {
            colors = [mixed(0.14, 0.0), mixed(0.0, 1.0)]
            letterColor = UIColor(rgb: 0x1c1c1e)
        } else {
            colors = [mixed(0.0, 1.0), mixed(luminance < 0.1 ? 0.3 : 0.35, 1.0)]
            letterColor = .white
        }
        return self.image(letters: letters, key: String(format: "accent-%06x", accent), colors: colors, letterColor: letterColor, diameter: diameter)
    }

    /// `colors`: the bottom's, then the top's. The cache keys on `key`, which names them.
    private static func image(letters: String, key colorKey: String, colors: [UIColor], letterColor: UIColor, diameter: CGFloat) -> UIImage? {
        let key = "\(letters)|\(colorKey)|\(diameter)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached {
            return cached
        }
        let image = generateImage(CGSize(width: diameter, height: diameter), rotatedContext: { size, context in
            let bounds = CGRect(origin: CGPoint(), size: size)
            context.clear(bounds)
            context.addEllipse(in: bounds)
            context.clip()
            let colorsArray = colors.map(\.cgColor) as CFArray
            var locations: [CGFloat] = [1.0, 0.0]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colorsArray, locations: &locations)!
            context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: size.height), options: [])

            // Center the glyphs themselves, not the line box. Glyph bounds are relative to the baseline, y up.
            let letterFont = font(size: floor(diameter * 26.0 / 60.0))
            let string = NSAttributedString(string: letters, font: letterFont, textColor: letterColor)
            let glyphs = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(string), .useGlyphPathBounds)
            let baseline = size.height / 2.0 + glyphs.midY
            UIGraphicsPushContext(context)
            string.draw(at: CGPoint(x: (size.width - glyphs.width) / 2.0 - glyphs.minX, y: baseline - letterFont.ascender))
            UIGraphicsPopContext()
        })
        lock.lock()
        cache[key] = image
        lock.unlock()
        return image
    }
}
