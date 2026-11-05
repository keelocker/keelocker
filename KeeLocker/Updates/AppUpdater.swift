import Combine
import Sparkle

/// Owns the native update UI. Sparkle replaces only this app bundle and asks
/// NSApplication to quit, preserving VaultApplicationDelegate's leave guards.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var startupFailure: String?

    private let controller: SPUStandardUpdaterController
    private var observations = Set<AnyCancellable>()
    private var started = false

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] available in
                guard let self else { return }
                canCheckForUpdates = started && available
            }
            .store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &observations)
        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .sink { [weak self] in self?.lastCheck = $0 }
            .store(in: &observations)
    }

    func start() {
        guard !started, !ProcessInfo.processInfo.arguments.contains("--disable-updates"),
              NSClassFromString("XCTestCase") == nil else { return }
        do {
            try controller.updater.start()
            started = true
            canCheckForUpdates = controller.updater.canCheckForUpdates
        } catch {
            startupFailure = "Updates couldn’t start. You can download KeeLocker from GitHub Releases."
        }
    }

    func checkForUpdates() {
        guard started, canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard started else { return }
        controller.updater.automaticallyChecksForUpdates = enabled
    }
}
