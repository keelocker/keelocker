import SwiftUI
import AppKit
import Carbon

struct UnlockVaultView: View {
    @ObservedObject var store: VaultStore
    let onClose: () -> Void
    @State private var password = ""
    @State private var keyFile: URL?
    @FocusState private var passwordFocused: Bool
    @State private var previousInputSource: TISInputSource?
    @State private var preferredInputSource: TISInputSource?
    @State private var didChooseInputSource = false

    private var isUnlocking: Bool { store.state == .unlocking }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unlock Vault").font(.headline)
            Text(store.fileURL?.lastPathComponent ?? "Vault")
                .foregroundStyle(.secondary)
                .lineLimit(2)

            SecureField("Master Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($passwordFocused)
                .disabled(isUnlocking)
                .onSubmit(unlock)

            HStack {
                Button(keyFile?.lastPathComponent ?? "Choose Key File…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK { keyFile = panel.url }
                }
                if keyFile != nil { Button("Remove") { keyFile = nil } }
            }
            .disabled(isUnlocking)

            if store.canQuickUnlock {
                Button { password = ""; store.unlockWithTouchID() } label: {
                    Label("Unlock with Touch ID", systemImage: "touchid")
                }
                .disabled(isUnlocking)
            }
            if store.canEnableTouchID {
                Text(store.canQuickUnlock
                     ? "After quitting or restarting, enter your master password again."
                     : "Touch ID will be enabled after unlocking and works until you quit KeeLocker.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isUnlocking {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Unlocking…").foregroundStyle(.secondary)
                }
            }
            if let failure = store.failure {
                VStack(alignment: .leading, spacing: 4) {
                    Text(failure.title).fontWeight(.medium)
                    Text(failure.message)
                }
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let failure = store.quickUnlockFailure {
                Text(failure.message).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    password = ""
                    store.lock()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isUnlocking)
            }
        }
        .padding(24)
        .frame(width: 380)
        .interactiveDismissDisabled(isUnlocking)
        .onAppear {
            store.refreshQuickUnlockAvailability()
            passwordFocused = true
        }
        .onChange(of: passwordFocused) { _, focused in
            if focused { preferEnglishInputSource() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshQuickUnlockAvailability()
            if passwordFocused { preferEnglishInputSource() }
        }
        .onDisappear {
            password = ""
            restoreInputSource()
        }
        .onChange(of: store.state) { _, _ in
            if store.failure != nil { passwordFocused = true }
        }
    }

    private func unlock() {
        guard !isUnlocking else { return }
        store.unlock(password: password, keyFile: keyFile)
        password = ""
    }

    private func preferEnglishInputSource() {
        guard !didChooseInputSource, NSApp.isActive else { return }
        didChooseInputSource = true
        guard let english = TISCopyInputSourceForLanguage("en" as CFString)?.takeRetainedValue(),
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              !CFEqual(current, english), TISSelectInputSource(english) == noErr else { return }
        previousInputSource = current
        preferredInputSource = english
    }

    private func restoreInputSource() {
        defer {
            previousInputSource = nil
            preferredInputSource = nil
            didChooseInputSource = false
        }
        // Preserve any layout the user deliberately selected while entering the password.
        guard NSApp.isActive, let previousInputSource, let preferredInputSource,
              let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              CFEqual(current, preferredInputSource) else { return }
        TISSelectInputSource(previousInputSource)
    }
}
