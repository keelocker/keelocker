import SwiftUI

@main
struct KeeLockerApp: App {
    @NSApplicationDelegateAdaptor(VaultApplicationDelegate.self) private var delegate
    @AppStorage("appearance") private var appearanceRawValue = AppearanceChoice.system.rawValue
    @FocusedValue(\.createVaultItem) private var createVaultItem
    @FocusedValue(\.createVaultGroup) private var createVaultGroup
    @FocusedValue(\.openVault) private var openVault
    @FocusedValue(\.saveVault) private var saveVault
    @FocusedValue(\.saveVaultAs) private var saveVaultAs

    private var appearance: AppearanceChoice {
        AppearanceChoice(rawValue: appearanceRawValue) ?? .system
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1_180, height: 760)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Vault…") { openVault?() }
                    .disabled(openVault == nil)
                    .keyboardShortcut("o", modifiers: .command)
                Button("New login") {
                    createVaultItem?()
                }
                .disabled(createVaultItem == nil)
                .keyboardShortcut("n", modifiers: .command)
                Button("New Group…") { createVaultGroup?() }
                    .disabled(createVaultGroup == nil)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { saveVault?() }
                    .keyboardShortcut("s").disabled(saveVault == nil)
                Button("Save As…") { saveVaultAs?() }
                    .keyboardShortcut("s", modifiers: [.command, .shift]).disabled(saveVaultAs == nil)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

private struct CreateVaultItemFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct CreateVaultGroupFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct OpenVaultFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SaveVaultFocusedValueKey: FocusedValueKey { typealias Value = () -> Void }
private struct SaveVaultAsFocusedValueKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var createVaultGroup: (() -> Void)? {
        get { self[CreateVaultGroupFocusedValueKey.self] }
        set { self[CreateVaultGroupFocusedValueKey.self] = newValue }
    }
    var saveVault: (() -> Void)? {
        get { self[SaveVaultFocusedValueKey.self] }
        set { self[SaveVaultFocusedValueKey.self] = newValue }
    }
    var saveVaultAs: (() -> Void)? {
        get { self[SaveVaultAsFocusedValueKey.self] }
        set { self[SaveVaultAsFocusedValueKey.self] = newValue }
    }
    var openVault: (() -> Void)? {
        get { self[OpenVaultFocusedValueKey.self] }
        set { self[OpenVaultFocusedValueKey.self] = newValue }
    }
    var createVaultItem: (() -> Void)? {
        get { self[CreateVaultItemFocusedValueKey.self] }
        set { self[CreateVaultItemFocusedValueKey.self] = newValue }
    }
}
