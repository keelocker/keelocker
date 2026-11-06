import Combine
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta

    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Beta" }
    var allowedChannels: Set<String> { self == .beta ? ["beta"] : [] }

    static func resolve(saved: String?, bundled: String?) -> UpdateChannel {
        saved.flatMap(Self.init(rawValue:)) ?? bundled.flatMap(Self.init(rawValue:)) ?? .stable
    }
}

/// Owns the native update UI. Sparkle replaces only this app bundle and asks
/// NSApplication to quit, preserving VaultApplicationDelegate's leave guards.
@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var startupFailure: String?
    @Published private(set) var channel: UpdateChannel

    private let defaults: UserDefaults
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var observations = Set<AnyCancellable>()
    private var started = false
    var canChangeChannel: Bool { !started || canCheckForUpdates }

    init(defaults: UserDefaults = .standard, bundledChannel: String? = Bundle.main.object(forInfoDictionaryKey: "KeeLockerDefaultUpdateChannel") as? String) {
        self.defaults = defaults
        channel = UpdateChannel.resolve(saved: defaults.string(forKey: "updateChannel"), bundled: bundledChannel)
        super.init()
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

    func setChannel(_ selected: UpdateChannel) {
        guard selected != channel, canChangeChannel else { return }
        defaults.set(selected.rawValue, forKey: "updateChannel")
        channel = selected
        if started { controller.updater.resetUpdateCycleAfterShortDelay() }
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel.allowedChannels
    }
}
