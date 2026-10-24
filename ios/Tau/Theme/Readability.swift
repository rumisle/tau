import UIKit
import TelegramPresentationData

/// Text that reads on every theme and accent as on Telegram's Night and Day (docs/appearance.md).
///
/// Telegram makes Tinted Night's colors by scaling the accent's brightness, so a darker accent darkens the text with
/// the backgrounds and its contrast falls: on green, secondary text measures half of Night's. Each rule here names a
/// color, the surfaces it is drawn on and the contrast it needs there, measured with APCA, which weighs dark themes as
/// eyes do; a color short of it on any of its surfaces is lifted until it is not. A see-through color is made more
/// opaque; an opaque one lighter (or darker, on a light surface) in OKLCH, so it keeps its hue and chroma. A color that
/// already reads is left as Telegram made it, so Night and Day stay as they are.
enum Readability {
    /// Lc of secondary text: dates, previews, subtitles, footers, the agent's times and thinking. Night's lowest: its
    /// messages' times on the chat's background.
    static let secondary: CGFloat = 37.0
    /// Lc of labels that are not dimmed on purpose, such as the tab bar's: Night's and Day's are white and black.
    static let primary: CGFloat = 75.0

    static func apply(to theme: PresentationTheme, chatBackground: UIColor) -> PresentationTheme {
        let root = theme.rootController
        let tabBar = root.tabBar
        let bar = root.navigationBar
        let chatList = theme.chatList
        let list = theme.list
        let message = theme.chat.message

        let listSurfaces = [chatList.backgroundColor, chatList.itemBackgroundColor]
        func parted(_ colors: PresentationThemePartedColors, on surfaces: [UIColor]) -> PresentationThemePartedColors {
            let fill = colors.bubble.withWallpaper.fill + colors.bubble.withoutWallpaper.fill
            let lifted = readable(colors.secondaryTextColor, on: fill + surfaces, contrast: Readability.secondary)
            return lifted == colors.secondaryTextColor ? colors : colors.withUpdated(secondaryTextColor: lifted)
        }

        return PresentationTheme(
            name: theme.name,
            index: theme.index,
            referenceTheme: theme.referenceTheme,
            overallDarkAppearance: theme.overallDarkAppearance,
            intro: theme.intro,
            passcode: theme.passcode,
            rootController: root.withUpdated(
                tabBar: tabBar.withUpdated(textColor: readable(tabBar.textColor, on: [tabBar.backgroundColor, bar.opaqueBackgroundColor], contrast: primary)),
                navigationBar: bar.withUpdated(secondaryTextColor: readable(bar.secondaryTextColor, on: [bar.opaqueBackgroundColor, bar.blurredBackgroundColor], contrast: secondary))
            ),
            list: list.withUpdated(
                itemSecondaryTextColor: readable(list.itemSecondaryTextColor, on: [list.itemBlocksBackgroundColor], contrast: secondary),
                // Above and below the sections, on the screen's background.
                sectionHeaderTextColor: readable(list.sectionHeaderTextColor, on: [list.blocksBackgroundColor], contrast: secondary),
                freeTextColor: readable(list.freeTextColor, on: [list.blocksBackgroundColor], contrast: secondary)
            ),
            chatList: chatList.withUpdated(
                dateTextColor: readable(chatList.dateTextColor, on: listSurfaces, contrast: secondary),
                messageTextColor: readable(chatList.messageTextColor, on: listSurfaces, contrast: secondary)
            ),
            chat: theme.chat.withUpdated(message: message.withUpdated(
                // An incoming message is also the agent's, drawn on the chat's background without a bubble. An outgoing
                // bubble's time is left as it is: on its accent it reads no better on Night or Day.
                incoming: parted(message.incoming, on: [chatBackground])
            )),
            actionSheet: theme.actionSheet,
            contextMenu: theme.contextMenu,
            inAppNotification: theme.inAppNotification,
            chart: theme.chart,
            preview: theme.preview
        )
    }

    /// `color`, or the least change of it that reaches `contrast` on each of `surfaces`.
    static func readable(_ color: UIColor, on surfaces: [UIColor], contrast: CGFloat) -> UIColor {
        let surfaces = surfaces.map(RGB.init)
        let text = RGB(color)
        var alpha = color.cgColor.alpha
        func reads(_ text: RGB, alpha: CGFloat) -> Bool {
            return surfaces.allSatisfy { lightness(text.over($0, alpha: alpha), on: $0) >= contrast }
        }
        if reads(text, alpha: alpha) {
            return color
        }
        // See-through: as opaque as it must be.
        if alpha < 1.0 {
            if reads(text, alpha: 1.0) {
                var low = alpha, high: CGFloat = 1.0
                for _ in 0 ..< 20 {
                    let middle = (low + high) / 2.0
                    if reads(text, alpha: middle) {
                        high = middle
                    } else {
                        low = middle
                    }
                }
                return text.color(alpha: high)
            }
            alpha = 1.0
        }
        // Then lighter on a dark surface, darker on a light one, in hue and chroma as it was.
        let lch = OKLCH(text)
        let lighter = surfaces.reduce(0.0) { $0 + OKLCH($1).l } / CGFloat(max(1, surfaces.count)) < 0.6
        var low = lighter ? lch.l : 0.0, high = lighter ? 1.0 : lch.l
        for _ in 0 ..< 24 {
            let middle = (low + high) / 2.0
            let ok = reads(OKLCH(l: middle, c: lch.c, h: lch.h).rgb, alpha: alpha)
            if lighter == ok {
                high = middle
            } else {
                low = middle
            }
        }
        return OKLCH(l: lighter ? high : low, c: lch.c, h: lch.h).rgb.color(alpha: alpha)
    }

    /// APCA's lightness contrast (Lc, 0.0.98G-4g), as a magnitude: about 40 for Night's secondary text, 60 for Day's,
    /// 100 for white on black.
    static func lightness(_ text: RGB, on background: RGB) -> CGFloat {
        func y(_ c: RGB) -> CGFloat {
            let y = 0.2126729 * pow(c.r, 2.4) + 0.7151522 * pow(c.g, 2.4) + 0.0721750 * pow(c.b, 2.4)
            return y > 0.022 ? y : y + pow(0.022 - y, 1.414)
        }
        let yt = y(text), yb = y(background)
        if abs(yb - yt) < 0.0005 {
            return 0.0
        }
        if yb > yt {
            let s = (pow(yb, 0.56) - pow(yt, 0.57)) * 1.14
            return s < 0.1 ? 0.0 : (s - 0.027) * 100.0
        }
        let s = (pow(yb, 0.65) - pow(yt, 0.62)) * 1.14
        return s > -0.1 ? 0.0 : -(s + 0.027) * 100.0
    }

    /// An opaque sRGB color, 0 to 1.
    struct RGB {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat

        init(r: CGFloat, g: CGFloat, b: CGFloat) {
            self.r = r
            self.g = g
            self.b = b
        }

        /// The color, its alpha left out.
        init(_ color: UIColor) {
            var r: CGFloat = 0.0, g: CGFloat = 0.0, b: CGFloat = 0.0, a: CGFloat = 0.0
            if !color.getRed(&r, green: &g, blue: &b, alpha: &a) {
                var white: CGFloat = 0.0
                color.getWhite(&white, alpha: &a)
                (r, g, b) = (white, white, white)
            }
            self.init(r: min(1.0, max(0.0, r)), g: min(1.0, max(0.0, g)), b: min(1.0, max(0.0, b)))
        }

        func over(_ background: RGB, alpha: CGFloat) -> RGB {
            return RGB(r: self.r * alpha + background.r * (1.0 - alpha), g: self.g * alpha + background.g * (1.0 - alpha), b: self.b * alpha + background.b * (1.0 - alpha))
        }

        func color(alpha: CGFloat) -> UIColor {
            return UIColor(red: self.r, green: self.g, blue: self.b, alpha: alpha)
        }
    }

    /// Björn Ottosson's OKLCH: lightness 0 to 1, chroma, hue in radians.
    struct OKLCH {
        var l: CGFloat
        var c: CGFloat
        var h: CGFloat

        init(l: CGFloat, c: CGFloat, h: CGFloat) {
            self.l = l
            self.c = c
            self.h = h
        }

        init(_ rgb: RGB) {
            func linear(_ x: CGFloat) -> CGFloat {
                return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            let r = linear(rgb.r), g = linear(rgb.g), b = linear(rgb.b)
            let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
            let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
            let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
            self.init(l: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s, c: hypot(a, bb), h: atan2(bb, a))
        }

        /// In sRGB, each channel clipped to its range.
        var rgb: RGB {
            let a = self.c * cos(self.h), b = self.c * sin(self.h)
            let l = pow(self.l + 0.3963377774 * a + 0.2158037573 * b, 3.0)
            let m = pow(self.l - 0.1055613458 * a - 0.0638541728 * b, 3.0)
            let s = pow(self.l - 0.0894841775 * a - 1.2914855480 * b, 3.0)
            func gamma(_ x: CGFloat) -> CGFloat {
                let x = min(1.0, max(0.0, x))
                return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
            }
            return RGB(
                r: gamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                g: gamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                b: gamma(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
            )
        }
    }
}
