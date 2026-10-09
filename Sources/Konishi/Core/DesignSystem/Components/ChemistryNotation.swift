import Foundation

enum ChemistryNotation {
    static func render(_ source: String) -> String {
        let characters = Array(source)
        var output = ""
        var index = 0

        while index < characters.count {
            if let arrow = arrow(at: index, in: characters) {
                output += arrow.value
                index += arrow.length
                continue
            }

            let character = characters[index]
            if character == "\\" {
                let command = readCommand(characters, from: &index)
                output += arrowCommand(command) ?? "\\" + command
            } else if character == "^" || character == "_" {
                index += 1
                let script = readScript(characters, from: &index)
                output += mappedScript(script, superscript: character == "^")
            } else if character.isNumber {
                let start = index
                while index < characters.count && characters[index].isNumber { index += 1 }
                let digits = String(characters[start..<index])
                let previous = output.last(where: { !$0.isWhitespace })
                if let previous, previous.isLetter || previous == ")" || previous == "]" {
                    output += mappedScript(digits, superscript: false)
                } else {
                    output += digits
                }
            } else if character == "+" || character == "-" || character == "−" {
                let previous = index > 0 ? characters[index - 1] : nil
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let endsSpecies = previous.map {
                    $0.isLetter || $0.isNumber || Self.subscripts.values.contains($0) || $0 == ")" || $0 == "]"
                } ?? false
                let endsCharge = next.map {
                    $0.isWhitespace || $0 == ")" || $0 == "]" || $0 == "("
                } ?? true
                if endsSpecies && endsCharge {
                    output += mappedScript(String(character), superscript: true)
                } else {
                    output.append(character)
                }
                index += 1
            } else if character == "#" {
                output.append("≡")
                index += 1
            } else if character == "{" || character == "}" {
                index += 1
            } else {
                output.append(character)
                index += 1
            }
        }

        return output
    }

    private static func arrow(at index: Int, in characters: [Character]) -> (value: String, length: Int)? {
        let suffix = String(characters[index...])
        for (token, value) in [("<=>", "⇌"), ("<->", "↔"), ("->", "→"), ("<-", "←")] {
            if suffix.hasPrefix(token) { return (value, token.count) }
        }
        return nil
    }

    private static func readCommand(_ characters: [Character], from index: inout Int) -> String {
        index += 1
        let start = index
        while index < characters.count && characters[index].isLetter { index += 1 }
        return String(characters[start..<index])
    }

    private static func arrowCommand(_ command: String) -> String? {
        switch command {
        case "rightarrow", "to": "→"
        case "leftarrow", "gets": "←"
        case "leftrightarrow": "↔"
        case "rightleftharpoons", "leftrightharpoons": "⇌"
        case "cdot", "cdotp": "·"
        default: nil
        }
    }

    private static func readScript(_ characters: [Character], from index: inout Int) -> String {
        guard index < characters.count else { return "" }
        if characters[index] == "{" {
            index += 1
            let start = index
            var depth = 1
            while index < characters.count && depth > 0 {
                if characters[index] == "{" { depth += 1 }
                if characters[index] == "}" { depth -= 1 }
                if depth > 0 { index += 1 }
            }
            let value = String(characters[start..<index])
            if index < characters.count { index += 1 }
            return value
        }

        let start = index
        if characters[index].isNumber {
            while index < characters.count && characters[index].isNumber { index += 1 }
            if index < characters.count && (characters[index] == "+" || characters[index] == "-" || characters[index] == "−") {
                index += 1
            }
        } else {
            index += 1
        }
        return String(characters[start..<index])
    }

    private static func mappedScript(_ value: String, superscript: Bool) -> String {
        let map = superscript ? superscripts : subscripts
        var result = ""
        for character in value {
            guard let mapped = map[character] else {
                return (superscript ? "^" : "_") + value
            }
            result.append(mapped)
        }
        return result
    }

    private static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "(": "⁽", ")": "⁾",
    ]

    private static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "(": "₍", ")": "₎",
    ]
}