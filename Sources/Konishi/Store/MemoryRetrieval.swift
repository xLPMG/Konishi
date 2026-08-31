import Foundation

/// Local lexical retrieval primitives for long-term memory.
enum MemoryRetrieval {
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
