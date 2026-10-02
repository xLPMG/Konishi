import Foundation
import Testing

@testable import Konishi

@Suite("Calculator")
struct CalculatorTests {
    @Test("arithmetic follows precedence and associativity")
    func arithmeticPrecedence() throws {
        #expect(try Calculator.evaluate("2 + 3 * 4") == 14)
        #expect(try Calculator.evaluate("(2 + 3) * 4") == 20)
        #expect(abs(try Calculator.evaluate("20 / 3 % 2") - 2.0 / 3.0) < 1e-12)
        #expect(try Calculator.evaluate("2 ^ 3 ^ 2") == 512)
        #expect(try Calculator.evaluate("-2^2") == -4)
        #expect(try Calculator.evaluate("2^-2") == 0.25)
    }

    @Test("numbers, whitespace, constants, and unary signs are accepted")
    func numberForms() throws {
        #expect(try Calculator.evaluate("  +.5e2 - 1.25E+1 ") == 37.5)
        #expect(try Calculator.evaluate("pi + e + tau") == 3 * Double.pi + M_E)
        #expect(try Calculator.evaluate("--3") == 3)
    }

    @Test("supported functions evaluate their single argument")
    func functions() throws {
        #expect(try Calculator.evaluate("sqrt(9) + cbrt(8)") == 5)
        #expect(try Calculator.evaluate("abs(-3) + exp(0)") == 4)
        #expect(try Calculator.evaluate("ln(e)") == 1)
        #expect(try Calculator.evaluate("log(100) + log2(8)") == 5)
        #expect(abs(try Calculator.evaluate("sin(rad(30))") - 0.5) < 1e-12)
        #expect(try Calculator.evaluate("deg(pi)") == 180)
        #expect(try Calculator.evaluate("sign(-2) + sign(0) + sign(2)") == 0)
        #expect(try Calculator.evaluate("floor(1.8) + ceil(1.2) + round(1.5)") == 5)
    }

    @Test("invalid syntax and non-finite results are rejected")
    func invalidExpressions() {
        for expression in ["", "1 +", "(1 + 2", "1 2", "unknown(1)", "1 / 0", "1 % 0", "sqrt(-1)", "1e999"] {
            #expect(throws: CalculatorError.self) {
                try Calculator.evaluate(expression)
            }
        }
    }

    @Test("formatting omits decimals only for small integral values")
    func formatting() {
        #expect(Calculator.format(4) == "4")
        #expect(Calculator.format(-2) == "-2")
        #expect(Calculator.format(0.125) == "0.125")
        #expect(Calculator.format(Double(Int64.max)) != String(Int64.max))
    }
}