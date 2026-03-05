import Accelerate
import Foundation

public enum SearchMath {
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        let n = vDSP_Length(a.count)

        vDSP_dotpr(a, 1, b, 1, &dot, n)
        vDSP_svesq(a, 1, &normA, n)
        vDSP_svesq(b, 1, &normB, n)

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    public static func keywordScore(terms: [String], title: String, text: String) -> Float {
        guard !terms.isEmpty else { return 0 }
        let lowerTitle = title.lowercased()
        let lowerText = text.lowercased()
        var matched: Float = 0
        for term in terms {
            if lowerTitle.contains(term) {
                matched += 1.5
            } else if lowerText.contains(term) {
                matched += 1.0
            }
        }
        return min(matched / Float(terms.count), 1.0)
    }
}
