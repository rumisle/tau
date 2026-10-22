import UIKit
import AsyncDisplayKit
import Display

/// Letter avatar in Telegram's style: a vertical two-color gradient circle with rounded bold initials.
/// Colors and drawing follow Telegram-iOS AvatarNode/Sources/AvatarNode.swift.
enum Avatar {
    static let gradientColors: [[UIColor]] = [
        [UIColor(rgb: 0xff516a), UIColor(rgb: 0xff885e)],
        [UIColor(rgb: 0xffa85c), UIColor(rgb: 0xffcd6a)],
        [UIColor(rgb: 0x665fff), UIColor(rgb: 0x82b1ff)],
        [UIColor(rgb: 0x54cb68), UIColor(rgb: 0xa0de7e)],
        [UIColor(rgb: 0x4acccd), UIColor(rgb: 0x00fcfd)],
        [UIColor(rgb: 0x2a9ef1), UIColor(rgb: 0x72d5fd)],
        [UIColor(rgb: 0xd669ed), UIColor(rgb: 0xe0a2f3)],
    ]

    static func font(size: CGFloat) -> UIFont {
        return Font.with(size: size, design: .round, weight: .bold)
    }

    static func letters(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        let initials = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return initials.isEmpty ? "?" : initials.joined()
    }

    /// Rows lay out on background queues, several lists at once while folders are swiped: the cache is shared.
    private static let lock = NSLock()
    private static var cache: [String: UIImage] = [:]

    static func image(letters: String, colorIndex: Int, diameter: CGFloat) -> UIImage? {
        let key = "\(letters)|\(colorIndex)|\(diameter)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached {
            return cached
        }
        let colors = gradientColors[abs(colorIndex) % gradientColors.count]
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
            let string = NSAttributedString(string: letters, font: letterFont, textColor: .white)
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
