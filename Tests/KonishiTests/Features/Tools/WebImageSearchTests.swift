import Foundation
import Testing

@testable import Konishi

@Suite("Web image search")
struct WebImageSearchTests {
    @Test("extracts DuckDuckGo image token")
    func extractsToken() {
        #expect(WebResearch.imageSearchToken(from: #"vqd=4-123456789"#) == "4-123456789")
    }

    @Test("decodes image results with source and image URLs")
    func decodesResults() {
        let json = Data(#"{"results":[{"title":"Blue jay","image":"https://images.example/bird.jpg","thumbnail":"https://thumbs.example/bird.jpg","url":"https://example/page"}]}"#.utf8)
        let results = WebResearch.parseImageSearchResponse(json)
        #expect(results?.count == 1)
        #expect(results?.first?.title == "Blue jay")
        #expect(results?.first?.image == "https://images.example/bird.jpg")
        #expect(results?.first?.url == "https://example/page")
    }

    @Test("accepts supported image bytes and rejects non-images")
    func identifiesImageMimeTypes() {
        #expect(WebResearch.imageMimeType(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == "image/png")
        #expect(WebResearch.imageMimeType(for: Data([0xFF, 0xD8, 0xFF])) == "image/jpeg")
        #expect(WebResearch.imageMimeType(for: Data("not an image".utf8)) == nil)
    }
}