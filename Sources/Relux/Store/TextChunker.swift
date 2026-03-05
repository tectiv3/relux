import Foundation

struct TextChunk: Sendable {
    let index: Int
    let text: String
}

enum TextChunker {
    static func chunk(_ text: String, maxTokens: Int = 500, overlapTokens: Int = 50) -> [TextChunk] {
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        var chunks: [TextChunk] = []
        var currentWords: [String] = []
        var chunkIndex = 0

        for paragraph in paragraphs {
            let words = paragraph.split(separator: " ").map(String.init)
            currentWords.append(contentsOf: words)

            if currentWords.count >= maxTokens {
                let chunkText = currentWords.joined(separator: " ")
                chunks.append(TextChunk(index: chunkIndex, text: chunkText))
                chunkIndex += 1

                // Keep last overlapTokens words for context continuity
                let overlapStart = max(0, currentWords.count - overlapTokens)
                currentWords = Array(currentWords[overlapStart...])
            }
        }

        if !currentWords.isEmpty {
            let chunkText = currentWords.joined(separator: " ")
            chunks.append(TextChunk(index: chunkIndex, text: chunkText))
        }

        return chunks
    }
}
