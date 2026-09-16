import SwiftUI

@main
struct KeeLockerApp: App {
    @AppStorage("appearance") private var appearanceRawValue = AppearanceChoice.system.rawValue
    @FocusedValue(\.createVaultItem) private var createVaultItem

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
                Button("New login") {
                    createVaultItem?()
                }
                .disabled(createVaultItem == nil)
                .keyboardShortcut("n", modifiers: .command)
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

extension FocusedValues {
    var createVaultItem: (() -> Void)? {
        get { self[CreateVaultItemFocusedValueKey.self] }
        set { self[CreateVaultItemFocusedValueKey.self] = newValue }
    }
}
