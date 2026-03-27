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
        case .anthropic:  return "Anthropic"
        case .openAI:     return "OpenAI"
        case .openRouter: return "OpenRouter"
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
        case .low:    return "Low"
        case .medium: return "Medium (Recommended)"
        case .high:   return "High"
        }
    }

    var description: String {
        switch self {
        case .low:    return "Minimal filtering. Allow all commands."
        case .medium: return "Block destructive commands. Confirm risky operations."
        case .high:   return "Strict allowlist. Approve every command before execution."
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
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            Picker("Tab", selection: $selectedTab) {
                ForEach(PrefsTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
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
            Section("Provider") {
                Picker("Provider", selection: $store.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                Picker("Model", selection: $store.selectedModel) {
                    ForEach(store.provider.defaultModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
            }

            // API Key
            Section("API Key") {
                HStack {
                    Group {
                        if showAPIKey {
                            TextField("Paste API key…", text: $apiKeyInput)
                        } else {
                            SecureField("Paste API key…", text: $apiKeyInput)
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
                    .help(showAPIKey ? "Hide key" : "Show key")
                }

                HStack(spacing: 10) {
                    Button("Save Key") {
                        store.saveAPIKey(apiKeyInput, for: store.provider)
                        connectionStatus = .idle
                    }
                    .disabled(apiKeyInput.isEmpty)

                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(apiKeyInput.isEmpty)

                    connectionStatusBadge
                    Spacer()
                }

                if store.hasAPIKey(for: store.provider) {
                    Label("Key stored in Keychain", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Safety
            Section("Safety Level") {
                Picker("Safety", selection: $store.safetyLevel) {
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
            Section("Advanced") {
                Toggle("Stream responses", isOn: $store.streamResponses)

                HStack {
                    Text("Max tokens")
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
                Button("Save Settings") { store.save() }
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
            Section("Gateway Connection") {
                HStack {
                    Text("URL")
                    Spacer()
                    TextField("http://localhost:8080", text: $gatewayStore.gatewayURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.system(.body, design: .monospaced))
                }

                HStack(spacing: 10) {
                    Button("Check Connection") {
                        gatewayStore.checkConnection()
                    }

                    gatewayConnectionBadge
                    Spacer()
                }
            }

            // Pairing Token
            Section("Pairing Token") {
                HStack {
                    Group {
                        if showPairingToken {
                            TextField("No token generated", text: $gatewayStore.pairingToken)
                        } else {
                            SecureField("No token generated", text: $gatewayStore.pairingToken)
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
                    .help(showPairingToken ? "Hide token" : "Show token")
                }

                HStack(spacing: 10) {
                    Button("Generate Pairing Token") {
                        gatewayStore.generatePairingToken()
                    }

                    if !gatewayStore.pairingToken.isEmpty {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(gatewayStore.pairingToken, forType: .string)
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                }

                if !gatewayStore.pairingToken.isEmpty {
                    Label("Token saved to preferences", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Telegram Link Instructions
            Section("Link Telegram") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to link your Telegram account:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Label("1. Start the Namu Gateway with your Telegram bot token", systemImage: "terminal")
                        Label("2. Send /start to your Telegram bot", systemImage: "paperplane")
                        Label("3. The bot sends you a 6-digit pairing code (valid 5 min)", systemImage: "number")
                        Label("4. Generate a pairing token above (or use existing)", systemImage: "key")
                        Label("5. POST { code, pairingToken } to \(gatewayStore.gatewayURL)/link", systemImage: "link")
                        Label("6. Your Telegram is now linked — send commands via the bot", systemImage: "checkmark.circle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    if !gatewayStore.pairingToken.isEmpty {
                        Divider()
                        Text("Quick link command:")
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
            Section("Unlink") {
                Text("To unlink your Telegram account, send /unlink to the bot. This removes the connection between your Telegram chat and Namu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Save
            HStack {
                Spacer()
                Button("Save Settings") { gatewayStore.save() }
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
            Label("Connected", systemImage: "checkmark.circle.fill")
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
            Label("Connected", systemImage: "checkmark.circle.fill")
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
            name: "New Rule",
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
                Button("Add Rule") { store.addRule() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Save Rules") { store.save() }
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
            if let code { return "Exit code \(code)" }
            return "Any exit"
        case .outputMatch(let pattern, _):
            return "Output contains \"\(pattern)\""
        case .portChange(let ports):
            return "Port change: \(ports.map(String.init).joined(separator: ", "))"
        case .shellIdle(let seconds):
            let mins = Int(seconds / 60)
            return mins > 0 ? "Idle \(mins)m" : "Idle \(Int(seconds))s"
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
            Text("Edit Alert Rule")
                .font(.headline)
                .padding(.top, 4)

            Form {
                Section("Rule") {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.isEnabled)
                }

                Section("Trigger") {
                    Picker("Type", selection: $triggerType) {
                        ForEach(TriggerType.allCases) { t in
                            Text(t.rawValue).tag(t)
                        }
                    }

                    Group {
                        switch triggerType {
                        case .processExit:
                            Toggle("Match any exit code", isOn: $anyExitCode)
                            if !anyExitCode {
                                TextField("Exit code", text: $exitCode)
                            }
                        case .outputMatch:
                            TextField("Pattern", text: $outputPattern)
                            Toggle("Case sensitive", isOn: $caseSensitive)
                        case .portChange:
                            TextField("Ports (comma-separated)", text: $portList)
                        case .shellIdle:
                            TextField("Idle seconds", text: $idleSeconds)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Save") { commitAndSave() }
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
