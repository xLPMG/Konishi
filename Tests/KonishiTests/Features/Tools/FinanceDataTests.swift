import Foundation
import Testing
@testable import Konishi

struct FinanceDataTests {
    @Test func parsesFREDObservationsAndSkipsMissingValues() {
        let csv = """
        observation_date,FEDFUNDS
        2025-01-01,4.33
        2025-01-02,.
        2025-01-03,4.25
        """

        let points = FinanceData.parseFREDCSV(csv)

        #expect(points.count == 2)
        #expect(points[0].date == "2025-01-01")
        #expect(points[0].value == 4.33)
        #expect(points[1].date == "2025-01-03")
    }

    @Test func portfolioWeightsAndConcentrationUseProvidedValues() throws {
        let result = try FinanceData.analyzePortfolio(.init(currency: "EUR", holdings: [
            .init(name: "Equities", marketValue: 750),
            .init(name: "Bonds", marketValue: 250),
        ]))

        #expect(result.totalValue == 1000)
        #expect(result.positions?.map(\.weight) == [0.75, 0.25])
        #expect(result.concentration == 0.625)
    }

    @Test func scenarioProjectsContributionsAndInflationAdjustedValue() throws {
        let result = try FinanceData.project(.init(
            currency: "EUR", initialAmount: 1000, monthlyContribution: 100,
            years: 1, annualReturnPercent: 0, annualFeePercent: 0, inflationPercent: 0))

        #expect(result.contributionTotal == 2200)
        #expect(result.projectedNominal == 2200)
        #expect(result.projectedReal == 2200)
    }

    @Test func scenarioRejectsInvalidRates() {
        #expect(throws: Error.self) {
            try FinanceData.project(.init(
                currency: "EUR", initialAmount: 1000, monthlyContribution: 100,
                years: 1, annualReturnPercent: 0, annualFeePercent: 0, inflationPercent: -100))
        }
    }

    @Test func scenarioAllowsTotalLossAssumption() throws {
        let result = try FinanceData.project(.init(
            currency: "EUR", initialAmount: 1000, monthlyContribution: 100,
            years: 1, annualReturnPercent: -100, annualFeePercent: 0, inflationPercent: 0))

        #expect(result.projectedNominal == 100)
        #expect(result.contributionTotal == 2200)
    }

    @Test func financeToolArgumentsAndArtifactRoundTrip() throws {
        let argumentData = Data(#"{"series_id":"FEDFUNDS","days":30}"#.utf8)
        let seriesArguments = try Wire.decoder.decode(ToolArguments.FinanceSeries.self, from: argumentData)
        #expect(seriesArguments.seriesId == "FEDFUNDS")

        let expected = FinanceData.Result(
            kind: "quote", title: "Example Inc.", source: "Yahoo Finance",
            sourceURL: "https://finance.yahoo.com/quote/EXM", asOf: "2026-10-06T12:00:00Z",
            symbol: "EXM", currency: "USD", price: 12.5)
        let artifact = ToolArtifact.make(
            toolName: "finance_quote", arguments: "{}", result: FinanceData.encode(expected), sources: [])

        guard case .finance(let decoded)? = artifact else {
            #expect(Bool(false))
            return
        }
        #expect(decoded.sourceURL == expected.sourceURL)
        #expect(decoded.asOf == expected.asOf)
        #expect(decoded.price == expected.price)
    }
}