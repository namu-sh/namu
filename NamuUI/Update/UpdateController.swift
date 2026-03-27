import Foundation
import AppKit
import Combine
import SwiftUI

#if canImport(Sparkle)
import Sparkle
#endif

// MARK: - UpdateSettings

enum UpdateSettings {
    static let automaticChecksKey        = "SUEnableAutomaticChecks"
    static let automaticallyUpdateKey    = "SUAutomaticallyUpdate"
    static let scheduledCheckIntervalKey = "SUScheduledCheckInterval"
    static let sendProfileInfoKey        = "SUSendProfileInfo"
    static let migrationKey              = "namu.sparkle.migration.v1"
    static let scheduledCheckInterval: TimeInterval = 60 * 60  // 1 hour

    static func apply(to defaults: UserDefaults) {
        defaults.register(defaults: [
            automaticChecksKey: true,
            automaticallyUpdateKey: false,
            scheduledCheckIntervalKey: scheduledCheckInterval,
            sendProfileInfoKey: false,
        ])
        guard !defaults.bool(forKey: migrationKey) else { return }
        defaults.set(true, forKey: automaticChecksKey)
        if let interval = defaults.object(forKey: scheduledCheckIntervalKey) as? NSNumber,
           interval.doubleValue <= 0 {
            defaults.set(scheduledCheckInterval, forKey: scheduledCheckIntervalKey)
        }
        if defaults.object(forKey: automaticallyUpdateKey) == nil {
            defaults.set(false, forKey: automaticallyUpdateKey)
        }
        defaults.set(true, forKey: migrationKey)
    }
}

// MARK: - UpdateController

/// Manages Sparkle auto-update integration.
///
/// Full Sparkle support is compiled in when Sparkle can be imported
/// (`canImport(Sparkle)`). When building without Sparkle the controller
/// falls back to a mock that exercises the same UpdateViewModel state machine.
@MainActor
final class UpdateController: ObservableObject {

    static let shared = UpdateController()

    // MARK: Published

    @Published private(set) var viewModel = UpdateViewModel()

    // MARK: Private

    private var backgroundProbeTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var didStartUpdater = false

#if canImport(Sparkle)
    private var sparkleController: SPUStandardUpdaterController?
    private var sparkleDelegate: SparkleDelegate?
#endif

    // MARK: Init

    private init() {
        UpdateSettings.apply(to: UserDefaults.standard)
    }

    deinit {
        backgroundProbeTimer?.invalidate()
    }

    // MARK: Public API

    var automaticallyChecksForUpdates: Bool {
        get { UserDefaults.standard.bool(forKey: UpdateSettings.automaticChecksKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: UpdateSettings.automaticChecksKey)
#if canImport(Sparkle)
            sparkleController?.updater.automaticallyChecksForUpdates = newValue
#endif
        }
    }

    var lastUpdateCheckDate: Date? {
#if canImport(Sparkle)
        return sparkleController?.updater.lastUpdateCheckDate
#else
        return UserDefaults.standard.object(forKey: "namu.lastUpdateCheck") as? Date
#endif
    }

    func startUpdaterIfNeeded() {
        guard !didStartUpdater else { return }
        didStartUpdater = true
#if canImport(Sparkle)
        startSparkleUpdater()
#else
        startMockUpdater()
#endif
    }

    func checkForUpdates() {
        guard !viewModel.isChecking else { return }
#if canImport(Sparkle)
        if let ctrl = sparkleController {
            ctrl.checkForUpdates(nil)
            return
        }
#endif
        runMockCheck()
    }

    func installUpdate() {
        guard viewModel.state.isInstallable else { return }
        // Sparkle drives installation through its own UI after the user confirms
        // via the standard updater controller. Nothing further required here.
    }

    // MARK: - Sparkle integration

#if canImport(Sparkle)
    private func startSparkleUpdater() {
        let delegate = SparkleDelegate(viewModel: viewModel)
        self.sparkleDelegate = delegate

        let ctrl = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        self.sparkleController = ctrl

        ctrl.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        ctrl.updater.updateCheckInterval = UpdateSettings.scheduledCheckInterval

        do {
            try ctrl.updater.start()
            scheduleBackgroundProbe(ctrl: ctrl)
        } catch {
            viewModel.state = .error(message: error.localizedDescription)
        }
    }

    private func scheduleBackgroundProbe(ctrl: SPUStandardUpdaterController) {
        guard automaticallyChecksForUpdates else { return }
        backgroundProbeTimer?.invalidate()
        backgroundProbeTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateSettings.scheduledCheckInterval,
            repeats: true
        ) { [weak self, weak ctrl] _ in
            guard let self, self.automaticallyChecksForUpdates, let ctrl else { return }
            ctrl.updater.checkForUpdateInformation()
        }
    }
#endif

    // MARK: - Mock fallback (no Sparkle)

    private func startMockUpdater() {
        guard automaticallyChecksForUpdates else { return }
        backgroundProbeTimer = Timer.scheduledTimer(
            withTimeInterval: UpdateSettings.scheduledCheckInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.runMockCheck() }
        }
    }

    private func runMockCheck() {
        viewModel.isChecking = true
        viewModel.state = .checking
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.viewModel.isChecking = false
            UserDefaults.standard.set(Date(), forKey: "namu.lastUpdateCheck")
            self.viewModel.state = .upToDate
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                if case .upToDate = self.viewModel.state {
                    self.viewModel.state = .idle
                }
            }
        }
    }
}

// MARK: - SparkleDelegate

#if canImport(Sparkle)
private final class SparkleDelegate: NSObject, SPUUpdaterDelegate {
    let viewModel: UpdateViewModel

    init(viewModel: UpdateViewModel) {
        self.viewModel = viewModel
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.viewModel.recordDetectedUpdate(version: item.displayVersionString)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Task { @MainActor in
            self.viewModel.clearDetectedUpdate()
            self.viewModel.state = .upToDate
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    if case .upToDate = self.viewModel.state {
                        self.viewModel.state = .idle
                    }
                }
            }
        }
    }

    // Suppress Sparkle's built-in permission dialog — handled in Settings.
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        return false
    }
}
#endif
