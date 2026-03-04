import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXEmbedders

@MainActor
@Observable
final class MLXService {
    var isLLMLoaded = false
    var isEmbedderLoaded = false
    var loadingStatus = ""

    private var llmContainer: MLXLMCommon.ModelContainer?
    private var embedContainer: MLXEmbedders.ModelContainer?

    func loadLLM(model: LocalModel) async throws {
        loadingStatus = "Loading \(model.name)..."
        let config = MLXLMCommon.ModelConfiguration(directory: model.path)
        llmContainer = try await LLMModelFactory.shared.loadContainer(configuration: config)
        isLLMLoaded = true
        loadingStatus = ""
    }

    func generate(prompt: String, maxTokens: Int = 1024) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task { @MainActor in
                guard let container = llmContainer else {
                    continuation.finish()
                    return
                }
                do {
                    let userInput = UserInput(prompt: prompt)
                    let lmInput = try await container.prepare(input: userInput)
                    let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.7)
                    let stream = try await container.generate(input: lmInput, parameters: params)
                    for await generation in stream {
                        if let text = generation.chunk {
                            continuation.yield(text)
                        }
                    }
                } catch {
                    continuation.yield("[Error: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
        }
    }

    func loadEmbedder(model: LocalModel) async throws {
        loadingStatus = "Loading embedder..."
        let config = MLXEmbedders.ModelConfiguration(directory: model.path)
        embedContainer = try await MLXEmbedders.loadModelContainer(configuration: config)
        isEmbedderLoaded = true
        loadingStatus = ""
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let container = embedContainer else {
            return texts.map { _ in [Float]() }
        }

        var results: [[Float]] = []
        for text in texts {
            let embedding: [Float] = try await container.perform { model, tokenizer, pooler in
                let encoded = tokenizer.encode(text: text)
                let inputArray = MLXArray(encoded).expandedDimensions(axis: 0)
                let output = model(inputArray, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)
                let pooled = pooler(output, normalize: true)
                let flat = pooled.reshaped(-1)
                eval(flat)
                return flat.asArray(Float.self)
            }
            results.append(embedding)
        }
        return results
    }
}
