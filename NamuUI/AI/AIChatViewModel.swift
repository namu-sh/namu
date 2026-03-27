import Foundation
import Combine

// MARK: - AIProviderType

enum AIProviderType: String, CaseIterable, Identifiable {
    case claude = "Claude"
    case openai = "OpenAI"
    case gemini = "Gemini"
    case custom = "Custom"

    var id: String { rawValue }
}

// MARK: - AIChatViewModel

@MainActor
final class AIChatViewModel: ObservableObject {

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isProcessing: Bool = false
    @Published var activeProvider: AIProviderType = .claude
    @Published var activeModel: String = "claude-opus-4-6"

    private let namuAI: NamuAI
    private let config = AIProviderConfig.shared
    private var conversationID: UUID?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Computed

    var isConfigured: Bool {
        config.hasAnyEnabled
    }

    var enabledProviders: [AIProviderType] {
        config.enabledProviders
    }

    var availableModels: [String] {
        activeProvider.models
    }

    // MARK: - Init

    init(namuAI: NamuAI) {
        self.namuAI = namuAI
        loadActiveProvider()

        // Re-check configuration when provider settings change
        NotificationCenter.default.publisher(for: AIProviderConfig.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleConfigChange()
            }
            .store(in: &cancellables)
    }

    // MARK: - Provider Switching

    func switchProvider(_ type: AIProviderType, model: String? = nil) {
        activeProvider = type
        activeModel = model ?? type.defaultModel
        applyActiveProvider()
    }

    // MARK: - Send

    func send(_ text: String) async {
        let userMessage = ChatMessage(role: "user", content: text, timestamp: Date())
        messages.append(userMessage)

        isProcessing = true
        defer { isProcessing = false }

        let reply = await namuAI.send(text, conversationID: conversationID)

        if conversationID == nil {
            conversationID = UUID()
        }

        let assistantMessage = ChatMessage(role: "assistant", content: reply, timestamp: Date())
        messages.append(assistantMessage)
    }

    // MARK: - Private

    private func loadActiveProvider() {
        // If NamuAI already has a provider (e.g. from env var), use it
        if namuAI.hasProvider {
            return
        }

        // Pick the first enabled provider
        if let first = enabledProviders.first {
            activeProvider = first
            activeModel = first.defaultModel
            applyActiveProvider()
        }
    }

    private func handleConfigChange() {
        objectWillChange.send()

        // If the currently active provider was disabled, switch to first enabled
        if !enabledProviders.contains(activeProvider) {
            if let first = enabledProviders.first {
                activeProvider = first
                activeModel = first.defaultModel
            }
        }

        applyActiveProvider()
    }

    private func applyActiveProvider() {
        let entry = config.entry(for: activeProvider)
        guard entry.enabled else { return }

        let provider = createProvider(
            type: activeProvider,
            apiKey: entry.apiKey,
            model: activeModel,
            baseURL: entry.baseURL ?? "http://localhost:11434/v1"
        )
        namuAI.setProvider(provider)
    }

    // MARK: - Provider Factory

    private func createProvider(type: AIProviderType, apiKey: String, model: String, baseURL: String) -> any LLMProvider {
        switch type {
        case .claude:
            return ClaudeProvider(apiKey: apiKey, model: model)
        case .openai:
            return OpenAIProvider(apiKey: apiKey, model: model)
        case .gemini:
            return GeminiProvider(apiKey: apiKey, model: model)
        case .custom:
            return CustomProvider(apiKey: apiKey, model: model, baseURL: baseURL)
        }
    }
}
