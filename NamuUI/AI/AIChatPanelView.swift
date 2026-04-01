import SwiftUI

// MARK: - ChatMessage

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String  // "user" or "assistant"
    let content: String
    let timestamp: Date
}

// MARK: - AIChatPanelView

struct AIChatPanelView: View {
    @ObservedObject var viewModel: AIChatViewModel
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if !viewModel.isConfigured {
                apiKeySetup
            } else {

            // Messages
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            MessageBubbleView(message: message)
                                .id(message.id)
                        }

                        if viewModel.isProcessing {
                            processingIndicator
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.isProcessing) { _, _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()

            // Input area
            inputArea
            } // end else (configured)
        }
        .frame(width: 320)
        .background(AIChatBackgroundView())
        .onAppear { isInputFocused = true }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text(String(localized: "ai.header.title", defaultValue: "Namu AI"))
                .font(.system(size: 13, weight: .semibold))

            if viewModel.isConfigured, !viewModel.enabledProviders.isEmpty {
                Spacer()

                // Provider picker
                Menu {
                    ForEach(viewModel.enabledProviders) { provider in
                        Button {
                            viewModel.switchProvider(provider)
                        } label: {
                            Label(provider.rawValue, systemImage: provider.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: viewModel.activeProvider.icon)
                            .font(.system(size: 10))
                        Text(viewModel.activeProvider.rawValue)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Model picker
                if viewModel.activeProvider == .custom {
                    Text(viewModel.activeModel)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else if !viewModel.availableModels.isEmpty {
                    Menu {
                        ForEach(viewModel.availableModels, id: \.self) { model in
                            Button(model) {
                                viewModel.switchProvider(viewModel.activeProvider, model: model)
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(viewModel.activeModel)
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - API Key Setup

    private var apiKeySetup: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(localized: "ai.setup.title", defaultValue: "Namu AI"))
                .font(.system(size: 17, weight: .semibold))
            Text(String(localized: "ai.setup.body", defaultValue: "Configure your AI provider in Settings to get started."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(String(localized: "ai.setup.openSettings", defaultValue: "Open Settings")) {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    // MARK: - Processing indicator

    private var processingIndicator: some View {
        HStack(spacing: 6) {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 14, height: 14)
            Text(String(localized: "ai.processing.thinking", defaultValue: "Thinking..."))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
        .id("processing")
    }

    // MARK: - Input area

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "ai.chat.placeholder", defaultValue: "Ask Namu AI..."), text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.05))
                )
                .focused($isInputFocused)
                .onSubmit { sendMessage() }

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty
                                     ? Color.secondary
                                     : Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isProcessing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !viewModel.isProcessing else { return }
        inputText = ""
        Task {
            await viewModel.send(text)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        if viewModel.isProcessing {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("processing", anchor: .bottom)
            }
        } else if let last = viewModel.messages.last {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - MessageBubbleView

private struct MessageBubbleView: View {
    let message: ChatMessage

    private var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }

            if isUser {
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(0.15))
                    )
            } else {
                MarkdownView(content: message.content)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.primary.opacity(0.05))
                    )
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Simple Markdown Renderer

private struct MarkdownView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
        .textSelection(.enabled)
    }

    private var paragraphs: [String] {
        content.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    @ViewBuilder
    private func renderBlock(_ block: String) -> some View {
        let lines = block.components(separatedBy: "\n")
        let firstLine = lines.first ?? block

        if firstLine.hasPrefix("### ") {
            Text(inlineMarkdown(String(firstLine.dropFirst(4))))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.primary)
        } else if firstLine.hasPrefix("## ") {
            Text(inlineMarkdown(String(firstLine.dropFirst(3))))
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.top, 4)
        } else if firstLine.hasPrefix("# ") {
            Text(inlineMarkdown(String(firstLine.dropFirst(2))))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.top, 4)
        } else if firstLine.hasPrefix("---") || firstLine.hasPrefix("⸻") {
            Divider().opacity(0.3)
        } else if lines.allSatisfy({ $0.hasPrefix("- ") || $0.hasPrefix("• ") || $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.enumerated()), id: \.offset) { _, line in
                    let text = line.hasPrefix("- ") ? String(line.dropFirst(2)) : (line.hasPrefix("• ") ? String(line.dropFirst(2)) : line)
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inlineMarkdown(text))
                            .font(.system(size: 13))
                    }
                }
            }
        } else if firstLine.hasPrefix("|") {
            // Table — render as monospaced text
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(lines.filter { !$0.hasPrefix("|---") && !$0.hasPrefix("| ---") }.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            // Regular paragraph — join lines
            Text(inlineMarkdown(lines.joined(separator: "\n")))
                .font(.system(size: 13))
                .foregroundStyle(.primary)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}

// MARK: - Background (matches sidebar material)

private struct AIChatBackgroundView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
