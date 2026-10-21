import Foundation
import SwiftMath

/// The LaTeX that models write, in the subset SwiftMath typesets: commands it lacks become the ones it has, or the
/// Unicode symbol (Latin Modern Math draws them), environments it lacks become `aligned` or `matrix`, and markup with
/// no effect on a phone (`\tag`, sizes, spacing commands) goes. Run before parsing; the original stays what Copy gives.
enum LatexNormalizer {
    static func normalize(_ latex: String) -> String {
        self.register()
        var text = latex
        text = self.rewriteEnvironments(text)
        text = self.rewriteArguments(text)
        text = self.replaceCommands(text)
        return text
    }

    /// Commands without arguments, by name, that SwiftMath has under another name, or that draw nothing on a phone.
    private static let commands: [String: String] = [
        "enspace": "\\;", "thinspace": "\\,", "negthinspace": "\\!", "hfill": "\\quad", "displaystyle": "",
        "textstyle": "", "scriptstyle": "", "scriptscriptstyle": "", "tiny": "", "small": "", "normalsize": "",
        "large": "", "Large": "", "LARGE": "", "huge": "", "Huge": "", "mathstrut": "", "nonumber": "", "notag": "",
        "limits": "", "nolimits": "", "hline": "", "newline": "\\\\", "big": "", "Big": "", "bigg": "", "Bigg": "",
        "bigl": "", "bigr": "", "Bigl": "", "Bigr": "", "biggl": "", "biggr": "", "Biggl": "", "Biggr": "",
        "bigm": "", "Bigm": "", "middle": "", "lVert": "\\|", "rVert": "\\|", "lvert": "|", "rvert": "|",
        "lbrack": "[", "rbrack": "]", "vert": "|", "Vert": "\\|", "lt": "<", "gt": ">", "implies": "\\Rightarrow",
        "impliedby": "\\Leftarrow", "iff": "\\Leftrightarrow", "leqslant": "\\leq", "geqslant": "\\geq",
        "intercal": "\\top", "iint": "\\int\\!\\!\\int", "iiint": "\\int\\!\\!\\int\\!\\!\\int", "intop": "\\int",
        "smallint": "\\int", "argmax": "\\arg\\max", "argmin": "\\arg\\min", "sgn": "\\mathrm{sgn}",
        "bmod": "\\;\\mathrm{mod}\\;", "varliminf": "\\liminf", "varlimsup": "\\limsup", "dots": "\\ldots",
        "dotsc": "\\ldots", "dotsb": "\\cdots", "dotsm": "\\cdots", "dotsi": "\\cdots", "dotso": "\\ldots",
        "mathellipsis": "\\ldots", "ldotp": ".", "textbackslash": "\\backslash", "textasciitilde": "\\sim",
        "lgroup": "(", "rgroup": ")", "N": "\\mathbb{N}", "Z": "\\mathbb{Z}", "R": "\\mathbb{R}", "C": "\\mathbb{C}",
        "Q": "\\mathbb{Q}", "degree": "^\\circ", "&": "＆", ":": "\\;", ">": "\\;",
    ]

    /// Symbols SwiftMath lacks a command for and its font has: registered as commands of their own (`register()`).
    private static let symbols: [(name: String, glyph: String, type: MTMathAtomType)] = [
        ("nexists", "∄", .relation), ("leqq", "≦", .relation), ("geqq", "≧", .relation), ("nleq", "≰", .relation),
        ("ngeq", "≱", .relation), ("lneq", "⪇", .relation), ("gneq", "⪈", .relation), ("lesssim", "≲", .relation),
        ("gtrsim", "≳", .relation), ("approxeq", "≊", .relation), ("backsim", "∽", .relation),
        ("triangleq", "≜", .relation), ("bumpeq", "≏", .relation), ("coloneqq", "≔", .relation),
        ("eqqcolon", "≕", .relation), ("vdash", "⊢", .relation), ("dashv", "⊣", .relation), ("vDash", "⊨", .relation),
        ("Vdash", "⊩", .relation), ("models", "⊨", .relation), ("multimap", "⊸", .relation),
        ("pitchfork", "⋔", .relation), ("subsetneq", "⊊", .relation), ("supsetneq", "⊋", .relation),
        ("nsubseteq", "⊈", .relation), ("nsupseteq", "⊉", .relation), ("nmid", "∤", .relation),
        ("nparallel", "∦", .relation), ("hookrightarrow", "↪", .relation), ("hookleftarrow", "↩", .relation),
        ("twoheadrightarrow", "↠", .relation), ("rightharpoonup", "⇀", .relation), ("leftharpoonup", "↼", .relation),
        ("rightleftharpoons", "⇌", .relation), ("leftrightarrows", "⇆", .relation),
        ("rightleftarrows", "⇄", .relation), ("looparrowright", "↬", .relation), ("curvearrowright", "↷", .relation),
        ("curvearrowleft", "↶", .relation), ("circlearrowleft", "↺", .relation), ("circlearrowright", "↻", .relation),
        ("Lsh", "↰", .relation), ("Rsh", "↱", .relation), ("upharpoonright", "↾", .relation),
        ("downharpoonright", "⇂", .relation), ("rightsquigarrow", "⇝", .relation), ("leadsto", "⇝", .relation),
        ("nrightarrow", "↛", .relation), ("nleftarrow", "↚", .relation), ("nRightarrow", "⇏", .relation),
        ("nLeftarrow", "⇍", .relation), ("nLeftrightarrow", "⇎", .relation), ("nleftrightarrow", "↮", .relation),
        ("dashrightarrow", "⇢", .relation), ("dashleftarrow", "⇠", .relation), ("Longmapsto", "⟾", .relation),
        ("longmapsto", "⟼", .relation), ("between", "≬", .relation), ("therefore", "∴", .relation),
        ("because", "∵", .relation), ("smallsetminus", "∖", .binaryOperator), ("circledast", "⊛", .binaryOperator),
        ("boxplus", "⊞", .binaryOperator), ("boxtimes", "⊠", .binaryOperator), ("boxminus", "⊟", .binaryOperator),
        ("boxdot", "⊡", .binaryOperator), ("centerdot", "·", .binaryOperator),
        ("divideontimes", "⋇", .binaryOperator), ("ltimes", "⋉", .binaryOperator), ("rtimes", "⋊", .binaryOperator),
        ("leftthreetimes", "⋋", .binaryOperator), ("rightthreetimes", "⋌", .binaryOperator),
        ("curlywedge", "⋏", .binaryOperator), ("curlyvee", "⋎", .binaryOperator), ("veebar", "⊻", .binaryOperator),
        ("barwedge", "⊼", .binaryOperator), ("doublebarwedge", "⩞", .binaryOperator), ("Cap", "⋒", .binaryOperator),
        ("Cup", "⋓", .binaryOperator), ("dotplus", "∔", .binaryOperator), ("diamond", "⋄", .binaryOperator),
        ("bigtriangleup", "△", .binaryOperator), ("bigtriangledown", "▽", .binaryOperator),
        ("triangleleft", "◃", .binaryOperator), ("triangleright", "▹", .binaryOperator),
        ("lhd", "⊲", .binaryOperator), ("rhd", "⊳", .binaryOperator), ("unlhd", "⊴", .binaryOperator),
        ("unrhd", "⊵", .binaryOperator), ("bigcirc", "◯", .binaryOperator), ("digamma", "ϝ", .ordinary),
        ("varkappa", "ϰ", .ordinary), ("beth", "ℶ", .ordinary), ("gimel", "ℷ", .ordinary), ("daleth", "ℸ", .ordinary),
        ("eth", "ð", .ordinary), ("Finv", "Ⅎ", .ordinary), ("Game", "⅁", .ordinary), ("complement", "∁", .ordinary),
        ("surd", "√", .ordinary), ("flat", "♭", .ordinary), ("sharp", "♯", .ordinary), ("natural", "♮", .ordinary),
        ("clubsuit", "♣", .ordinary), ("diamondsuit", "♢", .ordinary), ("heartsuit", "♡", .ordinary),
        ("spadesuit", "♠", .ordinary), ("dag", "†", .ordinary), ("ddag", "‡", .ordinary), ("S", "§", .ordinary),
        ("P", "¶", .ordinary), ("checkmark", "✓", .ordinary), ("blacksquare", "■", .ordinary),
        ("square", "□", .ordinary), ("Box", "□", .ordinary), ("blacktriangle", "▴", .ordinary),
        ("blacktriangledown", "▾", .ordinary), ("lozenge", "◊", .ordinary), ("blacklozenge", "⧫", .ordinary),
        ("bigstar", "★", .ordinary), ("measuredangle", "∡", .ordinary), ("sphericalangle", "∢", .ordinary),
        ("varnothing", "∅", .ordinary), ("hslash", "ℏ", .ordinary), ("backprime", "‵", .ordinary),
        ("vartriangle", "△", .ordinary), ("diagup", "╱", .ordinary), ("diagdown", "╲", .ordinary),
        ("Bbbk", "𝕜", .ordinary), ("ulcorner", "⌜", .ordinary), ("urcorner", "⌝", .ordinary),
        ("llcorner", "⌞", .ordinary), ("lrcorner", "⌟", .ordinary), ("lmoustache", "⎰", .ordinary),
        ("rmoustache", "⎱", .ordinary), ("i", "ı", .ordinary), ("j", "ȷ", .ordinary), ("l", "ł", .ordinary),
        ("L", "Ł", .ordinary), ("copyright", "©", .ordinary), ("pounds", "£", .ordinary), ("euro", "€", .ordinary),
        ("preceq", "⪯", .ordinary), ("succeq", "⪰", .ordinary), ("precsim", "≾", .ordinary),
        ("succsim", "≿", .ordinary),
    ]

    /// The negated relations `\not` makes.
    private static let negated: [(name: String, glyph: String, type: MTMathAtomType)] = [
        ("nequiv", "≢", .relation), ("nsubset", "⊄", .relation), ("nsupset", "⊅", .relation), ("nsim", "≁", .relation),
        ("napprox", "≉", .relation), ("ncong", "≇", .relation), ("nless", "≮", .relation), ("ngtr", "≯", .relation),
        ("nni", "∌", .relation), ("nsimeq", "≄", .relation),
    ]

    private static let registered: Void = {
        for symbol in LatexNormalizer.symbols + LatexNormalizer.negated where MTMathAtomFactory.atom(forLatexSymbol: symbol.name) == nil {
            // MTMathAtom's initializer is internal: a copy of a known atom, retyped.
            guard let atom = MTMathAtomFactory.atom(forLatexSymbol: "leq")?.copy() else {
                continue
            }
            atom.type = symbol.type
            atom.nucleus = symbol.glyph
            MTMathAtomFactory.add(latexSymbol: symbol.name, value: atom)
        }
    }()

    /// Makes SwiftMath know the extra symbols; once, before the first formula.
    static func register() {
        _ = self.registered
    }

    /// `\not` before a relation: its negated symbol.
    private static let negations: [String: String] = [
        "=": "\\neq", "\\equiv": "\\nequiv", "\\in": "\\notin", "\\subset": "\\nsubset", "\\supset": "\\nsupset", "\\subseteq": "\\nsubseteq",
        "\\supseteq": "\\nsupseteq", "\\sim": "\\nsim", "\\approx": "\\napprox", "\\cong": "\\ncong", "<": "\\nless", ">": "\\ngtr", "\\le": "\\nleq", "\\leq": "\\nleq",
        "\\ge": "\\ngeq", "\\geq": "\\ngeq", "\\mid": "\\nmid", "\\parallel": "\\nparallel", "\\exists": "\\nexists", "\\ni": "\\nni", "\\simeq": "\\nsimeq",
    ]

    /// Letters Unicode has precomposed that SwiftMath writes with a font command.
    private static let unicodeLetters: [Unicode.Scalar: String] = [
        "ℝ": "\\mathbb{R}", "ℕ": "\\mathbb{N}", "ℤ": "\\mathbb{Z}", "ℚ": "\\mathbb{Q}", "ℂ": "\\mathbb{C}", "ℙ": "\\mathbb{P}",
        "ℍ": "\\mathbb{H}", "𝔼": "\\mathbb{E}", "ℒ": "\\mathcal{L}", "ℱ": "\\mathcal{F}", "ℋ": "\\mathcal{H}", "−": "-", "…": "\\ldots ",
        "⋯": "\\cdots ", "′": "'", "″": "''",
    ]

    /// One pass over the text, replacing `\name` (a run of letters, or one other character) from `commands`.
    private static func replaceCommands(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        let unicodeNames = MTMathAtomFactory.textToLatexSymbolName
        while index < scalars.count {
            // A symbol typed as itself (`≤`, `α`, `ℝ`): SwiftMath reads only ASCII, so its command.
            if !scalars[index].isASCII, let replacement = self.unicodeLetters[scalars[index]] {
                output.append(contentsOf: replacement.unicodeScalars)
                index += 1
                continue
            }
            if !scalars[index].isASCII, let name = unicodeNames[String(scalars[index])], MTMathAtomFactory.atom(forCharacter: Character(scalars[index])) == nil {
                output.append(contentsOf: "\\\(name) ".unicodeScalars)
                index += 1
                continue
            }
            guard scalars[index] == "\\", index + 1 < scalars.count else {
                output.append(scalars[index])
                index += 1
                continue
            }
            var end = index + 1
            if CharacterSet.letters.contains(scalars[end]) {
                while end < scalars.count, CharacterSet.letters.contains(scalars[end]), scalars[end].isASCII {
                    end += 1
                }
            } else {
                end += 1
            }
            let name = String(String.UnicodeScalarView(scalars[(index + 1) ..< end]))
            if name == "not" {
                // The relation after it, possibly past spaces.
                var next = end
                while next < scalars.count, scalars[next] == " " {
                    next += 1
                }
                var relationEnd = next
                if next < scalars.count, scalars[next] == "\\" {
                    relationEnd = next + 1
                    while relationEnd < scalars.count, CharacterSet.letters.contains(scalars[relationEnd]) {
                        relationEnd += 1
                    }
                } else if next < scalars.count {
                    relationEnd = next + 1
                }
                let relation = String(String.UnicodeScalarView(scalars[next ..< relationEnd]))
                if let negated = self.negations[relation] {
                    output.append(contentsOf: (negated + " ").unicodeScalars)
                    index = relationEnd
                    continue
                }
                index = end
                continue
            }
            if name == " " {
                // `\ `, a space: SwiftMath's medium space.
                output.append(contentsOf: "\\;".unicodeScalars)
                index = end
                continue
            }
            if let replacement = self.commands[name] {
                // A command followed by a letter needs a space after its replacement if that is a command too.
                output.append(contentsOf: replacement.unicodeScalars)
                if replacement.hasPrefix("\\"), let last = replacement.unicodeScalars.last, CharacterSet.letters.contains(last), end < scalars.count, CharacterSet.letters.contains(scalars[end]) {
                    output.append(" ")
                }
                index = end
                continue
            }
            output.append(contentsOf: scalars[index ..< end])
            index = end
        }
        return String(output)
    }

    // MARK: - Commands with arguments

    /// The balanced `{...}` group at `index` (which must be `{`), or one token: its content and where it ends.
    private static func group(_ scalars: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        var index = start
        while index < scalars.count, scalars[index] == " " {
            index += 1
        }
        guard index < scalars.count else {
            return nil
        }
        if scalars[index] == "{" {
            var depth = 0
            var cursor = index
            while cursor < scalars.count {
                if scalars[cursor] == "\\" {
                    cursor += 2
                    continue
                }
                if scalars[cursor] == "{" {
                    depth += 1
                } else if scalars[cursor] == "}" {
                    depth -= 1
                    if depth == 0 {
                        return (String(String.UnicodeScalarView(scalars[(index + 1) ..< cursor])), cursor + 1)
                    }
                }
                cursor += 1
            }
            return nil
        }
        if scalars[index] == "\\" {
            var cursor = index + 1
            while cursor < scalars.count, CharacterSet.letters.contains(scalars[cursor]) {
                cursor += 1
            }
            if cursor == index + 1 {
                cursor += 1
            }
            return (String(String.UnicodeScalarView(scalars[index ..< min(cursor, scalars.count)])), min(cursor, scalars.count))
        }
        return (String(scalars[index]), index + 1)
    }

    /// Commands with arguments, rewritten by their arguments.
    private static let rewrites: [String: (count: Int, rewrite: ([String]) -> String)] = [
        "dfrac": (2, { "\\frac{\($0[0])}{\($0[1])}" }),
        "tfrac": (2, { "\\frac{\($0[0])}{\($0[1])}" }),
        "cfrac": (2, { "\\frac{\($0[0])}{\($0[1])}" }),
        "dbinom": (2, { "\\binom{\($0[0])}{\($0[1])}" }),
        "tbinom": (2, { "\\binom{\($0[0])}{\($0[1])}" }),
        "boldsymbol": (1, { "\\mathbf{\($0[0])}" }),
        "pmb": (1, { "\\mathbf{\($0[0])}" }),
        "bm": (1, { "\\mathbf{\($0[0])}" }),
        "mathbfit": (1, { "\\mathbf{\($0[0])}" }),
        "mathscr": (1, { "\\mathcal{\($0[0])}" }),
        "emph": (1, { "\\textit{\($0[0])}" }),
        "textup": (1, { "\\text{\($0[0])}" }),
        "textnormal": (1, { "\\text{\($0[0])}" }),
        "mbox": (1, { "\\text{\($0[0])}" }),
        "hbox": (1, { "\\text{\($0[0])}" }),
        "fbox": (1, { "\\text{\($0[0])}" }),
        "boxed": (1, { "\($0[0])" }),
        "cancel": (1, { "\($0[0])" }),
        "bcancel": (1, { "\($0[0])" }),
        "xcancel": (1, { "\($0[0])" }),
        "phantom": (1, { _ in "" }),
        "vphantom": (1, { _ in "" }),
        "hphantom": (1, { _ in "" }),
        "hspace": (1, { _ in "\\quad" }),
        "vspace": (1, { _ in "" }),
        "tag": (1, { "\\qquad (\($0[0]))" }),
        "label": (1, { _ in "" }),
        "mathbin": (1, { "\($0[0])" }),
        "mathrel": (1, { "\($0[0])" }),
        "mathord": (1, { "\($0[0])" }),
        "mathop": (1, { "\\mathrm{\($0[0])}" }),
        "pmod": (1, { "\\;(\\mathrm{mod}\\;\($0[0]))" }),
        "pod": (1, { "\\;(\($0[0]))" }),
        "underbrace": (1, { "\\underline{\($0[0])}" }),
        "overbrace": (1, { "\\overline{\($0[0])}" }),
        "overrightarrow": (1, { "\\vec{\($0[0])}" }),
        "overleftarrow": (1, { "\\overline{\($0[0])}" }),
        "overleftrightarrow": (1, { "\\overline{\($0[0])}" }),
        "underrightarrow": (1, { "\\underline{\($0[0])}" }),
        "overparen": (1, { "\\overline{\($0[0])}" }),
        "wideparen": (1, { "\\overline{\($0[0])}" }),
        "mathring": (1, { "\\dot{\($0[0])}" }),
        "xrightarrow": (1, { "\\stackrel{\($0[0])}{\\longrightarrow}" }),
        "xleftarrow": (1, { "\\stackrel{\($0[0])}{\\longleftarrow}" }),
        "xRightarrow": (1, { "\\stackrel{\($0[0])}{\\Longrightarrow}" }),
        "xLeftarrow": (1, { "\\stackrel{\($0[0])}{\\Longleftarrow}" }),
        "xmapsto": (1, { "\\stackrel{\($0[0])}{\\longmapsto}" }),
        "overset": (2, { "\\stackrel{\($0[0])}{\($0[1])}" }),
        "underset": (2, { "{\($0[1])}_{\($0[0])}" }),
        "substack": (1, { $0[0].replacingOccurrences(of: "\\\\", with: ",\\,") }),
        "ce": (1, { "\\mathrm{\($0[0])}" }),
        "color": (1, { _ in "" }),
        "textcolor": (2, { "\($0[1])" }),
        "colorbox": (2, { "\($0[1])" }),
        "raisebox": (2, { "\($0[1])" }),
        "kern": (1, { _ in "\\," }),
        "mkern": (1, { _ in "\\," }),
        "mskip": (1, { _ in "\\," }),
        "hskip": (1, { _ in "\\," }),
        "rule": (2, { _ in "" }),
        "sideset": (2, { _ in "" }),
        "operatorname*": (1, { "\\operatorname{\($0[0])}" }),
    ]

    private static func rewriteArguments(_ text: String) -> String {
        guard text.contains("\\") else {
            return text
        }
        var current = text
        // Nested rewrites (a `\dfrac` in a `\boxed`) take a few passes.
        for _ in 0 ..< 4 {
            let next = self.rewriteArgumentsOnce(current)
            if next == current {
                break
            }
            current = next
        }
        return current
    }

    private static func rewriteArgumentsOnce(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\\" else {
                output.append(scalars[index])
                index += 1
                continue
            }
            var end = index + 1
            while end < scalars.count, CharacterSet.letters.contains(scalars[end]), scalars[end].isASCII {
                end += 1
            }
            var name = String(String.UnicodeScalarView(scalars[(index + 1) ..< end]))
            if end < scalars.count, scalars[end] == "*", name == "operatorname" {
                name += "*"
                end += 1
            }
            if name == "operatorname" || name == "operatorname*" {
                // SwiftMath has no \operatorname: upright text, which is what it draws.
                if let (argument, after) = self.group(scalars, at: end) {
                    output.append(contentsOf: "\\mathrm{\(argument.replacingOccurrences(of: "\\,", with: " ").replacingOccurrences(of: "\\!", with: ""))}".unicodeScalars)
                    index = after
                    continue
                }
            }
            if name == "stackrel" {
                if let (over, afterOver) = self.group(scalars, at: end), let (base, afterBase) = self.group(scalars, at: afterOver) {
                    // A relation with something over it: the something as a superscript, the closest SwiftMath has.
                    output.append(contentsOf: "{\(base)}^{\(over)}".unicodeScalars)
                    index = afterBase
                    continue
                }
            }
            if let (count, rewrite) = self.rewrites[name] {
                var arguments: [String] = []
                var cursor = end
                // `\color{red}` has a group, `\kern1em` a dimension: the first token either way.
                if name == "kern" || name == "mkern" || name == "mskip" || name == "hskip" {
                    while cursor < scalars.count, scalars[cursor] == " " || scalars[cursor] == "." || scalars[cursor] == "-" || CharacterSet.alphanumerics.contains(scalars[cursor]) {
                        cursor += 1
                        if cursor < scalars.count, scalars[cursor] == "\\" {
                            break
                        }
                    }
                    output.append(contentsOf: rewrite([]).unicodeScalars)
                    index = cursor
                    continue
                }
                for _ in 0 ..< count {
                    guard let (argument, after) = self.group(scalars, at: cursor) else {
                        break
                    }
                    arguments.append(argument)
                    cursor = after
                }
                if arguments.count == count {
                    output.append(contentsOf: rewrite(arguments).unicodeScalars)
                    index = cursor
                    continue
                }
            }
            output.append(contentsOf: scalars[index ..< end])
            index = end
        }
        return String(output)
    }

    // MARK: - Environments

    private static func rewriteEnvironments(_ text: String) -> String {
        guard text.contains("\\begin") else {
            return text
        }
        let pattern = #"\\begin\{([a-zA-Z]+\*?)\}(\{[^}]*\})?([\s\S]*?)\\end\{\1\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        var current = text
        for _ in 0 ..< 4 {
            let range = NSRange(current.startIndex..., in: current)
            guard let match = regex.firstMatch(in: current, range: range) else {
                break
            }
            var rewritten = false
            let result = NSMutableString(string: current)
            for match in regex.matches(in: current, range: range).reversed() {
                let name = (current as NSString).substring(with: match.range(at: 1))
                let body = (current as NSString).substring(with: match.range(at: 3))
                guard let replacement = self.environment(name, body: body) else {
                    continue
                }
                result.replaceCharacters(in: match.range, with: replacement)
                rewritten = true
            }
            _ = match
            if !rewritten {
                break
            }
            current = result as String
        }
        return current
    }

    /// An environment SwiftMath cannot typeset, as one it can; nil to leave it.
    private static func environment(_ name: String, body: String) -> String? {
        let rows = body.components(separatedBy: "\\\\").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let columns = rows.map { $0.components(separatedBy: "&").count }.max() ?? 1
        switch name {
        case "aligned", "align", "align*", "alignat", "alignat*", "flalign", "flalign*", "split", "eqnarray", "eqnarray*", "alignedat":
            if name == "aligned" && columns == 2 && rows.allSatisfy({ $0.contains("&") }) {
                return nil
            }
            if columns <= 2 {
                // Each row as `left & right`, which `aligned` lines up at the `&`.
                let fixed = rows.map { row -> String in
                    let row = row.replacingOccurrences(of: "&=&", with: "&=").replacingOccurrences(of: "& = &", with: "&=")
                    return row.contains("&") ? row : "&" + row
                }
                return "\\begin{aligned}" + fixed.joined(separator: " \\\\ ") + "\\end{aligned}"
            }
            return "\\begin{matrix}" + rows.joined(separator: " \\\\ ") + "\\end{matrix}"
        case "equation", "equation*", "displaymath", "math":
            return rows.count <= 1 ? (rows.first ?? "") : "\\begin{gathered}" + rows.joined(separator: " \\\\ ") + "\\end{gathered}"
        case "gather", "gather*", "gathered", "multline", "multline*", "displaylines", "center":
            if rows.count <= 1 {
                return rows.first ?? ""
            }
            // One centered column.
            return "\\begin{matrix}" + rows.map { $0.replacingOccurrences(of: "&", with: "") }.joined(separator: " \\\\ ") + "\\end{matrix}"
        case "array", "smallmatrix", "tabular", "subarray":
            return "\\begin{matrix}" + rows.joined(separator: " \\\\ ") + "\\end{matrix}"
        case "dcases", "dcases*", "rcases", "cases*":
            return "\\begin{cases}" + rows.joined(separator: " \\\\ ") + "\\end{cases}"
        default:
            return nil
        }
    }
}
