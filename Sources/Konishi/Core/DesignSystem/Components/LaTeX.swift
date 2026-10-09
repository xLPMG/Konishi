import Foundation

/// Converts LaTeX math (inside `$…$`, `$$…$$`, `\(…\)`, `\[…\]`) and stray LaTeX
/// escapes/commands in prose into a readable Unicode approximation, since SwiftUI
/// has no math typesetter. The goal is legibility, not perfect typesetting:
/// `$\Delta x \approx 5 \cdot 10^{-3}\%$` becomes `Δx ≈ 5·10⁻³%`.
enum LaTeX {

    /// Rewrites a line of Markdown text so math spans render cleanly. Math spans are
    /// decoded and wrapped in backticks (inline code) to set them apart and to keep the
    /// decoded output from being re-interpreted by the Markdown parser. LaTeX commands
    /// that appear outside any math delimiters (a common model quirk) are decoded too.
    static func render(_ text: String) -> String {
        scan(text,
             decodeSpan: { inner in
                 var decoder = Decoder(Array(inner), mathMode: true, spoken: false)
                 return "`" + Decoder.normalizeMathSpacing(decoder.parse()) + "`"
             },
             decodePlain: { slice in
                 var decoder = Decoder(Array(slice), mathMode: false, spoken: false)
                 return decoder.parse()
             })
    }

    /// Rewrites text for text-to-speech: math spans and bare LaTeX commands become spoken
    /// words (`\approx` → "approximately", `x^2` → "x squared", `\frac{a}{b}` → "a over b")
    /// with no delimiters, backticks or math symbols the synthesizer would mangle or skip.
    static func speech(_ text: String) -> String {
        scan(text,
             decodeSpan: { inner in
                 var decoder = Decoder(Array(inner), mathMode: true, spoken: true)
                 return " " + decoder.parse() + " "
             },
             decodePlain: { slice in
                 var decoder = Decoder(Array(slice), mathMode: false, spoken: true)
                 return decoder.parse()
             })
    }

    /// Decodes a bare LaTeX math expression (no surrounding delimiters) to Unicode.
    static func decodeMath(_ expression: String) -> String {
        var decoder = Decoder(Array(expression), mathMode: true, spoken: false)
        return Decoder.normalizeMathSpacing(decoder.parse())
    }

    /// Walks `text`, decoding math delimiters (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) via
    /// `decodeSpan` and the surrounding prose via `decodePlain`.
    private static func scan(
        _ text: String,
        decodeSpan: (ArraySlice<Character>) -> String,
        decodePlain: (ArraySlice<Character>) -> String
    ) -> String {
        let chars = Array(text)
        let n = chars.count
        var out = ""
        var segmentStart = 0
        var i = 0

        func flushPlain(upTo end: Int) {
            guard end > segmentStart else { return }
            out += decodePlain(chars[segmentStart..<end])
        }

        while i < n {
            let c = chars[i]
            let escaped = i > 0 && chars[i - 1] == "\\"

            // $$ … $$  and  $ … $
            if c == "$" && !escaped {
                let double = i + 1 < n && chars[i + 1] == "$"
                let open = double ? 2 : 1
                if let close = findDollarClose(chars, from: i + open, double: double) {
                    let inner = chars[(i + open)..<close]
                    if double || looksLikeMath(inner) {
                        flushPlain(upTo: i)
                        out += decodeSpan(inner)
                        i = close + open
                        segmentStart = i
                        continue
                    }
                }
            }

            // \( … \)  and  \[ … \]
            if c == "\\" && i + 1 < n && (chars[i + 1] == "(" || chars[i + 1] == "[") {
                let closer: Character = chars[i + 1] == "(" ? ")" : "]"
                if let close = findBackslashClose(chars, from: i + 2, closer: closer) {
                    flushPlain(upTo: i)
                    out += decodeSpan(chars[(i + 2)..<close])
                    i = close + 2
                    segmentStart = i
                    continue
                }
            }

            i += 1
        }

        flushPlain(upTo: n)
        return out
    }


    // MARK: Delimiter scanning

    private static func findDollarClose(_ chars: [Character], from start: Int, double: Bool) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "$" && chars[j - 1] != "\\" {
                if double {
                    if j + 1 < chars.count && chars[j + 1] == "$" { return j }
                } else {
                    return j
                }
            }
            j += 1
        }
        return nil
    }

    private static func findBackslashClose(_ chars: [Character], from start: Int, closer: Character) -> Int? {
        var j = start
        while j + 1 < chars.count {
            if chars[j] == "\\" && chars[j + 1] == closer { return j }
            j += 1
        }
        return nil
    }

    /// Guards single-`$` spans against currency false-positives ("$5 and $10"): a span is
    /// treated as math if it carries a LaTeX signal or contains no multi-letter prose word.
    private static func looksLikeMath(_ inner: ArraySlice<Character>) -> Bool {
        if inner.isEmpty { return false }
        if inner.contains(where: { $0 == "\\" || $0 == "^" || $0 == "_" || $0 == "{" }) { return true }
        let words = String(inner).split(separator: " ")
        let hasProseWord = words.contains { word in
            word.count >= 3 && word.allSatisfy { $0.isLetter && $0.isASCII }
        }
        return !hasProseWord
    }
}

// MARK: - Decoder

/// A small recursive LaTeX-to-Unicode walker. In `mathMode` it resolves `^`/`_`
/// scripts, `{…}` grouping, `\frac`, `\sqrt`, symbols and Greek letters. Outside
/// math it only rewrites known commands/escapes and leaves everything else — including
/// `_`, `^`, `*`, backticks and unknown `\sequences` — untouched so prose and
/// snake_case survive.
private struct Decoder {
    private let chars: [Character]
    private let mathMode: Bool
    private let spoken: Bool
    private var i = 0

    init(_ chars: [Character], mathMode: Bool, spoken: Bool = false) {
        self.chars = chars
        self.mathMode = mathMode
        self.spoken = spoken
    }

    mutating func parse(stopAtBrace: Bool = false) -> String {
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "}" && stopAtBrace { break }
            switch c {
            case "\\":
                out += command()
            case "^" where mathMode:
                i += 1
                out += superscript(group())
            case "_" where mathMode:
                i += 1
                out += subscriptText(group())
            case "{" where mathMode:
                i += 1
                out += parse(stopAtBrace: true)
                if i < chars.count && chars[i] == "}" { i += 1 }
            case "}":
                i += 1
            case "$" where mathMode:
                i += 1
            case "~":
                out += spoken ? " " : "\u{00A0}"
                i += 1
            default:
                if spoken && mathMode, let word = Self.spokenLiterals[c] {
                    out += word
                } else {
                    out.append(c)
                }
                i += 1
            }
        }
        return out
    }

    /// Reads a command argument: a `{…}` group (decoded) or a single following token.
    private mutating func group() -> String {
        while i < chars.count && chars[i] == " " { i += 1 }
        guard i < chars.count else { return "" }
        if chars[i] == "{" {
            i += 1
            let inner = parse(stopAtBrace: true)
            if i < chars.count && chars[i] == "}" { i += 1 }
            return inner
        }
        if chars[i] == "\\" { return command() }
        let c = chars[i]
        i += 1
        return String(c)
    }

    private mutating func rawGroup() -> String {
        while i < chars.count && chars[i] == " " { i += 1 }
        guard i < chars.count, chars[i] == "{" else { return group() }
        i += 1
        let start = i
        var depth = 1
        while i < chars.count && depth > 0 {
            if chars[i] == "{" { depth += 1 }
            if chars[i] == "}" { depth -= 1 }
            if depth > 0 { i += 1 }
        }
        let value = String(chars[start..<i])
        if i < chars.count { i += 1 }
        return value
    }

    private mutating func command() -> String {
        i += 1 // consume backslash
        guard i < chars.count else { return mathMode ? "" : "\\" }
        let c = chars[i]

        if !c.isLetter {
            i += 1
            switch c {
            case "%": return spoken ? " percent" : "%"
            case "&": return spoken ? " and " : "&"
            case "$", "#", "_", "{", "}": return String(c)
            case " ", ",", ";", ":", "!": return " "
            case "\\": return mathMode ? (spoken ? ". " : "\n") : (spoken ? " " : "\\\\")
            default: return mathMode || spoken ? String(c) : "\\" + String(c)
            }
        }

        var name = ""
        while i < chars.count && chars[i].isLetter {
            name.append(chars[i])
            i += 1
        }
        // LaTeX ignores whitespace after a control word; keep it in prose so words don't
        // merge, and keep it for speech so spoken words stay separate.
        if mathMode && !spoken {
            while i < chars.count && chars[i] == " " { i += 1 }
        }

        switch name {
        case "text", "textrm", "textbf", "textit", "textsf", "texttt",
             "mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak",
             "boldsymbol", "operatorname", "mbox", "hbox":
            return group()
        case "frac", "tfrac", "dfrac", "cfrac":
            let numerator = group()
            let denominator = group()
            return spoken ? " " + numerator + " over " + denominator + " " : fraction(numerator, denominator)
        case "ce":
            let chemistry = ChemistryNotation.render(rawGroup())
            return spoken ? " " + chemistry + " " : chemistry
        case "sqrt":
            var index = ""
            if i < chars.count && chars[i] == "[" {
                i += 1
                while i < chars.count && chars[i] != "]" { index.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
            }
            let radicand = group()
            if spoken {
                let name = index.isEmpty ? "square root of " : index + "th root of "
                return " " + name + radicand + " "
            }
            let root = radicand.count > 1 ? "√(" + radicand + ")" : "√" + radicand
            return index.isEmpty ? root : superscript(index) + root
        case "vec", "overrightarrow": return spoken ? group() : group() + "\u{20D7}"
        case "hat", "widehat": return spoken ? group() : group() + "\u{0302}"
        case "bar", "overline": return spoken ? group() : group() + "\u{0304}"
        case "tilde", "widetilde": return spoken ? group() : group() + "\u{0303}"
        case "dot": return spoken ? group() : group() + "\u{0307}"
        case "ddot": return spoken ? group() : group() + "\u{0308}"
        case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr",
             "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits":
            return ""
        case "quad", "qquad": return "  "
        default:
            if spoken {
                return Self.spokenSymbols[name] ?? Self.spokenGreek[name] ?? " " + name + " "
            }
            if let symbol = Self.symbols[name] { return symbol }
            // Unknown: in math keep the readable name; in prose keep the original command.
            return mathMode ? name : "\\" + name
        }
    }

    /// Applies readable spacing around math operators/relations, independent of how the
    /// model spaced its input: relations/arrows get one space each side, multiplicative
    /// operators stay tight, and runs of spaces are collapsed.
    static func normalizeMathSpacing(_ s: String) -> String {
        var result = ""
        for ch in s {
            if Self.spacedOps.contains(ch) {
                while result.last == " " { result.removeLast() }
                result.append(" ")
                result.append(ch)
                result.append(" ")
            } else if Self.tightOps.contains(ch) {
                while result.last == " " { result.removeLast() }
                result.append(ch)
            } else if ch == " " {
                if result.last == " " { continue }
                if let last = result.last, Self.tightOps.contains(last) { continue }
                result.append(ch)
            } else {
                result.append(ch)
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    private func fraction(_ numerator: String, _ denominator: String) -> String {
        func wrap(_ side: String) -> String {
            let needsParens = side.count > 1 && side.contains { "+-−·×*/ ".contains($0) }
            return needsParens ? "(" + side + ")" : side
        }
        return wrap(numerator) + "/" + wrap(denominator)
    }

    private func superscript(_ s: String) -> String {
        if spoken {
            switch s {
            case "2": return " squared "
            case "3": return " cubed "
            default: return " to the power of " + s + " "
            }
        }
        if let mapped = mapAll(s, Self.superscripts) { return mapped }
        return s.count == 1 ? "^" + s : "^(" + s + ")"
    }

    private func subscriptText(_ s: String) -> String {
        if spoken { return " sub " + s + " " }
        if let mapped = mapAll(s, Self.subscripts) { return mapped }
        return s.count == 1 ? "_" + s : "_(" + s + ")"
    }

    private func mapAll(_ s: String, _ table: [Character: Character]) -> String? {
        guard !s.isEmpty else { return "" }
        var result = ""
        for ch in s {
            guard let mapped = table[ch] else { return nil }
            result.append(mapped)
        }
        return result
    }

    // MARK: Tables

    /// Operators/relations that read better with a space on each side.
    private static let spacedOps: Set<Character> = [
        "=", "+", "<", ">", "≤", "≥", "≠", "≈", "≡", "∼", "≃", "≅", "∝", "≪", "≫",
        "∈", "∉", "∋", "→", "←", "⇒", "⇐", "↔", "⇔", "↦", "±", "∓", "∧", "∨",
        "⊕", "⊗", "⊂", "⊃", "⊆", "⊇",
    ]

    /// Multiplicative operators that read better tight against their operands.
    private static let tightOps: Set<Character> = ["·", "×", "÷", "∗"]

    /// Literal operator characters spoken as words inside math spans.
    private static let spokenLiterals: [Character: String] = [
        "=": " equals ", "+": " plus ", "-": " minus ", "−": " minus ",
        "*": " times ", "/": " over ", "<": " less than ", ">": " greater than ",
    ]

    /// Command symbols spoken as words (Greek letters fall back to their command name).
    private static let spokenSymbols: [String: String] = [
        "cdot": " times ", "times": " times ", "div": " divided by ", "ast": " times ",
        "pm": " plus or minus ", "mp": " minus or plus ", "star": " star ",
        "leq": " less than or equal to ", "le": " less than or equal to ",
        "geq": " greater than or equal to ", "ge": " greater than or equal to ",
        "neq": " not equal to ", "ne": " not equal to ", "approx": " approximately ",
        "equiv": " equivalent to ", "sim": " similar to ", "simeq": " approximately equal to ",
        "cong": " approximately equal to ", "propto": " proportional to ",
        "ll": " much less than ", "gg": " much greater than ",
        "subset": " subset of ", "supset": " superset of ",
        "subseteq": " subset of or equal to ", "supseteq": " superset of or equal to ",
        "in": " in ", "notin": " not in ", "ni": " contains ",
        "cup": " union ", "cap": " intersection ", "setminus": " minus ",
        "emptyset": " empty set ", "varnothing": " empty set ",
        "forall": " for all ", "exists": " there exists ", "nexists": " there does not exist ",
        "neg": " not ", "land": " and ", "wedge": " and ", "lor": " or ", "vee": " or ",
        "oplus": " plus ", "otimes": " times ", "perp": " perpendicular to ",
        "parallel": " parallel to ", "angle": " angle ", "infty": " infinity ",
        "partial": " partial ", "nabla": " del ", "sum": " sum of ", "prod": " product of ",
        "int": " integral of ", "oint": " contour integral of ", "iint": " double integral of ",
        "to": " to ", "rightarrow": " to ", "gets": " from ", "leftarrow": " left arrow ",
        "Rightarrow": " implies ", "implies": " implies ", "Leftarrow": " implied by ",
        "leftrightarrow": " if and only if ", "Leftrightarrow": " if and only if ",
        "iff": " if and only if ", "mapsto": " maps to ",
        "uparrow": " up arrow ", "downarrow": " down arrow ",
        "cdots": " and so on ", "ldots": " and so on ", "dots": " and so on ",
        "vdots": " and so on ", "ddots": " and so on ",
        "prime": " prime ", "circ": " degrees ", "degree": " degrees ", "bullet": " ",
        "hbar": " h bar ", "ell": " l ", "percent": " percent ",
    ]

    /// Greek letters spoken as spaced words, with phonetic forms for the ones the
    /// synthesizer otherwise mispronounces or glues to a neighbour ("pi" → "pie").
    private static let spokenGreek: [String: String] = [
        "alpha": " alpha ", "beta": " beta ", "gamma": " gamma ", "delta": " delta ",
        "epsilon": " epsilon ", "varepsilon": " epsilon ", "zeta": " zeta ", "eta": " eta ",
        "theta": " theta ", "vartheta": " theta ", "iota": " iota ", "kappa": " kappa ",
        "lambda": " lambda ", "mu": " mew ", "nu": " new ", "xi": " ksai ",
        "omicron": " omicron ", "pi": " pie ", "varpi": " pie ", "rho": " row ",
        "varrho": " row ", "sigma": " sigma ", "varsigma": " sigma ", "tau": " tau ",
        "upsilon": " upsilon ", "phi": " fie ", "varphi": " fie ", "chi": " kai ",
        "psi": " sigh ", "omega": " omega ",
        "Gamma": " gamma ", "Delta": " delta ", "Theta": " theta ", "Lambda": " lambda ",
        "Xi": " ksai ", "Pi": " pie ", "Sigma": " sigma ", "Upsilon": " upsilon ",
        "Phi": " fie ", "Psi": " sigh ", "Omega": " omega ",
    ]

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ",
        "j": "ʲ", "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ",
        "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

    private static let symbols: [String: String] = [
        // Greek lowercase
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
        "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ",
        "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "omicron": "ο", "pi": "π", "varpi": "ϖ",
        "rho": "ρ", "varrho": "ϱ", "sigma": "σ", "varsigma": "ς", "tau": "τ", "upsilon": "υ",
        "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        // Greek uppercase
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π",
        "Sigma": "Σ", "Upsilon": "Υ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        // Operators & relations
        "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗", "star": "⋆",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠",
        "approx": "≈", "equiv": "≡", "sim": "∼", "simeq": "≃", "cong": "≅", "propto": "∝",
        "ll": "≪", "gg": "≫", "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇",
        "in": "∈", "notin": "∉", "ni": "∋", "cup": "∪", "cap": "∩", "setminus": "∖",
        "emptyset": "∅", "varnothing": "∅", "forall": "∀", "exists": "∃", "nexists": "∄",
        "neg": "¬", "land": "∧", "wedge": "∧", "lor": "∨", "vee": "∨",
        "oplus": "⊕", "otimes": "⊗", "perp": "⊥", "parallel": "∥", "angle": "∠",
        "triangle": "△", "square": "□", "infty": "∞", "partial": "∂", "nabla": "∇",
        "sum": "∑", "prod": "∏", "int": "∫", "oint": "∮", "iint": "∬",
        // Arrows
        "to": "→", "gets": "←", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒",
        "Leftarrow": "⇐", "leftrightarrow": "↔", "Leftrightarrow": "⇔", "mapsto": "↦",
        "uparrow": "↑", "downarrow": "↓", "implies": "⇒", "iff": "⇔",
        // Delimiters & dots
        "langle": "⟨", "rangle": "⟩", "lceil": "⌈", "rceil": "⌉", "lfloor": "⌊", "rfloor": "⌋",
        "cdots": "⋯", "ldots": "…", "dots": "…", "vdots": "⋮", "ddots": "⋱",
        // Misc
        "prime": "′", "circ": "∘", "bullet": "•", "dagger": "†", "degree": "°",
        "hbar": "ℏ", "ell": "ℓ", "Re": "ℜ", "Im": "ℑ", "aleph": "ℵ", "wp": "℘",
        "percent": "%", "backslash": "\\", "colon": ":",
    ]
}
