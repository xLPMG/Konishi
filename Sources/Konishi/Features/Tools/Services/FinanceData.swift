import Foundation

enum FinanceData {
    struct Point: Codable, Equatable, Sendable {
        let date: String
        let value: Double
    }

    struct Match: Codable, Equatable, Sendable {
        let symbol: String
        let name: String
        let exchange: String
        let type: String
        let currency: String?
        let url: String
    }

    struct Position: Codable, Equatable, Sendable {
        let name: String
        let marketValue: Double
        let weight: Double
        let assetClass: String?
    }

    struct Result: Codable, Equatable, Sendable {
        let kind: String
        let title: String
        let source: String
        let sourceUrl: String?
        let note: String?
        let asOf: String?
        let symbol: String?
        let exchange: String?
        let currency: String?
        let price: Double?
        let previousClose: Double?
        let change: Double?
        let changePercent: Double?
        let points: [Point]?
        let matches: [Match]?
        let positions: [Position]?
        let totalValue: Double?
        let contributionTotal: Double?
        let projectedNominal: Double?
        let projectedReal: Double?
        let concentration: Double?

        var sourceURL: String? { sourceUrl }

        init(
            kind: String, title: String, source: String, sourceURL: String? = nil,
            note: String? = nil, asOf: String? = nil, symbol: String? = nil,
            exchange: String? = nil, currency: String? = nil, price: Double? = nil,
            previousClose: Double? = nil, change: Double? = nil, changePercent: Double? = nil,
            points: [Point]? = nil, matches: [Match]? = nil, positions: [Position]? = nil,
            totalValue: Double? = nil, contributionTotal: Double? = nil,
            projectedNominal: Double? = nil, projectedReal: Double? = nil,
            concentration: Double? = nil
        ) {
            self.kind = kind
            self.title = title
            self.source = source
            self.sourceUrl = sourceURL
            self.note = note
            self.asOf = asOf
            self.symbol = symbol
            self.exchange = exchange
            self.currency = currency
            self.price = price
            self.previousClose = previousClose
            self.change = change
            self.changePercent = changePercent
            self.points = points
            self.matches = matches
            self.positions = positions
            self.totalValue = totalValue
            self.contributionTotal = contributionTotal
            self.projectedNominal = projectedNominal
            self.projectedReal = projectedReal
            self.concentration = concentration
        }
    }

    struct HoldingInput: Decodable, Sendable {
        let name: String
        let marketValue: Double
        var assetClass: String?
    }

    struct PortfolioInput: Decodable, Sendable {
        let currency: String
        let holdings: [HoldingInput]
    }

    struct ScenarioInput: Decodable, Sendable {
        let currency: String
        let initialAmount: Double
        let monthlyContribution: Double
        let years: Int
        let annualReturnPercent: Double
        let annualFeePercent: Double
        let inflationPercent: Double
    }

    private struct SearchResponse: Decodable {
        var quotes: [SearchQuote]?
    }

    private struct SearchQuote: Decodable {
        var symbol: String?
        var shortName: String?
        var longName: String?
        var exchange: String?
        var exchangeName: String?
        var fullExchangeName: String?
        var quoteType: String?
        var currency: String?

        enum CodingKeys: String, CodingKey {
            case symbol, exchange, currency, exchangeName, fullExchangeName
            case shortName = "shortname"
            case longName = "longname"
            case quoteType = "quoteType"
        }
    }

    private struct ChartResponse: Decodable {
        var chart: ChartBody
    }

    private struct ChartBody: Decodable {
        var result: [ChartResult]?
        var error: ChartError?
    }

    private struct ChartError: Decodable {
        var description: String?
    }

    private struct ChartResult: Decodable {
        var meta: ChartMeta
        var timestamp: [Int]?
        var indicators: Indicators?
    }

    private struct ChartMeta: Decodable {
        var symbol: String?
        var currency: String?
        var exchangeName: String?
        var fullExchangeName: String?
        var longName: String?
        var shortName: String?
        var regularMarketPrice: Double?
        var regularMarketTime: Int?
        var chartPreviousClose: Double?
        var previousClose: Double?
    }

    private struct Indicators: Decodable {
        var quote: [DailyQuote]?
    }

    private struct DailyQuote: Decodable {
        var close: [Double?]?
    }

    private enum FinanceError: LocalizedError {
        case invalid(String)
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .invalid(let message), .unavailable(let message): message
            }
        }
    }

    private static let yahooSource = "Yahoo Finance public chart API; quotes may be delayed"
    private static let fredSource = "Federal Reserve Bank of St. Louis FRED"

    static func encode(_ result: Result) -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(result) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func lookup(identifier: String, identifierType: String?) async throws -> Result {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw FinanceError.invalid("Enter a ticker, ISIN, or WKN.") }
        let quotes = try await searchQuotes(value)
        let matches = quotes.prefix(10).compactMap { quote -> Match? in
            guard let symbol = quote.symbol, !symbol.isEmpty else { return nil }
            let name = quote.longName ?? quote.shortName ?? symbol
            let exchange = quote.fullExchangeName ?? quote.exchangeName ?? quote.exchange ?? "Unknown exchange"
            let type = quote.quoteType ?? "Unknown"
            return Match(
                symbol: symbol, name: name, exchange: exchange, type: type,
                currency: quote.currency, url: quoteURL(symbol))
        }
        let label = identifierType.map { "\($0.uppercased()) \(value)" } ?? value
        return Result(
            kind: "matches", title: "Matches for \(label)", source: yahooSource,
            sourceURL: "https://finance.yahoo.com/", matches: matches)
    }

    static func quote(identifier: String, identifierType: String?, exchange: String?) async throws -> Result {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw FinanceError.invalid("Enter a ticker, ISIN, or WKN.") }
        let quotes = try await searchQuotes(value)
        let exchangeFilter = exchange?.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = quotes.filter { quote in
            guard let exchangeFilter, !exchangeFilter.isEmpty else { return true }
            return quote.exchange?.localizedCaseInsensitiveContains(exchangeFilter) == true
                || quote.exchangeName?.localizedCaseInsensitiveContains(exchangeFilter) == true
                || quote.fullExchangeName?.localizedCaseInsensitiveContains(exchangeFilter) == true
        }
        let exact = candidates.filter { $0.symbol?.caseInsensitiveCompare(value) == .orderedSame }
        let chosen: SearchQuote?
        if exact.count == 1 { chosen = exact[0] }
        else if exact.count > 1 { chosen = nil }
        else if candidates.count == 1 { chosen = candidates[0] }
        else { chosen = nil }

        guard let chosen, let symbol = chosen.symbol else {
            let alternatives = candidates.prefix(10).compactMap { quote -> Match? in
                guard let symbol = quote.symbol else { return nil }
                return Match(
                    symbol: symbol, name: quote.longName ?? quote.shortName ?? symbol,
                    exchange: quote.fullExchangeName ?? quote.exchangeName ?? quote.exchange ?? "Unknown exchange",
                    type: quote.quoteType ?? "Unknown", currency: quote.currency,
                    url: quoteURL(symbol))
            }
            let typeLabel = identifierType.map { " (\($0.uppercased()))" } ?? ""
            return Result(
                kind: "matches", title: "Choose a security for \(value)\(typeLabel)",
                source: yahooSource, sourceURL: "https://finance.yahoo.com/",
                note: alternatives.isEmpty ? "No matching listings were found." : "More than one listing may match; confirm the exchange before using a quote.",
                matches: alternatives)
        }

        let chart = try await chartResult(symbol: symbol, days: 5)
        let meta = chart.meta
        let price = meta.regularMarketPrice
        let previous = meta.chartPreviousClose ?? meta.previousClose
        let change = price.flatMap { current in previous.map { current - $0 } }
        let changePercent = change.flatMap { delta in previous.flatMap { $0 == 0 ? nil : delta / $0 * 100 } }
        let asOf = meta.regularMarketTime.map(isoDate)
        let displayName = meta.longName ?? meta.shortName ?? chosen.longName ?? chosen.shortName ?? symbol
        return Result(
            kind: "quote", title: displayName, source: yahooSource, sourceURL: quoteURL(symbol),
            note: "Market-data availability and delay depend on the listing and provider.",
            asOf: asOf, symbol: symbol,
            exchange: meta.fullExchangeName ?? meta.exchangeName ?? chosen.exchange,
            currency: meta.currency ?? chosen.currency, price: price, previousClose: previous,
            change: change, changePercent: changePercent)
    }

    static func history(identifier: String, days: Int) async throws -> Result {
        let value = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw FinanceError.invalid("Enter a ticker, ISIN, or WKN.") }
        let matches = try await searchQuotes(value)
        let exact = matches.filter { $0.symbol?.caseInsensitiveCompare(value) == .orderedSame }
        let quote: SearchQuote?
        if exact.count == 1 { quote = exact[0] }
        else if matches.count == 1 { quote = matches[0] }
        else { quote = nil }
        guard let quote, let symbol = quote.symbol else {
            return try await lookup(identifier: value, identifierType: nil)
        }
        let chart = try await chartResult(symbol: symbol, days: min(max(days, 1), 3650))
        let timestamps = chart.timestamp ?? []
        let closes = chart.indicators?.quote?.first?.close ?? []
        let points = zip(timestamps, closes).compactMap { timestamp, close -> Point? in
            guard let close else { return nil }
            return Point(date: dayLabel(timestamp), value: close)
        }
        return Result(
            kind: "history", title: "\(chart.meta.longName ?? quote.longName ?? symbol) price history",
            source: yahooSource, sourceURL: quoteURL(symbol), note: "Daily closing prices; market data may be delayed.",
            asOf: points.last?.date, symbol: symbol,
            exchange: chart.meta.fullExchangeName ?? chart.meta.exchangeName ?? quote.exchange,
            currency: chart.meta.currency ?? quote.currency, points: Array(points.suffix(120)))
    }

    static func economicSeries(seriesID: String, days: Int) async throws -> Result {
        let id = seriesID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard id.range(of: "^[A-Z0-9_.-]{1,40}$", options: .regularExpression) != nil else {
            throw FinanceError.invalid("Use a valid FRED series ID, such as FEDFUNDS, DGS10, CPIAUCSL, or UNRATE.")
        }
        let end = Date()
        let start = end.addingTimeInterval(-Double(min(max(days, 1), 3650)) * 86_400)
        var components = URLComponents(string: "https://fred.stlouisfed.org/graph/fredgraph.csv")!
        components.queryItems = [
            URLQueryItem(name: "id", value: id),
            URLQueryItem(name: "cosd", value: dayLabel(start)),
            URLQueryItem(name: "coed", value: dayLabel(end)),
        ]
        guard let url = components.url else { throw FinanceError.invalid("Could not build the FRED request.") }
        let data = try await get(url)
        let points = parseFREDCSV(String(decoding: data, as: UTF8.self))
        guard !points.isEmpty else {
            throw FinanceError.unavailable("FRED returned no observations for \(id). Check the series ID and date range.")
        }
        let seriesURL = "https://fred.stlouisfed.org/series/\(id)"
        return Result(
            kind: "series", title: "FRED series \(id)", source: fredSource, sourceURL: seriesURL,
            note: "Units and seasonal adjustment depend on the series. Values are observations, not forecasts.",
            asOf: points.last?.date, symbol: id, points: Array(points.suffix(120)))
    }

    static func parseFREDCSV(_ csv: String) -> [Point] {
        csv.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 2, let value = Double(columns[1]), value.isFinite else { return nil }
            let date = String(columns[0]).trimmingCharacters(in: CharacterSet(charactersIn: "\" \t"))
            guard date.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return nil }
            return Point(date: date, value: value)
        }
    }

    static func analyzePortfolio(_ input: PortfolioInput) throws -> Result {
        guard input.holdings.count > 0, input.holdings.count <= 100 else {
            throw FinanceError.invalid("Provide between 1 and 100 portfolio holdings.")
        }
        guard input.currency.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil else {
            throw FinanceError.invalid("Currency must be a three-letter code, and all market values must use that currency.")
        }
        guard input.holdings.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.marketValue.isFinite && $0.marketValue >= 0 }) else {
            throw FinanceError.invalid("Each holding needs a name and a finite, non-negative market value.")
        }
        let total = input.holdings.reduce(0) { $0 + $1.marketValue }
        guard total.isFinite, total > 0 else { throw FinanceError.invalid("Portfolio total must be greater than zero.") }
        let positions = input.holdings.map {
            Position(name: $0.name, marketValue: $0.marketValue, weight: $0.marketValue / total, assetClass: $0.assetClass)
        }.sorted { $0.marketValue > $1.marketValue }
        let hhi = positions.reduce(0) { $0 + $1.weight * $1.weight }
        return Result(
            kind: "portfolio", title: "Portfolio allocation", source: "User-supplied market values",
            note: "Calculated locally. Holdings are not saved or sent to a market-data provider. Concentration (HHI) is the sum of squared holding weights; it is not a risk forecast.",
            currency: input.currency.uppercased(), positions: positions, totalValue: total,
            concentration: hhi)
    }

    static func project(_ input: ScenarioInput) throws -> Result {
        let values = [input.initialAmount, input.monthlyContribution, input.annualReturnPercent,
                      input.annualFeePercent, input.inflationPercent]
        guard values.allSatisfy(\.isFinite), input.initialAmount >= 0, input.monthlyContribution >= 0,
              (1...80).contains(input.years), (-100...100).contains(input.annualReturnPercent),
              (0...20).contains(input.annualFeePercent), (-20...100).contains(input.inflationPercent),
              input.currency.range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil
        else {
            throw FinanceError.invalid("Use non-negative amounts, 1-80 years, annual return -100% to 100%, fee 0-20%, inflation -20% to 100%, and a three-letter currency code.")
        }
        let netAnnualRate = (input.annualReturnPercent - input.annualFeePercent) / 100
        guard netAnnualRate >= -1 else { throw FinanceError.invalid("Return minus fee must be at least -100%.") }
        let monthlyRate = pow(1 + netAnnualRate, 1.0 / 12.0) - 1
        var balance = input.initialAmount
        for _ in 0..<(input.years * 12) {
            balance = balance * (1 + monthlyRate) + input.monthlyContribution
        }
        let contributions = input.initialAmount + input.monthlyContribution * Double(input.years * 12)
        let inflationFactor = pow(1 + input.inflationPercent / 100, Double(input.years))
        let realValue = inflationFactor > 0 ? balance / inflationFactor : 0
        return Result(
            kind: "scenario", title: "Illustrative investment scenario", source: "User-supplied assumptions",
            note: "Deterministic illustration, not a forecast or investment recommendation. Assumes monthly contributions at month-end and a constant return, fee, and inflation rate.",
            currency: input.currency.uppercased(),
            contributionTotal: contributions, projectedNominal: balance, projectedReal: realValue)
    }

    private static func searchQuotes(_ query: String) async throws -> [SearchQuote] {
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v1/finance/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "quotesCount", value: "10"),
            URLQueryItem(name: "newsCount", value: "0"),
        ]
        guard let url = components.url else { throw FinanceError.invalid("Could not build the Yahoo Finance search request.") }
        let data = try await get(url)
        return try JSONDecoder().decode(SearchResponse.self, from: data).quotes ?? []
    }

    private static func chartResult(symbol: String, days: Int) async throws -> ChartResult {
        guard let encodedSymbol = symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FinanceError.invalid("Invalid ticker symbol.")
        }
        var components = URLComponents(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(encodedSymbol)")!
        let now = Date()
        components.queryItems = [
            URLQueryItem(name: "period1", value: String(Int(now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970))),
            URLQueryItem(name: "period2", value: String(Int(now.timeIntervalSince1970))),
            URLQueryItem(name: "interval", value: "1d"),
        ]
        guard let url = components.url else { throw FinanceError.invalid("Could not build the Yahoo Finance chart request.") }
        let data = try await get(url)
        let body = try JSONDecoder().decode(ChartResponse.self, from: data).chart
        if let result = body.result?.first { return result }
        throw FinanceError.unavailable(body.error?.description ?? "Yahoo Finance returned no chart data for \(symbol).")
    }

    private static func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Konishi finance research client", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/csv;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FinanceError.unavailable("The finance data provider returned an invalid response.")
        }
        if http.statusCode == 429 {
            throw FinanceError.unavailable("The finance data provider is rate-limiting requests. Try again later.")
        }
        guard (200...299).contains(http.statusCode) else {
            throw FinanceError.unavailable("The finance data provider returned HTTP \(http.statusCode).")
        }
        return data
    }

    private static func quoteURL(_ symbol: String) -> String {
        "https://finance.yahoo.com/quote/\(symbol.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? symbol)"
    }

    private static func isoDate(_ timestamp: Int) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private static func dayLabel(_ timestamp: Int) -> String {
        dayLabel(Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}