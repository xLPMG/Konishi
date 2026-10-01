import Foundation

/// Local lexical retrieval primitives for long-term memory.
enum MemoryRetrieval {
    struct ScoredChunk {
        // label is the memory chunk's identifier (scope/file), text is the content of the chunk.
        let chunk: (label: String, text: String)
        let score: Double
        let semanticScore: Double?
        let lexicalScore: Double
        let rawLexicalScore: Double
    }

    /// Combines normalized BM25 with semantic cosine similarity (mapped to [0, 1]) into one score.
    static func hybridScore(semantic: Double, lexical: Double) -> Double {
        0.7 * semantic + 0.3 * lexical
    }

    struct Ranking {
        let scored: [ScoredChunk]
        /// Set when embeddings were unavailable and scoring fell back to BM25 alone.
        let failure: String?
    }

    /// Ranks chunks against a query by hybrid BM25 + embedding score, best first. Chunks below the
    /// threshold are dropped; without an embeddings endpoint, BM25 alone is used.
    @MainActor
    static func rank(
        chunks: [(label: String, text: String)], query: String, cache: EmbeddingCache,
        requestConfig: RequestConfig, hybridThreshold: Double, lexicalThreshold: Double
    ) async -> Ranking {
        let rawLexical = bm25(query: query, documents: chunks.map(\.text))
        let lexical = rawLexical.map(boundedBM25)
        do {
            let (q, blockEmb) = try await cache.embedWithCache(
                query: query, blocks: chunks.map(\.text), requestConfig: requestConfig)
            // Cosine mapped to [0, 1] so it is comparable with bounded BM25.
            let semantic = blockEmb.map { (EmbeddingCache.cosine(q, $0) + 1.0) / 2.0 }
            let scored = chunks.indices
                .map { i in
                    ScoredChunk(
                        chunk: chunks[i],
                        score: hybridScore(semantic: semantic[i], lexical: lexical[i]),
                        semanticScore: semantic[i], lexicalScore: lexical[i],
                        rawLexicalScore: rawLexical[i])
                }
                .filter { $0.score >= hybridThreshold }
                .sorted { $0.score > $1.score }
            return Ranking(scored: scored, failure: nil)
        } catch {
            let scored = chunks.indices
                .map { i in
                    ScoredChunk(
                        chunk: chunks[i], score: lexical[i], semanticScore: nil,
                        lexicalScore: lexical[i], rawLexicalScore: rawLexical[i])
                }
                .filter { $0.score >= lexicalThreshold }
                .sorted { $0.score > $1.score }
            return Ranking(scored: scored, failure: error.localizedDescription)
        }
    }

    /// Groups scored chunks by source file, preserving score order between files.
    static func groupedSections(_ scored: [ScoredChunk]) -> [String] {
        var order: [String] = []
        var byLabel: [String: [String]] = [:]
        for item in scored {
            if byLabel[item.chunk.label] == nil { order.append(item.chunk.label) }
            byLabel[item.chunk.label, default: []].append(item.chunk.text)
        }
        return order.map { "## \($0)\n\((byLabel[$0] ?? []).joined(separator: "\n"))" }
    }

    /// Trace details for the exact bullets injected this turn, in retrieval order.
    static func traceDetail(_ scored: [ScoredChunk]) -> String {
        guard !scored.isEmpty else { return "No memory bullets met the retrieval criteria." }
        return scored.enumerated().map { rank, item in
            let scores: String
            if let semantic = item.semanticScore {
                scores =
                    "hybrid \(String(format: "%.3f", item.score))  semantic \(String(format: "%.3f", semantic))  BM25 \(String(format: "%.3f", item.lexicalScore)) (raw \(String(format: "%.3f", item.rawLexicalScore)))"
            } else {
                scores =
                    "BM25 \(String(format: "%.3f", item.score)) (raw \(String(format: "%.3f", item.rawLexicalScore)))"
            }
            return "\(rank + 1). \(scores)\n   \(item.chunk.label)\n   \(item.chunk.text)"
        }.joined(separator: "\n\n")
    }

    /// Raw BM25 scores for each document.
    static func bm25(query: String, documents: [String]) -> [Double] {
        let queryTerms = tokenize(query)
        let tokenized = documents.map(tokenize)
        guard !queryTerms.isEmpty, !tokenized.isEmpty else {
            return Array(repeating: 0, count: documents.count)
        }

        let documentCount = Double(tokenized.count)
        let averageLength = max(1, Double(tokenized.reduce(0) { $0 + $1.count }) / documentCount)
        let querySet = Set(queryTerms)
        var documentFrequency: [String: Int] = [:]
        for terms in tokenized {
            for term in Set(terms) where querySet.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }

        let k1 = 1.2
        let b = 0.75
        return tokenized.map { terms in
            let frequencies = terms.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
            let lengthFactor = 1 - b + b * Double(terms.count) / averageLength
            return querySet.reduce(0) { score, term in
                let tf = Double(frequencies[term, default: 0])
                guard tf > 0 else { return score }
                let df = Double(documentFrequency[term, default: 0])
                let idf = log(1 + (documentCount - df + 0.5) / (df + 0.5))
                return score + idf * (tf * (k1 + 1)) / (tf + k1 * lengthFactor)
            }
        }
    }

    /// Saturate raw BM25 without making it depend on the current candidate set.
    /// A raw score of 1.5 maps to 0.5; tune this from retrieval traces if needed.
    static func boundedBM25(_ rawScore: Double) -> Double {
        guard rawScore > 0 else { return 0 }
        return rawScore / (rawScore + 1.5)
    }

    private static func tokenize(_ text: String) -> [String] {
        let lowered = text.lowercased()
        let range = NSRange(lowered.startIndex..., in: lowered)
        return tokenPattern.matches(in: lowered, range: range)
            .compactMap { Range($0.range, in: lowered) }
            .map { String(lowered[$0]) }
            .filter { $0.count > 1 && !stopWords.contains($0) }
    }

    /// Word tokens plus the suffixes used by language names such as C++ and C#.
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:\+\+|#)?"#
    )

    /// Conservative English/German function-word list for lexical retrieval.
    private static let stopWords: Set<String> = [
        // English
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by", "can",
        "could", "did", "do", "does", "for", "from", "had", "has", "have", "he", "her",
        "here", "hers", "herself", "him", "himself", "his", "how", "i", "if", "in", "into",
        "is", "it", "its", "itself", "just", "me", "more", "most", "my", "myself", "no",
        "not", "of", "on", "or", "our", "ours", "ourselves", "out", "she", "should", "so",
        "some", "such", "than", "that", "the", "their", "theirs", "them", "themselves", "then",
        "there", "these", "they", "this", "those", "to", "too", "up", "us", "very", "was",
        "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why", "will",
        "with", "would", "you", "your", "yours", "yourself", "yourselves",
        // German
        "aber", "alle", "allem", "allen", "aller", "alles", "als", "also", "am", "an", "ander",
        "andere", "anderem", "anderen", "anderer", "anderes", "auch", "auf", "aus", "bei", "beim",
        "bin", "bis", "bist", "da", "dadurch", "dafür", "daher", "darum", "das", "dass", "daß",
        "dein", "deine", "dem", "den", "denn", "der", "des", "dessen", "dich", "die", "dies",
        "diese", "diesem", "diesen", "dieser", "dieses", "doch", "dort", "durch", "ein", "eine",
        "einem", "einen", "einer", "eines", "er", "es", "etwas", "euch", "für", "hat", "hatte",
        "haben", "hier", "hinter", "ich", "ihm", "ihn", "ihnen", "ihr", "ihre", "ihrem", "ihren",
        "ihrer", "ihres", "im", "in", "indem", "ins", "ist", "ja", "jede", "jedem", "jeden",
        "jeder", "jedes", "jener", "jetzt", "kann", "kein", "keine", "keinem", "keinen", "keiner",
        "keines", "können", "könnte", "machen", "man", "manche", "manchem", "manchen", "mancher",
        "manches", "mein", "meine", "meinem", "meinen", "meiner", "meines", "mich", "mir", "mit",
        "muss", "müssen", "musste", "nach", "nicht", "nichts", "noch", "nun", "nur", "ob", "oder",
        "ohne", "sehr", "sein", "seine", "seinem", "seinen", "seiner", "seines", "selbst", "sich",
        "sie", "sind", "so", "soll", "sollen", "sollte", "sondern", "sonst", "über", "um", "und",
        "uns", "unsere", "unserem", "unseren", "unserer", "unseres", "unter", "vom", "von", "vor",
        "war", "waren", "warst", "was", "weg", "weil", "weiter", "welche", "welchem", "welchen",
        "welcher", "welches", "wenn", "wer", "werde", "werden", "wie", "wieder", "will", "wir",
        "wird", "wo", "wollen", "wollte", "würde", "würden", "zu", "zum", "zur", "zwischen"
    ]
}
