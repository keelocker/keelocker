import AppKit
import Darwin

// Watch the directory: KeePassXC and KeeLocker save by replacing the file's inode.
// Watching only the original file would stop working after the first atomic save.
@MainActor
final class VaultFileMonitor {
    private var source: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var invalidated = false
    private let onChange: @MainActor () -> Void
    private let url: URL

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        self.url = url
        let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete, .attrib, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.schedule() }
            }
            source.setCancelHandler { close(descriptor) }
            self.source = source
            source.resume()
        }
        watchCurrentFile()
        // Also check on return from another app, including filesystems that do
        // not deliver vnode events. Hash/decryption remain off the main thread.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedule() }
        }
    }

    private func schedule() {
        guard !invalidated else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard let self, !self.invalidated else { return }
            self.watchCurrentFile()
            self.onChange()
        }
    }

    private func watchCurrentFile() {
        fileSource?.cancel()
        fileSource = nil
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib, .extend], queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.schedule() }
        }
        source.setCancelHandler { close(descriptor) }
        fileSource = source
        source.resume()
    }

    func invalidate() {
        invalidated = true
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        fileSource?.cancel()
        fileSource = nil
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    deinit {
        pending?.cancel()
        source?.cancel()
        fileSource?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }
}
