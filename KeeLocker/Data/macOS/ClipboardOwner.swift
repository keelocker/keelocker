import AppKit

/// Owns only the latest value copied by this process, without retaining its contents.
@MainActor
final class ClipboardOwner {
    typealias CleanupScheduler = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    static let shared = ClipboardOwner()

    private let pasteboard: NSPasteboard
    private let shouldClear: () -> Bool
    private let scheduleCleanup: CleanupScheduler
    private var ownedChangeCount: Int?

    init(pasteboard: NSPasteboard = .general,
         shouldClear: @escaping () -> Bool = {
             (UserDefaults.standard.object(forKey: "clearClipboard") as? Bool) ?? true
         },
         scheduleCleanup: @escaping CleanupScheduler = { delay, cleanup in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay) { cleanup() }
         }) {
        self.pasteboard = pasteboard
        self.shouldClear = shouldClear
        self.scheduleCleanup = scheduleCleanup
    }

    @discardableResult
    func copy(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        ownedChangeCount = nil
        pasteboard.clearContents()
        guard pasteboard.setString(value, forType: .string) else { return false }
        let changeCount = pasteboard.changeCount
        ownedChangeCount = changeCount
        if shouldClear() {
            scheduleCleanup(30) { [weak self] in self?.clearIfOwned(changeCount) }
        }
        return true
    }

    /// Call only once termination is confirmed; a cancelled Quit keeps its timer.
    func clearOnTermination() {
        guard let ownedChangeCount else { return }
        clearIfOwned(ownedChangeCount)
    }

    private func clearIfOwned(_ changeCount: Int) {
        guard ownedChangeCount == changeCount else { return }
        guard pasteboard.changeCount == changeCount else {
            ownedChangeCount = nil
            return
        }
        guard shouldClear() else { return }
        ownedChangeCount = nil
        pasteboard.clearContents()
    }
}
