import UIKit
import Display

/// A model provider's logo on its color, as a rounded square: the avatar of its accounts and the icon of its rows
/// (docs/accounts.md). The logos are LobeHub's (scripts/provider-icons.py), in the asset catalog's Providers; a
/// provider without one has its initial on a letter avatar's gradient.
enum ProviderIcon {
    private struct Look {
        var asset: String
        var background: UInt32
        /// The logo's color; nil for a logo in its own colors.
        var foreground: UInt32?
    }

    private static let looks: [String: Look] = {
        let white: UInt32 = 0xFFFFFF
        let black: UInt32 = 0x000000
        let kimi = Look(asset: "kimi", background: black, foreground: white)
        let minimax = Look(asset: "minimax", background: 0xE73562, foreground: white)
        let zai = Look(asset: "zai", background: black, foreground: white)
        let qwen = Look(asset: "qwen", background: 0x615CED, foreground: white)
        let xiaomi = Look(asset: "xiaomimimo", background: 0xFF6900, foreground: white)
        let cloudflare = Look(asset: "cloudflare", background: 0xF38020, foreground: white)
        let opencode = Look(asset: "opencode", background: black, foreground: white)
        return [
            "anthropic": Look(asset: "claude-color", background: 0xF4F1EA, foreground: nil),
            "openai": Look(asset: "openai", background: black, foreground: white),
            "openai-codex": Look(asset: "openai", background: black, foreground: white),
            "github-copilot": Look(asset: "githubcopilot", background: black, foreground: white),
            "google": Look(asset: "gemini-color", background: white, foreground: nil),
            "google-vertex": Look(asset: "vertexai", background: 0x4285F4, foreground: white),
            "xai": Look(asset: "xai", background: black, foreground: white),
            "deepseek": Look(asset: "deepseek", background: 0x4D6BFE, foreground: white),
            "mistral": Look(asset: "mistral", background: 0xFA520F, foreground: white),
            "moonshotai": kimi,
            "moonshotai-cn": kimi,
            "kimi-coding": kimi,
            "openrouter": Look(asset: "openrouter", background: 0x6467F2, foreground: white),
            "fireworks": Look(asset: "fireworks", background: 0x5019C5, foreground: white),
            "groq": Look(asset: "groq", background: 0xF55036, foreground: white),
            "together": Look(asset: "together", background: 0x0F6FFF, foreground: white),
            "cerebras": Look(asset: "cerebras", background: 0xF15A29, foreground: white),
            "meta": Look(asset: "meta", background: 0x0668E1, foreground: white),
            "minimax": minimax,
            "minimax-cn": minimax,
            "zai": zai,
            "zai-coding-cn": zai,
            "nvidia": Look(asset: "nvidia", background: 0x76B900, foreground: white),
            "huggingface": Look(asset: "huggingface", background: 0xFFD21E, foreground: black),
            "amazon-bedrock": Look(asset: "bedrock", background: 0x01A88D, foreground: white),
            "azure": Look(asset: "azure", background: 0x0078D4, foreground: white),
            "cloudflare-ai-gateway": cloudflare,
            "cloudflare-workers-ai": cloudflare,
            "vercel-ai-gateway": Look(asset: "vercel", background: black, foreground: white),
            "qwen-token-plan": qwen,
            "qwen-token-plan-cn": qwen,
            "qwen-token-plan-individual": qwen,
            "qwen-token-plan-individual-cn": qwen,
            "xiaomi": xiaomi,
            "xiaomi-token-plan-ams": xiaomi,
            "xiaomi-token-plan-cn": xiaomi,
            "xiaomi-token-plan-sgp": xiaomi,
            "baseten": Look(asset: "baseten", background: black, foreground: white),
            "opencode": opencode,
            "opencode-go": opencode,
        ]
    }()

    private static let lock = NSLock()
    private static var cache: [String: UIImage] = [:]

    /// The provider's square, `size` points wide, its corners as an app icon's.
    static func image(provider: String, name: String, size: CGFloat) -> UIImage? {
        let key = "\(provider)|\(size)"
        self.lock.lock()
        let cached = self.cache[key]
        self.lock.unlock()
        if let cached {
            return cached
        }
        let image: UIImage?
        if let look = self.looks[provider], let logo = UIImage(named: "Providers/\(look.asset)") {
            image = self.draw(logo: look.foreground.map { logo.withTintColor(UIColor(rgb: $0), renderingMode: .alwaysOriginal) } ?? logo, background: UIColor(rgb: look.background), size: size)
        } else {
            // The letter avatar's gradient, in a square
            let colors = Avatar.gradientColors[abs(provider.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }) % Avatar.gradientColors.count]
            image = self.draw(letter: String(name.prefix(1)).uppercased(), colors: colors, size: size)
        }
        if let image {
            self.lock.lock()
            self.cache[key] = image
            self.lock.unlock()
        }
        return image
    }

    private static func path(size: CGFloat) -> UIBezierPath {
        return UIBezierPath(roundedRect: CGRect(x: 0.0, y: 0.0, width: size, height: size), cornerRadius: size * 0.225)
    }

    private static func draw(logo: UIImage, background: UIColor, size: CGFloat) -> UIImage? {
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            self.path(size: size).addClip()
            background.setFill()
            UIRectFill(CGRect(x: 0.0, y: 0.0, width: size, height: size))
            let side = round(size * 0.6)
            logo.draw(in: CGRect(x: (size - side) / 2.0, y: (size - side) / 2.0, width: side, height: side))
        }
    }

    private static func draw(letter: String, colors: [UIColor], size: CGFloat) -> UIImage? {
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            self.path(size: size).addClip()
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: [0.0, 1.0])!
            context.cgContext.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: size), end: CGPoint(x: 0.0, y: 0.0), options: [])
            let font = Avatar.font(size: floor(size * 0.48))
            let text = NSAttributedString(string: letter, attributes: [.font: font, .foregroundColor: UIColor.white])
            let bounds = text.size()
            text.draw(at: CGPoint(x: (size - bounds.width) / 2.0, y: (size - bounds.height) / 2.0))
        }
    }
}
