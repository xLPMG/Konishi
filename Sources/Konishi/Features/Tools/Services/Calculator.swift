import Foundation

enum CalculatorError: LocalizedError {
    case invalidExpression(String)

    var errorDescription: String? {
        switch self {
        case let .invalidExpression(message): message
        }
    }
}

/// Small, deterministic expression evaluator for arithmetic that should not consume model tokens.
enum Calculator {
    static func evaluate(_ expression: String) throws -> Double {
        var parser = Parser(expression)
        let value = try parser.parseExpression()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw CalculatorError.invalidExpression("unexpected input") }
        guard value.isFinite else { throw CalculatorError.invalidExpression("result is not finite") }
        return value
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < Double(Int64.max) {
            return String(Int64(value))
        }
        return String(format: "%.12g", value)
    }

    private struct Parser {
        private let input: [Character]
        private var index = 0

        init(_ expression: String) { input = Array(expression) }
        var isAtEnd: Bool { index >= input.count }

        mutating func skipWhitespace() {
            while !isAtEnd, input[index].isWhitespace { index += 1 }
        }

        mutating func parseExpression() throws -> Double {
            var value = try parseTerm()
            while true {
                if consume("+") { value += try parseTerm() }
                else if consume("-") { value -= try parseTerm() }
                else { return value }
            }
        }

        private mutating func parseTerm() throws -> Double {
            var value = try parseUnary()
            while true {
                if consume("*") { value *= try parseUnary() }
                else if consume("/") {
                    let divisor = try parseUnary()
                    guard divisor != 0 else { throw CalculatorError.invalidExpression("division by zero") }
                    value /= divisor
                } else if consume("%") {
                    let divisor = try parseUnary()
                    guard divisor != 0 else { throw CalculatorError.invalidExpression("division by zero") }
                    value.formTruncatingRemainder(dividingBy: divisor)
                } else { return value }
            }
        }

        private mutating func parsePower() throws -> Double {
            var value = try parsePrimary()
            if consume("^") { value = Foundation.pow(value, try parseUnary()) }
            return value
        }

        private mutating func parseUnary() throws -> Double {
            if consume("+") { return try parseUnary() }
            if consume("-") { return -(try parseUnary()) }
            return try parsePower()
        }

        private mutating func parsePrimary() throws -> Double {
            if consume("(") {
                let value = try parseExpression()
                guard consume(")") else { throw CalculatorError.invalidExpression("missing closing parenthesis") }
                return value
            }
            if let number = parseNumber() { return number }
            let name = parseIdentifier()
            if name == "pi" { return .pi }
            if name == "e" { return M_E }
            if name == "tau" { return 2 * .pi }
            guard !name.isEmpty, consume("(") else {
                throw CalculatorError.invalidExpression("expected a number, constant, or function")
            }
            let argument = try parseExpression()
            guard consume(")") else { throw CalculatorError.invalidExpression("missing closing parenthesis") }
            return try apply(name, to: argument)
        }

        private mutating func parseNumber() -> Double? {
            skipWhitespace()
            let start = index
            var sawDigit = false
            while !isAtEnd, input[index].isNumber { sawDigit = true; index += 1 }
            if !isAtEnd, input[index] == "." {
                index += 1
                while !isAtEnd, input[index].isNumber { sawDigit = true; index += 1 }
            }
            if sawDigit, !isAtEnd, input[index] == "e" || input[index] == "E" {
                let exponentStart = index
                index += 1
                if !isAtEnd, input[index] == "+" || input[index] == "-" { index += 1 }
                let digitsStart = index
                while !isAtEnd, input[index].isNumber { index += 1 }
                if digitsStart == index { index = exponentStart }
            }
            guard sawDigit else { index = start; return nil }
            return Double(String(input[start..<index]))
        }

        private mutating func parseIdentifier() -> String {
            skipWhitespace()
            let start = index
            while !isAtEnd, input[index].isLetter || input[index] == "_" { index += 1 }
            return String(input[start..<index]).lowercased()
        }

        private mutating func consume(_ character: Character) -> Bool {
            skipWhitespace()
            guard !isAtEnd, input[index] == character else { return false }
            index += 1
            return true
        }

        private func apply(_ name: String, to value: Double) throws -> Double {
            switch name {
            case "sqrt": return Foundation.sqrt(value)
            case "cbrt": return Foundation.cbrt(value)
            case "abs": return Swift.abs(value)
            case "exp": return Foundation.exp(value)
            case "ln": return Foundation.log(value)
            case "log": return Foundation.log10(value)
            case "log2": return Foundation.log2(value)
            case "sin": return Foundation.sin(value)
            case "cos": return Foundation.cos(value)
            case "tan": return Foundation.tan(value)
            case "asin": return Foundation.asin(value)
            case "acos": return Foundation.acos(value)
            case "atan": return Foundation.atan(value)
            case "sinh": return Foundation.sinh(value)
            case "cosh": return Foundation.cosh(value)
            case "tanh": return Foundation.tanh(value)
            case "floor": return Foundation.floor(value)
            case "ceil": return Foundation.ceil(value)
            case "round": return value.rounded()
            case "sign": return value == 0 ? 0 : (value > 0 ? 1 : -1)
            case "rad": return value * .pi / 180
            case "deg": return value * 180 / .pi
            default: throw CalculatorError.invalidExpression("unknown function '\(name)'")
            }
        }
    }
}