import Foundation
import MLX
import MLXEmbedders
import MLXLLM
import MLXLMCommon

@MainActor
@Observable
final class MLXService {
    var isLLMLoaded = false
    var isEmbedderLoaded = false
    var loadingStatus = ""

    /// Whether a model is configured (even if not currently loaded in memory)
    var hasLLMModel: Bool {
        llmModel != nil
    }

    var hasEmbedderModel: Bool {
        embedderModel != nil
    }

    private var llmContainer: MLXLMCommon.ModelContainer?
    private var embedContainer: MLXEmbedders.ModelContainer?
    private var llmModel: LocalModel?
    private var embedderModel: LocalModel?
    private var idleTask: Task<Void, Never>?

    private static let idleTimeout: UInt64 = 10 * 60 * 1_000_000_000 // 10 minutes in nanoseconds

    // MARK: - Model reference (for lazy loading without immediate load)

    func setLLMModel(_ model: LocalModel) {
        llmModel = model
    }

    func setEmbedderModel(_ model: LocalModel) {
        embedderModel = model
    }

    // MARK: - Loading

    func loadLLM(model: LocalModel) async throws {
        llmModel = model
        loadingStatus = "Loading \(model.name)..."
        defer { loadingStatus = "" }
        let config = MLXLMCommon.ModelConfiguration(directory: model.path)
        llmContainer = try await LLMModelFactory.shared.loadContainer(configuration: config)
        isLLMLoaded = true
        resetIdleTimer()
    }

    func loadEmbedder(model: LocalModel) async throws {
        embedderModel = model
        loadingStatus = "Loading embedder..."
        defer { loadingStatus = "" }
        let config = MLXEmbedders.ModelConfiguration(directory: model.path)
        embedContainer = try await MLXEmbedders.loadModelContainer(configuration: config)
        isEmbedderLoaded = true
        resetIdleTimer()
    }

    // MARK: - Inference (auto-loads if needed)

    func generate(prompt: String, maxTokens: Int = 1024) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task { @MainActor in
                do {
                    try await ensureLLMLoaded()
                } catch {
                    continuation.yield("[Error loading model: \(error.localizedDescription)]")
                    continuation.finish()
                    return
                }

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
                self.resetIdleTimer()
            }
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        try await ensureEmbedderLoaded()

        guard let container = embedContainer else {
            return texts.map { _ in [Float]() }
        }

        var results: [[Float]] = []
        for text in texts {
            let embedding: [Float] = try await container.perform { model, tokenizer, _ in
                let encoded = tokenizer.encode(text: text, addSpecialTokens: true)
                let inputArray = MLXArray(encoded).expandedDimensions(axis: 0)
                let output = model(inputArray, positionIds: nil, tokenTypeIds: nil, attentionMask: nil)

                // Mean pooling over hidden states with L2 normalization
                let meanPooler = MLXEmbedders.Pooling(strategy: .mean)
                let pooled = meanPooler(output, normalize: true)
                let flat = pooled.reshaped(-1)
                eval(flat)
                return flat.asArray(Float.self)
            }
            results.append(embedding)
            MLX.GPU.clearCache()
        }
        resetIdleTimer()
        return results
    }

    // MARK: - Idle unloading

    private func ensureLLMLoaded() async throws {
        guard llmContainer == nil, let model = llmModel else { return }
        try await loadLLM(model: model)
    }

    private func ensureEmbedderLoaded() async throws {
        guard embedContainer == nil, let model = embedderModel else { return }
        try await loadEmbedder(model: model)
    }

    private func resetIdleTimer() {
        idleTask?.cancel()
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: MLXService.idleTimeout)
            guard !Task.isCancelled else { return }
            self?.unloadModels()
        }
    }

    private func unloadModels() {
        if llmContainer != nil {
            llmContainer = nil
            isLLMLoaded = false
        }
        if embedContainer != nil {
            embedContainer = nil
            isEmbedderLoaded = false
        }
        MLX.GPU.clearCache()
    }

    /// Full teardown — prevents lazy reload, unlike unloadModels which keeps model refs
    func unloadAll() {
        idleTask?.cancel()
        idleTask = nil
        llmContainer = nil
        embedContainer = nil
        llmModel = nil
        embedderModel = nil
        isLLMLoaded = false
        isEmbedderLoaded = false
        loadingStatus = ""
        MLX.GPU.clearCache()
    }
}
