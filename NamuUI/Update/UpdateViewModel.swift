import Foundation
import AppKit
import SwiftUI
import Combine

// MARK: - UpdateState

enum UpdateState: Equatable {
    case idle
    case checking
    case updateAvailable(version: String)
    case downloading(progress: Double)
    case installing
    case upToDate
    case error(message: String)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }

    var isInstallable: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    static func == (lhs: UpdateState, rhs: UpdateState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.checking, .checking): return true
        case (.updateAvailable(let l), .updateAvailable(let r)): return l == r
        case (.downloading(let l), .downloading(let r)): return l == r
        case (.installing, .installing): return true
        case (.upToDate, .upToDate): return true
        case (.error(let l), .error(let r)): return l == r
        default: return false
        }
    }
}

// MARK: - UpdateViewModel

@MainActor
final class UpdateViewModel: ObservableObject {
    @Published var state: UpdateState = .idle
    @Published var isChecking: Bool = false
    @Published var updateAvailable: Bool = false
    @Published var releaseNotes: String? = nil
    @Published var downloadProgress: Double = 0.0
    @Published var currentVersion: String
    @Published var latestVersion: String? = nil
    @Published var errorMessage: String? = nil

    var showsPill: Bool {
        switch state {
        case .idle: return false
        default: return true
        }
    }

    var statusText: String {
        switch state {
        case .idle:
            return ""
        case .checking:
            return "Checking for Updates…"
        case .updateAvailable(let version):
            return "Update Available: \(version)"
        case .downloading(let progress):
            return String(format: "Downloading: %.0f%%", progress * 100)
        case .installing:
            return "Installing…"
        case .upToDate:
            return "Up to Date"
        case .error:
            return "Update Failed"
        }
    }

    var iconName: String? {
        switch state {
        case .idle: return nil
        case .checking: return "arrow.triangle.2.circlepath"
        case .updateAvailable: return "shippingbox.fill"
        case .downloading: return "arrow.down.circle"
        case .installing: return "power.circle"
        case .upToDate: return "checkmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    var iconColor: Color {
        switch state {
        case .updateAvailable: return .accentColor
        case .error: return .orange
        case .upToDate: return .green
        default: return .secondary
        }
    }

    var backgroundColor: Color {
        switch state {
        case .updateAvailable: return .accentColor
        case .error: return .orange.opacity(0.2)
        case .upToDate: return Color(nsColor: .controlBackgroundColor)
        default: return Color(nsColor: .controlBackgroundColor)
        }
    }

    var foregroundColor: Color {
        switch state {
        case .updateAvailable: return .white
        case .error: return .orange
        default: return .primary
        }
    }

    init() {
        self.currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    func recordDetectedUpdate(version: String) {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestVersion = trimmed
        updateAvailable = true
        state = .updateAvailable(version: trimmed)
    }

    func clearDetectedUpdate() {
        latestVersion = nil
        updateAvailable = false
        if case .updateAvailable = state {
            state = .idle
        }
    }
}
