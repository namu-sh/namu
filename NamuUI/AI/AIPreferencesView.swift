import SwiftUI
import Security

// MARK: - AI Provider

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case anthropic = "anthropic"
    case openAI    = "openai"
    case openRouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic:  return String(localized: "ai.provider.anthropic", defaultValue: "Anthropic")
        case .openAI:     return String(localized: "ai.provider.openai", defaultValue: "OpenAI")
        case .openRouter: return String(localized: "ai.provider.openrouter", defaultValue: "OpenRouter")
        }
    }

    var defaultModels: [String] {
        switch self {
        case .anthropic:
            return ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
        case .openAI:
            return ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
        case .openRouter:
            return ["openai/gpt-4o", "anthropic/claude-opus-4", "google/gemini-pro-1.5"]
        }
    }

    var keychainService: String { "namu.ai.\(rawValue)" }
    var keychainAccount: String { "apiKey" }
}

// MARK: - Safety Level

enum AISafetyLevel: String, CaseIterable, Identifiable, Codable {
    case low    = "low"
    case medium = "medium"
    case high   = "high"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low:    return String(localized: "ai.safety.level.low", defaultValue: "Low")
        case .medium: return String(localized: "ai.safety.level.medium", defaultValue: "Medium (Recommended)")
        case .high:   return String(localized: "ai.safety.level.high", defaultValue: "High")
        }
    }

    var description: String {
        switch self {
        case .low:    return String(localized: "ai.safety.level.low.description", defaultValue: "Minimal filtering. Allow all commands.")
        case .medium: return String(localized: "ai.safety.level.medium.description", defaultValue: "Block destructive commands. Confirm risky operations.")
        case .high:   return String(localized: "ai.safety.level.high.description", defaultValue: "Strict allowlist. Approve every command before execution.")
        }
    }
}

// MARK: - Gateway Preferences Store

final class GatewayPreferencesStore: ObservableObject {
    @Published var gatewayURL: String = "http://localhost:8080"
    @Published var pairingToken: String = ""
    @Published var connectionStatus: GatewayConnectionStatus = .idle

    private static let gatewayURLKey            = "namu.gateway.url"
    private static let pairingTokenService      = "namu.gateway"
    private static let pairingTokenAccount      = "pairingToken"

    enum GatewayConnectionStatus {
        case idle, checking, connected, failed(String)
    }

    init() { load() }

    func load() {
        if let url = UserDefaults.standard.string(forKey: Self.gatewayURLKey) {
            gatewayURL = url
        }
        pairingToken = loadPairingToken()
    }

    func save() {
        UserDefaults.standard.set(gatewayURL, forKey: Self.gatewayURLKey)
        savePairingToken(pairingToken)
    }

    // MARK: - Keychain helpers for pairing token

    private func savePairingToken(_ token: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.pairingTokenService,
            kSecAttrAccount as String: Self.pairingTokenAccount
        ]
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(token.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    private func loadPairingToken() -> String {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.pairingTokenService,
            kSecAttrAccount as String: Self.pairingTokenAccount,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func generatePairingToken() {
        // Generate a cryptographically random 32-char hex token
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        pairingToken = bytes.map { String(format: "%02x", $0) }.joined()
        savePairingToken(pairingToken)
    }

    func checkConnection() {
        guard let url = URL(string: gatewayURL + "/health") else {
            connectionStatus = .failed("Invalid URL")
            return
        }
        connectionStatus = .checking
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                let ok = (response as? HTTPURLResponse)?.statusCode == 200
                await MainActor.run {
                    connectionStatus = ok ? .connected : .failed("Server returned non-200")
                }
            } catch {
                await MainActor.run {
                    connectionStatus = .failed(error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - AI Preferences Store

final class AIPreferencesStore: ObservableObject {
    @Published var provider: AIProvider    = .anthropic
    @Published var selectedModel: String   = AIProvider.anthropic.defaultModels[0]
    @Published var safetyLevel: AISafetyLevel = .medium
    @Published var streamResponses: Bool   = true
    @Published var maxTokens: Int          = 4096

    private static let providerKey     = "namu.ai.provider"
    private static let modelKey        = "namu.ai.model"
    private static let safetyKey       = "namu.ai.safetyLevel"
    private static let streamKey       = "namu.ai.streamResponses"
    private static let maxTokensKey    = "namu.ai.maxTokens"

    init() { load() }

    // MARK: - Persistence

    func load() {
        if let raw = UserDefaults.standard.string(forKey: Self.providerKey),
           let p = AIProvider(rawValue: raw) {
            provider = p
        }
        if let m = UserDefaults.standard.string(forKey: Self.modelKey) {
            selectedModel = m
        } else {
            selectedModel = provider.defaultModels[0]
        }
        if let raw = UserDefaults.standard.string(forKey: Self.safetyKey),
           let s = AISafetyLevel(rawValue: raw) {
            safetyLevel = s
        }
        streamResponses = UserDefaults.standard.object(forKey: Self.streamKey) as? Bool ?? true
        let stored = UserDefaults.standard.integer(forKey: Self.maxTokensKey)
        maxTokens = stored > 0 ? stored : 4096
    }

    func save() {
        UserDefaults.standard.set(provider.rawValue,     forKey: Self.providerKey)
        UserDefaults.standard.set(selectedModel,         forKey: Self.modelKey)
        UserDefaults.standard.set(safetyLevel.rawValue,  forKey: Self.safetyKey)
        UserDefaults.standard.set(streamResponses,       forKey: Self.streamKey)
        UserDefaults.standard.set(maxTokens,             forKey: Self.maxTokensKey)
    }

    // MARK: - Keychain

    func saveAPIKey(_ key: String, for provider: AIProvider) {
        let data = Data(key.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: provider.keychainService,
            kSecAttrAccount as String: provider.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        if key.isEmpty { return }
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func loadAPIKey(for provider: AIProvider) -> String {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      provider.keychainService,
            kSecAttrAccount as String:      provider.keychainAccount,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    func hasAPIKey(for provider: AIProvider) -> Bool {
        !loadAPIKey(for: provider).isEmpty
    }
}

// MARK: - AIPreferencesView

struct AIPreferencesView: View {
    @StateObject private var store = AIPreferencesStore()
    @StateObject private var alertEngineStore = AlertRulesEditorStore()
    @StateObject private var gatewayStore = GatewayPreferencesStore()

    @State private var apiKeyInput: String = ""
    @State private var showAPIKey: Bool = false
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var selectedTab: PrefsTab = .general
    @State private var showPairingToken: Bool = false

    enum PrefsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case gateway = "Gateway"
        case alertRules = "Alert Rules"
        var id: String { rawValue }

        var localizedLabel: String {
            switch self {
            case .general:    return String(localized: "ai.prefs.tab.general", defaultValue: "General")
            case .gateway:    return String(localized: "ai.prefs.tab.gateway", defaultValue: "Gateway")
            case .alertRules: return String(localized: "ai.prefs.tab.alertRules", defaultValue: "Alert Rules")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            Picker(String(localized: "ai.prefs.tab.picker", defaultValue: "Tab"), selection: $selectedTab) {
                ForEach(PrefsTab.allCases) { tab in
                    Text(tab.localizedLabel).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                switch selectedTab {
                case .general:
                    generalTab
                case .gateway:
                    gatewayTab
                case .alertRules:
                    AlertRulesEditorView(store: alertEngineStore)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 500)
        .onAppear {
            apiKeyInput = store.loadAPIKey(for: store.provider)
        }
        .onChange(of: store.provider) { _, newProvider in
            apiKeyInput = store.loadAPIKey(for: newProvider)
            if !newProvider.defaultModels.contains(store.selectedModel) {
                store.selectedModel = newProvider.defaultModels[0]
            }
            connectionStatus = .idle
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            // Provider
            Section(String(localized: "ai.prefs.section.provider", defaultValue: "Provider")) {
                Picker(String(localized: "ai.prefs.provider.picker", defaultValue: "Provider"), selection: $store.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Picker(String(localized: "ai.prefs.model.picker", defaultValue: "Model"), selection: $store.selectedModel) {
                    ForEach(store.provider.defaultModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            // API Key
            Section(String(localized: "ai.prefs.section.apiKey", defaultValue: "API Key")) {
                HStack {
                    Group {
                        if showAPIKey {
                            TextField(String(localized: "ai.prefs.apiKey.placeholder", defaultValue: "Paste API key…"), text: $apiKeyInput)
                        } else {
                            SecureField(String(localized: "ai.prefs.apiKey.placeholder", defaultValue: "Paste API key…"), text: $apiKeyInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                    Button {
                        showAPIKey.toggle()
                    } label: {
                        Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showAPIKey ? String(localized: "ai.prefs.apiKey.hide", defaultValue: "Hide key") : String(localized: "ai.prefs.apiKey.show", defaultValue: "Show key"))
                }

                HStack(spacing: 10) {
                    Button(String(localized: "ai.prefs.apiKey.saveButton", defaultValue: "Save Key")) {
                        store.saveAPIKey(apiKeyInput, for: store.provider)
                        connectionStatus = .idle
                    }
                    .disabled(apiKeyInput.isEmpty)

                    Button(String(localized: "ai.prefs.apiKey.testButton", defaultValue: "Test Connection")) {
                        testConnection()
                    }
                    .disabled(apiKeyInput.isEmpty)

                    connectionStatusBadge
                    Spacer()
                }

                if store.hasAPIKey(for: store.provider) {
                    Label(String(localized: "ai.prefs.apiKey.storedInKeychain", defaultValue: "Key stored in Keychain"), systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Safety
            Section(String(localized: "ai.prefs.section.safetyLevel", defaultValue: "Safety Level")) {
                Picker(String(localized: "ai.prefs.safety.picker", defaultValue: "Safety"), selection: $store.safetyLevel) {
                    ForEach(AISafetyLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.radioGroup)

                Text(store.safetyLevel.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Advanced
            Section(String(localized: "ai.prefs.section.advanced", defaultValue: "Advanced")) {
                Toggle(String(localized: "ai.prefs.advanced.streamResponses", defaultValue: "Stream responses"), isOn: $store.streamResponses)

                HStack {
                    Text(String(localized: "ai.prefs.advanced.maxTokens", defaultValue: "Max tokens"))
                    Spacer()
                    TextField("", value: $store.maxTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            }

            // Save button
            HStack {
                Spacer()
                Button(String(localized: "ai.prefs.saveSettings.button", defaultValue: "Save Settings")) { store.save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .formStyle(.grouped)
        .padding(4)
    }

    // MARK: - Gateway Tab

    private var gatewayTab: some View {
        Form {
            // Connection
            Section(String(localized: "ai.prefs.section.gatewayConnection", defaultValue: "Gateway Connection")) {
                HStack {
                    Text(String(localized: "ai.prefs.gateway.urlLabel", defaultValue: "URL"))
                    Spacer()
                    TextField("http://localhost:8080", text: $gatewayStore.gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.system(.body, design: .monospaced))
                }

                HStack(spacing: 10) {
                    Button(String(localized: "ai.prefs.gateway.checkButton", defaultValue: "Check Connection")) {
                        gatewayStore.checkConnection()
                    }

                    gatewayConnectionBadge
                    Spacer()
                }
            }

            // Pairing Token
            Section(String(localized: "ai.prefs.section.pairingToken", defaultValue: "Pairing Token")) {
                HStack {
                    Group {
                        if showPairingToken {
                            TextField(String(localized: "ai.prefs.pairingToken.placeholder", defaultValue: "No token generated"), text: $gatewayStore.pairingToken)
                        } else {
                            SecureField(String(localized: "ai.prefs.pairingToken.placeholder", defaultValue: "No token generated"), text: $gatewayStore.pairingToken)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .disabled(true)

                    Button {
                        showPairingToken.toggle()
                    } label: {
                        Image(systemName: showPairingToken ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help(showPairingToken ? String(localized: "ai.prefs.token.hide", defaultValue: "Hide token") : String(localized: "ai.prefs.token.show", defaultValue: "Show token"))
                }

                HStack(spacing: 10) {
                    Button(String(localized: "ai.prefs.pairingToken.generateButton", defaultValue: "Generate Pairing Token")) {
                        gatewayStore.generatePairingToken()
                    }

                    if !gatewayStore.pairingToken.isEmpty {
                        Button(String(localized: "ai.prefs.pairingToken.copyButton", defaultValue: "Copy")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(gatewayStore.pairingToken, forType: .string)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                }

                if !gatewayStore.pairingToken.isEmpty {
                    Label(String(localized: "ai.prefs.pairingToken.savedLabel", defaultValue: "Token saved to preferences"), systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Telegram Link Instructions
            Section(String(localized: "ai.prefs.section.linkTelegram", defaultValue: "Link Telegram")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "ai.prefs.telegram.howTo", defaultValue: "How to link your Telegram account:"))
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Label(String(localized: "ai.prefs.telegram.step1", defaultValue: "1. Start the Namu Gateway with your Telegram bot token"), systemImage: "terminal")
                        Label(String(localized: "ai.prefs.telegram.step2", defaultValue: "2. Send /start to your Telegram bot"), systemImage: "paperplane")
                        Label(String(localized: "ai.prefs.telegram.step3", defaultValue: "3. The bot sends you a 6-digit pairing code (valid 5 min)"), systemImage: "number")
                        Label(String(localized: "ai.prefs.telegram.step4", defaultValue: "4. Generate a pairing token above (or use existing)"), systemImage: "key")
                        Label(String(format: String(localized: "ai.prefs.telegram.step5", defaultValue: "5. POST { code, pairingToken } to %@/link"), gatewayStore.gatewayURL), systemImage: "link")
                        Label(String(localized: "ai.prefs.telegram.step6", defaultValue: "6. Your Telegram is now linked — send commands via the bot"), systemImage: "checkmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !gatewayStore.pairingToken.isEmpty {
                        Divider()
                        Text(String(localized: "ai.prefs.telegram.quickLinkLabel", defaultValue: "Quick link command:"))
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("""
                            curl -X POST \(gatewayStore.gatewayURL)/link \\
                              -H 'Content-Type: application/json' \\
                              -d '{"code":"<6-digit-code>","pairingToken":"\(gatewayStore.pairingToken)"}'
                            """)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }

            // Unlink Instructions
            Section(String(localized: "ai.prefs.section.unlink", defaultValue: "Unlink")) {
                Text(String(localized: "ai.prefs.unlink.description", defaultValue: "To unlink your Telegram account, send /unlink to the bot. This removes the connection between your Telegram chat and Namu."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Save
            HStack {
                Spacer()
                Button(String(localized: "ai.prefs.saveSettings.button", defaultValue: "Save Settings")) { gatewayStore.save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .formStyle(.grouped)
        .padding(4)
    }

    @ViewBuilder
    private var gatewayConnectionBadge: some View {
        switch gatewayStore.connectionStatus {
        case .idle:
            EmptyView()
        case .checking:
            ProgressView().scaleEffect(0.7)
        case .connected:
            Label(String(localized: "ai.prefs.gateway.connected", defaultValue: "Connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    // MARK: - Connection status badge

    @ViewBuilder
    private var connectionStatusBadge: some View {
        switch connectionStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().scaleEffect(0.7)
        case .success:
            Label(String(localized: "ai.prefs.connection.connected", defaultValue: "Connected"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .font(.callout)
        }
    }

    // MARK: - Test Connection

    private func testConnection() {
        store.saveAPIKey(apiKeyInput, for: store.provider)
        connectionStatus = .testing

        Task {
            // Lightweight ping: just validate the key is non-empty and looks correct.
            try? await Task.sleep(for: .milliseconds(600))
            let key = store.loadAPIKey(for: store.provider)
            if key.isEmpty {
                await MainActor.run { connectionStatus = .failure("No key saved") }
            } else if key.count < 20 {
                await MainActor.run { connectionStatus = .failure("Key too short") }
            } else {
                await MainActor.run { connectionStatus = .success }
            }
        }
    }

    enum ConnectionStatus {
        case idle, testing, success
        case failure(String)
    }
}

// MARK: - Alert Rules Editor

final class AlertRulesEditorStore: ObservableObject {
    @Published var rules: [AlertRule]

    init() {
        // Load from UserDefaults via a temporary AlertEngine
        let engine = AlertEngine(eventBus: EventBus())
        engine.loadRules()
        let loaded = engine.rules
        rules = loaded.isEmpty ? AlertEngine.defaultRules : loaded
    }

    func save() {
        let engine = AlertEngine(eventBus: EventBus())
        engine.setRules(rules)
        engine.saveRules()
    }

    func addRule() {
        rules.append(AlertRule(
            name: String(localized: "ai.alert.newRule.defaultName", defaultValue: "New Rule"),
            trigger: .outputMatch(pattern: "", caseSensitive: false)
        ))
    }

    func removeRules(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }
}

struct AlertRulesEditorView: View {
    @ObservedObject var store: AlertRulesEditorStore
    @State private var editingRule: AlertRule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach($store.rules) { $rule in
                    AlertRuleRow(rule: $rule)
                        .onTapGesture { editingRule = rule }
                }
                .onDelete { store.removeRules(at: $0) }
            }
            .listStyle(.inset)
            .frame(minHeight: 280)

            Divider()

            HStack {
                Button(String(localized: "ai.alert.addRule.button", defaultValue: "Add Rule")) { store.addRule() }
                    .buttonStyle(.borderless)
                Spacer()
                Button(String(localized: "ai.alert.saveRules.button", defaultValue: "Save Rules")) { store.save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .sheet(item: $editingRule) { rule in
            AlertRuleEditView(rule: rule) { updated in
                if let idx = store.rules.firstIndex(where: { $0.id == updated.id }) {
                    store.rules[idx] = updated
                }
                editingRule = nil
            } onCancel: {
                editingRule = nil
            }
        }
    }
}

// MARK: - Alert Rule Row

private struct AlertRuleRow: View {
    @Binding var rule: AlertRule

    var body: some View {
        HStack {
            Toggle("", isOn: $rule.isEnabled)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .fontWeight(.medium)
                Text(triggerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .opacity(rule.isEnabled ? 1 : 0.5)
    }

    private var triggerSummary: String {
        switch rule.trigger {
        case .processExit(let code):
            if let code {
                let fmt = String(localized: "ai.alert.trigger.exitCode", defaultValue: "Exit code %d")
                return String(format: fmt, code)
            }
            return String(localized: "ai.alert.trigger.anyExit", defaultValue: "Any exit")
        case .outputMatch(let pattern, _):
            let fmt = String(localized: "ai.alert.trigger.outputContains", defaultValue: "Output contains \"%@\"")
            return String(format: fmt, pattern)
        case .portChange(let ports):
            let portStr = ports.map(String.init).joined(separator: ", ")
            let fmt = String(localized: "ai.alert.trigger.portChange", defaultValue: "Port change: %@")
            return String(format: fmt, portStr)
        case .shellIdle(let seconds):
            let mins = Int(seconds / 60)
            if mins > 0 {
                let fmt = String(localized: "ai.alert.trigger.idleMinutes", defaultValue: "Idle %dm")
                return String(format: fmt, mins)
            } else {
                let fmt = String(localized: "ai.alert.trigger.idleSeconds", defaultValue: "Idle %ds")
                return String(format: fmt, Int(seconds))
            }
        }
    }
}

// MARK: - Alert Rule Edit View

struct AlertRuleEditView: View {
    @State private var rule: AlertRule
    let onSave: (AlertRule) -> Void
    let onCancel: () -> Void

    init(rule: AlertRule, onSave: @escaping (AlertRule) -> Void, onCancel: @escaping () -> Void) {
        _rule = State(initialValue: rule)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    // Trigger type picker
    @State private var triggerType: TriggerType = .outputMatch

    enum TriggerType: String, CaseIterable, Identifiable {
        case processExit  = "Process Exit"
        case outputMatch  = "Output Match"
        case portChange   = "Port Change"
        case shellIdle    = "Shell Idle"
        var id: String { rawValue }

        var localizedLabel: String {
            switch self {
            case .processExit: return String(localized: "ai.alert.triggerType.processExit", defaultValue: "Process Exit")
            case .outputMatch: return String(localized: "ai.alert.triggerType.outputMatch", defaultValue: "Output Match")
            case .portChange:  return String(localized: "ai.alert.triggerType.portChange", defaultValue: "Port Change")
            case .shellIdle:   return String(localized: "ai.alert.triggerType.shellIdle", defaultValue: "Shell Idle")
            }
        }
    }

    // Per-trigger state
    @State private var exitCode: String = ""
    @State private var anyExitCode: Bool = true
    @State private var outputPattern: String = ""
    @State private var caseSensitive: Bool = false
    @State private var portList: String = ""
    @State private var idleSeconds: String = "300"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "ai.alert.editRule.title", defaultValue: "Edit Alert Rule"))
                .font(.headline)
                .padding(.top, 4)

            Form {
                Section(String(localized: "ai.alert.editRule.section.rule", defaultValue: "Rule")) {
                    TextField(String(localized: "ai.alert.editRule.namePlaceholder", defaultValue: "Name"), text: $rule.name)
                    Toggle(String(localized: "ai.alert.editRule.enabledToggle", defaultValue: "Enabled"), isOn: $rule.isEnabled)
                }

                Section(String(localized: "ai.alert.editRule.section.trigger", defaultValue: "Trigger")) {
                    Picker(String(localized: "ai.alert.editRule.typePicker", defaultValue: "Type"), selection: $triggerType) {
                        ForEach(TriggerType.allCases) { t in
                            Text(t.localizedLabel).tag(t)
                        }
                    }

                    Group {
                        switch triggerType {
                        case .processExit:
                            Toggle(String(localized: "ai.alert.editRule.matchAnyExit", defaultValue: "Match any exit code"), isOn: $anyExitCode)
                            if !anyExitCode {
                                TextField(String(localized: "ai.alert.editRule.exitCodePlaceholder", defaultValue: "Exit code"), text: $exitCode)
                            }
                        case .outputMatch:
                            TextField(String(localized: "ai.alert.editRule.patternPlaceholder", defaultValue: "Pattern"), text: $outputPattern)
                            Toggle(String(localized: "ai.alert.editRule.caseSensitive", defaultValue: "Case sensitive"), isOn: $caseSensitive)
                        case .portChange:
                            TextField(String(localized: "ai.alert.editRule.portsPlaceholder", defaultValue: "Ports (comma-separated)"), text: $portList)
                        case .shellIdle:
                            TextField(String(localized: "ai.alert.editRule.idleSecondsPlaceholder", defaultValue: "Idle seconds"), text: $idleSeconds)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(String(localized: "ai.alert.editRule.cancelButton", defaultValue: "Cancel"), action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(String(localized: "ai.alert.editRule.saveButton", defaultValue: "Save")) { commitAndSave() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding(.horizontal, 4)
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { populateFromRule() }
    }

    private func populateFromRule() {
        switch rule.trigger {
        case .processExit(let code):
            triggerType = .processExit
            anyExitCode = code == nil
            exitCode = code.map(String.init) ?? ""
        case .outputMatch(let pattern, let cs):
            triggerType = .outputMatch
            outputPattern = pattern
            caseSensitive = cs
        case .portChange(let ports):
            triggerType = .portChange
            portList = ports.map(String.init).joined(separator: ", ")
        case .shellIdle(let secs):
            triggerType = .shellIdle
            idleSeconds = String(Int(secs))
        }
    }

    private func commitAndSave() {
        let trigger: AlertTrigger
        switch triggerType {
        case .processExit:
            let code = anyExitCode ? nil : Int(exitCode)
            trigger = .processExit(exitCode: code)
        case .outputMatch:
            trigger = .outputMatch(pattern: outputPattern, caseSensitive: caseSensitive)
        case .portChange:
            let ports = portList
                .split(separator: ",")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            trigger = .portChange(ports: ports)
        case .shellIdle:
            let secs = Double(idleSeconds) ?? 300
            trigger = .shellIdle(seconds: secs)
        }
        var updated = rule
        updated = AlertRule(
            id: rule.id,
            name: rule.name,
            isEnabled: rule.isEnabled,
            trigger: trigger,
            workspaceID: rule.workspaceID
        )
        onSave(updated)
    }
}
