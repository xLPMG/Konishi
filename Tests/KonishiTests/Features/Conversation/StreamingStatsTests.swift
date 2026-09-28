import Foundation
import Testing

@testable import Konishi

@Suite("Streaming stats")
@MainActor
struct StreamingStatsTests {
    @Test("reasoning time counts toward completion rate, but not visible TTFT")
    func reasoningCountsTowardRate() {
        let start = Date(timeIntervalSince1970: 1_000)
        let stats = AppModel.makeStats(
            start: start,
            firstTokenAt: start.addingTimeInterval(2),
            firstGenerationAt: start.addingTimeInterval(1),
            charCount: 40,
            usage: Usage(promptTokens: 10, completionTokens: 60, totalTokens: 70),
            end: start.addingTimeInterval(4))

        #expect(stats.timeToFirstToken == 2)
        #expect(stats.tokensPerSecond == 20)
        #expect(stats.duration == 4)
    }

    @Test("without reasoning, the visible first token starts the rate timer")
    func contentOnlyRate() {
        let start = Date(timeIntervalSince1970: 1_000)
        let first = start.addingTimeInterval(1)
        let stats = AppModel.makeStats(
            start: start, firstTokenAt: first, firstGenerationAt: first,
            charCount: 40, usage: Usage(promptTokens: nil, completionTokens: 30, totalTokens: nil),
            end: start.addingTimeInterval(4))

        #expect(stats.tokensPerSecond == 10)
    }
}