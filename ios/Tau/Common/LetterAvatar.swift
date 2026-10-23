import UIKit

/// Telegram's letter avatar without Display, for the notification service extension: the same palette, initials and
/// drawing as `Avatar` (AvatarNode.swift), which the app draws its rows with.
enum LetterAvatar {
    /// Telegram-iOS AvatarNode's gradients, top to bottom.
    static let palette: [(UInt32, UInt32)] = [
        (0xff516a, 0xff885e),
        (0xffa85c, 0xffcd6a),
        (0x665fff, 0x82b1ff),
        (0x54cb68, 0xa0de7e),
        (0x4acccd, 0x00fcfd),
        (0x2a9ef1, 0x72d5fd),
        (0xd669ed, 0xe0a2f3),
    ]

    static func letters(_ title: String) -> String {
        let words = title.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).filter { !$0.isEmpty }
        let initials = words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }
        return initials.isEmpty ? "?" : initials.joined()
    }

    /// A chat's avatar by its app ID, as the chat list draws it.
    static func image(title: String, colorIndex: Int, diameter: CGFloat) -> UIImage {
        let colors = palette[abs(colorIndex) % palette.count]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: CGSize(width: diameter, height: diameter), format: format).image { renderer in
            let context = renderer.cgContext
            let bounds = CGRect(x: 0.0, y: 0.0, width: diameter, height: diameter)
            context.addEllipse(in: bounds)
            context.clip()
            // As Avatar: the second color at the top.
            var locations: [CGFloat] = [1.0, 0.0]
            let cgColors = [color(colors.0).cgColor, color(colors.1).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: &locations) {
                context.drawLinearGradient(gradient, start: CGPoint(), end: CGPoint(x: 0.0, y: diameter), options: [])
            }
            let size = floor(diameter * 26.0 / 60.0)
            let base = UIFont.systemFont(ofSize: size, weight: .bold)
            let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
            let string = NSAttributedString(string: letters(title), attributes: [.font: font, .foregroundColor: UIColor.white])
            // Center the glyphs themselves, not the line box.
            let glyphs = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(string), .useGlyphPathBounds)
            let baseline = diameter / 2.0 + glyphs.midY
            string.draw(at: CGPoint(x: (diameter - glyphs.width) / 2.0 - glyphs.minX, y: baseline - font.ascender))
        }
    }

    private static func color(_ rgb: UInt32) -> UIColor {
        return UIColor(red: CGFloat((rgb >> 16) & 0xff) / 255.0, green: CGFloat((rgb >> 8) & 0xff) / 255.0, blue: CGFloat(rgb & 0xff) / 255.0, alpha: 1.0)
    }
}
