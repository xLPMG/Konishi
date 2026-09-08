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
        let chars = Array(text)
        let n = chars.count
        var out = ""
        var segmentStart = 0
        var i = 0

        func flushPlain(upTo end: Int) {
            guard end > segmentStart else { return }
            var decoder = Decoder(Array(chars[segmentStart..<end]), mathMode: false)
            out += decoder.parse()
        }

        func emitMath(_ slice: ArraySlice<Character>) {
            var decoder = Decoder(Array(slice), mathMode: true)
            out += "`" + Decoder.normalizeMathSpacing(decoder.parse()) + "`"
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
                        emitMath(inner)
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
                    emitMath(chars[(i + 2)..<close])
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

    /// Decodes a bare LaTeX math expression (no surrounding delimiters) to Unicode.
    static func decodeMath(_ expression: String) -> String {
        var decoder = Decoder(Array(expression), mathMode: true)
        return Decoder.normalizeMathSpacing(decoder.parse())
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
    private var i = 0

    init(_ chars: [Character], mathMode: Bool) {
        self.chars = chars
        self.mathMode = mathMode
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
                out += "\u{00A0}"
                i += 1
            default:
                out.append(c)
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

    private mutating func command() -> String {
        i += 1 // consume backslash
        guard i < chars.count else { return mathMode ? "" : "\\" }
        let c = chars[i]

        if !c.isLetter {
            i += 1
            switch c {
            case "%", "$", "&", "#", "_", "{", "}": return String(c)
            case " ", ",", ";", ":", "!": return " "
            case "\\": return mathMode ? "\n" : "\\\\"
            default: return mathMode ? String(c) : "\\" + String(c)
            }
        }

        var name = ""
        while i < chars.count && chars[i].isLetter {
            name.append(chars[i])
            i += 1
        }
        // LaTeX ignores whitespace after a control word; keep it in prose so words don't merge.
        if mathMode {
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
            return fraction(numerator, denominator)
        case "sqrt":
            var index = ""
            if i < chars.count && chars[i] == "[" {
                i += 1
                while i < chars.count && chars[i] != "]" { index.append(chars[i]); i += 1 }
                if i < chars.count { i += 1 }
            }
            let radicand = group()
            let root = radicand.count > 1 ? "√(" + radicand + ")" : "√" + radicand
            return index.isEmpty ? root : superscript(index) + root
        case "vec", "overrightarrow": return group() + "\u{20D7}"
        case "hat", "widehat": return group() + "\u{0302}"
        case "bar", "overline": return group() + "\u{0304}"
        case "tilde", "widetilde": return group() + "\u{0303}"
        case "dot": return group() + "\u{0307}"
        case "ddot": return group() + "\u{0308}"
        case "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr",
             "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits":
            return ""
        case "quad", "qquad": return "  "
        default:
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
        if let mapped = mapAll(s, Self.superscripts) { return mapped }
        return s.count == 1 ? "^" + s : "^(" + s + ")"
    }

    private func subscriptText(_ s: String) -> String {
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
