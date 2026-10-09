import Foundation
import Testing

@testable import Konishi

@Suite("Response suggestion footer")
struct ResponseSuggestionStripperTests {
    @Test("footer is hidden across split stream chunks and yields validated actions")
    func parsesSplitFooter() {
        var stripper = ResponseSuggestionStripper()
        let first = stripper.consume("A complete answer.\n<konishi_act")
        let second = stripper.consume("ions>{\"suggestions\":[{\"type\":\"reply\",\"label\":\"Tell me more\",\"value\":\"Please tell me more about this\"},{\"type\":\"web_search\",\"label\":\"Search the web\",\"value\":\"Qwen local models\"}]}</konishi_actions>")
        let final = stripper.finish()

        #expect(first.visible + second.visible + final.visible == "A complete answer.\n")
        #expect(second.footerFound)
        #expect(second.suggestions.map(\.kind) == [.reply, .webSearch])
        #expect(second.suggestions.map(\.value) == ["Please tell me more about this", "Qwen local models"])
    }

    @Test("search providers encode query text without opening it as a URL")
    func providerSearchURLs() throws {
        for provider in RecommendationSearchProvider.allCases {
            let url = try #require(provider.searchURL(for: "Qwen local models & tools"))
            let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

            #expect(components.queryItems?.first(where: { $0.name == "q" })?.value == "Qwen local models & tools")
            #expect(components.scheme == "https")
            switch provider {
            case .google:
                #expect(components.host == "www.google.com")
                #expect(components.path == "/search")
            case .duckDuckGo:
                #expect(components.host == "duckduckgo.com")
                #expect(components.path == "/")
            }
        }
    }

    @Test("malformed footer is hidden and never becomes an action")
    func malformedFooterFailsClosed() {
        var stripper = ResponseSuggestionStripper()
        let output = stripper.consume("Answer<konishi_actions>{bad json}</konishi_actions>")
        let final = stripper.finish()

        #expect(output.visible + final.visible == "Answer")
        #expect(output.footerFound)
        #expect(output.suggestions.isEmpty)
    }

    @Test("invalid and unsafe suggestions are rejected")
    func rejectsInvalidSuggestions() {
        var stripper = ResponseSuggestionStripper()
        let output = stripper.consume("<konishi_actions>{\"suggestions\":[{\"type\":\"google_search\",\"label\":\"Search\",\"value\":\"safe\\u0000query\"},{\"type\":\"unknown\",\"label\":\"Bad\",\"value\":\"thing\"}]}</konishi_actions>")

        #expect(output.suggestions.isEmpty)
    }

    @Test("messages from before suggestions were added still decode")
    func oldMessagesDecodeWithoutSuggestions() throws {
        let data = Data("{\"role\":\"assistant\",\"content\":\"Hello\"}".utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: data)

        #expect(message.content == "Hello")
        #expect(message.suggestions.isEmpty)
    }
}