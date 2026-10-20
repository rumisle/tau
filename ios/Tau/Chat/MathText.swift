import UIKit
import CoreText
import Display
import SwiftMath

/// LaTeX in answers: `$...$` and `\(...\)` inline, `$$...$$` and `\[...\]` as display math, typeset by SwiftMath and
/// drawn by InteractiveTextNode as text attachments (`NSAttributedString.Key.attachment`), which it tints with the
/// text color.
///
/// Math comes out of the text before the Markdown parser sees it, which would read `_` and `*` as emphasis and drop
/// backslashes before punctuation. Each formula becomes one private-use character the parser passes through; the
/// renderer puts the formula back in its place.
enum MathText {
    struct Formula: Equatable {
        var latex: String
        var display: Bool
    }

    /// The first placeholder. U+E000...U+F8FF is the BMP's private use area: one UTF-16 unit each.
    private static let placeholderBase: UInt32 = 0xE000
    private static let maxFormulas = 0x18FF

    static func placeholderIndex(_ unit: unichar) -> Int? {
        let value = UInt32(unit)
        guard value >= placeholderBase, value < placeholderBase + UInt32(maxFormulas) else {
            return nil
        }
        return Int(value - placeholderBase)
    }

    /// The text with every formula outside code replaced by a placeholder, and the formulas in order. An unclosed
    /// delimiter, as in a half-streamed answer, stays text.
    static func extract(_ text: String) -> (String, [Formula]) {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else {
            return (text, [])
        }
        let characters = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var formulas: [Formula] = []
        var index = 0
        var atLineStart = true
        var inFence = false

        func hasPrefix(_ prefix: String, at position: Int) -> Bool {
            let scalars = Array(prefix.unicodeScalars)
            guard position + scalars.count <= characters.count else {
                return false
            }
            for offset in 0 ..< scalars.count where characters[position + offset] != scalars[offset] {
                return false
            }
            return true
        }

        func find(_ closing: String, from position: Int, singleLine: Bool) -> Int? {
            var cursor = position
            while cursor < characters.count {
                if singleLine && characters[cursor] == "\n" {
                    return nil
                }
                if characters[cursor] == "\\" && closing == "$" {
                    cursor += 2
                    continue
                }
                if hasPrefix(closing, at: cursor) {
                    return cursor
                }
                cursor += 1
            }
            return nil
        }

        func emit(_ latex: String, display: Bool) {
            if let scalar = Unicode.Scalar(placeholderBase + UInt32(formulas.count)) {
                output.append(scalar)
            }
            formulas.append(Formula(latex: latex.trimmingCharacters(in: .whitespacesAndNewlines), display: display))
        }

        while index < characters.count {
            let character = characters[index]
            // Fenced code blocks pass through untouched.
            if atLineStart, hasPrefix("```", at: index) || hasPrefix("~~~", at: index) {
                inFence.toggle()
            }
            if inFence || formulas.count >= maxFormulas {
                output.append(character)
                atLineStart = character == "\n"
                index += 1
                continue
            }
            atLineStart = character == "\n" ? true : (atLineStart && character == " ")

            // Inline code passes through untouched.
            if character == "`" {
                var ticks = 0
                while index + ticks < characters.count && characters[index + ticks] == "`" {
                    ticks += 1
                }
                let fence = String(repeating: "`", count: ticks)
                if let end = find(fence, from: index + ticks, singleLine: false) {
                    for offset in index ..< end + ticks {
                        output.append(characters[offset])
                    }
                    index = end + ticks
                    continue
                }
            }

            var delimiters: (open: String, close: String, display: Bool)?
            if hasPrefix("$$", at: index) {
                delimiters = ("$$", "$$", true)
            } else if hasPrefix("\\[", at: index) {
                delimiters = ("\\[", "\\]", true)
            } else if hasPrefix("\\(", at: index) {
                delimiters = ("\\(", "\\)", false)
            } else if character == "$" {
                delimiters = ("$", "$", false)
            }
            if let (open, close, display) = delimiters {
                let start = index + open.unicodeScalars.count
                if let end = find(close, from: start, singleLine: open == "$") {
                    let latex = String(String.UnicodeScalarView(characters[start ..< end]))
                    // A lone `$` is math only as `$x$`: no space inside the delimiters, no digit after, so prices
                    // like "$5 and $10" stay text.
                    var isMath = !latex.trimmingCharacters(in: .whitespaces).isEmpty
                    if open == "$" {
                        let after = end + 1 < characters.count ? characters[end + 1] : " "
                        isMath = isMath && latex.first != " " && latex.last != " " && !CharacterSet.decimalDigits.contains(after)
                    }
                    if isMath {
                        emit(latex, display: display)
                        index = end + close.unicodeScalars.count
                        continue
                    }
                }
            }
            output.append(character)
            index += 1
        }
        return (String(output), formulas)
    }

    private static let lock = NSLock()
    private static var cache: [String: (UIImage, CGFloat, CGFloat)?] = [:]

    /// The formula as an attachment run: the typeset image, with a run delegate that gives the character the image's
    /// width and its height above and below the baseline. Nil when SwiftMath cannot parse it.
    static func attachment(_ formula: Formula, fontSize: CGFloat, attributes: [NSAttributedString.Key: Any], maxWidth: CGFloat) -> NSAttributedString? {
        let size = formula.display ? fontSize * 1.15 : fontSize
        let key = "\(formula.display)|\(size)|\(formula.latex)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        let rendered: (UIImage, CGFloat, CGFloat)?
        if let cached {
            rendered = cached
        } else {
            var math = MathImage(latex: formula.latex, fontSize: size, textColor: .black, labelMode: formula.display ? .display : .text, textAlignment: .left)
            lock.lock()
            let (error, image, info) = math.asImage()
            lock.unlock()
            if error == nil, let image, let info {
                rendered = (image, info.ascent, info.descent)
            } else {
                rendered = nil
            }
            lock.lock()
            cache[key] = rendered
            lock.unlock()
        }
        guard var (image, ascent, descent) = rendered else {
            return nil
        }
        // A display formula wider than the text column shrinks to fit; it cannot wrap.
        if image.size.width > maxWidth, maxWidth > 0.0 {
            let scale = maxWidth / image.size.width
            let scaledSize = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
            image = generateImage(scaledSize, rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                UIGraphicsPushContext(context)
                image.draw(in: CGRect(origin: CGPoint(), size: size))
                UIGraphicsPopContext()
            }) ?? image
            ascent *= scale
            descent *= scale
        }
        // SwiftMath sets the formula's baseline `descent` above the image's bottom; a formula shorter than half the font
        // size is centered in that height instead.
        if ascent + descent < image.size.height - 0.5 {
            let extra = (image.size.height - ascent - descent) / 2.0
            ascent += extra
            descent += extra
        }
        let metrics = RunMetrics(width: image.size.width + 2.0, ascent: ascent, descent: descent)
        var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { pointer in
            Unmanaged<RunMetrics>.fromOpaque(pointer).release()
        }, getAscent: { pointer in
            return Unmanaged<RunMetrics>.fromOpaque(pointer).takeUnretainedValue().ascent
        }, getDescent: { pointer in
            return Unmanaged<RunMetrics>.fromOpaque(pointer).takeUnretainedValue().descent
        }, getWidth: { pointer in
            return Unmanaged<RunMetrics>.fromOpaque(pointer).takeUnretainedValue().width
        })
        guard let delegate = CTRunDelegateCreate(&callbacks, Unmanaged.passRetained(metrics).toOpaque()) else {
            return nil
        }
        var runAttributes = attributes
        runAttributes[.attachment] = image
        runAttributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
        // Copying the text gives the LaTeX back.
        runAttributes[latexKey] = formula.latex
        return NSAttributedString(string: "\u{FFFC}", attributes: runAttributes)
    }

    static let latexKey = NSAttributedString.Key("tau.latex")

    private final class RunMetrics {
        let width: CGFloat
        let ascent: CGFloat
        let descent: CGFloat

        init(width: CGFloat, ascent: CGFloat, descent: CGFloat) {
            self.width = width
            self.ascent = ascent
            self.descent = descent
        }
    }
}
