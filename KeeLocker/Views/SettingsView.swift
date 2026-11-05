import SwiftUI

struct SettingsView: View {
    @ObservedObject private var updates = AppUpdater.shared
    @AppStorage("appearance") private var appearanceRawValue = AppearanceChoice.system.rawValue
    @AppStorage("concealUsernames") private var concealUsernames = false
    @AppStorage("clearClipboard") private var clearClipboard = true
    @AppStorage("automaticallyDownloadWebsiteIcons") private var automaticallyDownloadWebsiteIcons = false

    private var appearance: Binding<AppearanceChoice> {
        Binding(
            get: { AppearanceChoice(rawValue: appearanceRawValue) ?? .system },
            set: { appearanceRawValue = $0.rawValue }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: appearance) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Privacy") {
                Toggle("Conceal usernames in the item list", isOn: $concealUsernames)
                Toggle("Clear copied values automatically", isOn: $clearClipboard)
            }

            Section {
                Toggle("Automatically download website icons", isOn: $automaticallyDownloadWebsiteIcons)
                    .accessibilityIdentifier("settings.automaticWebsiteIcons")
            } header: {
                Text("Website icons")
            } footer: {
                Text("Fill missing icons and refresh downloaded icons when a website changes. Contacts websites over HTTPS and saves icons in the vault. Chosen icons are kept.")
            }

            Section {
                Picker("Update channel", selection: Binding(get: { updates.channel }, set: updates.setChannel)) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .disabled(!updates.canChangeChannel)
                .accessibilityIdentifier("settings.updateChannel")
                Text(updates.channel == .beta
                     ? "Receive stable releases and beta versions. Beta versions may contain unfinished features."
                     : "Receive stable releases only. Switching from Beta waits for a newer stable release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updates.automaticallyChecksForUpdates },
                    set: updates.setAutomaticallyChecksForUpdates
                ))
                .accessibilityIdentifier("settings.automaticUpdates")
                Button("Check for Updates…", action: updates.checkForUpdates)
                    .disabled(!updates.canCheckForUpdates)
                if let lastCheck = updates.lastCheck {
                    LabeledContent("Last checked") {
                        Text(lastCheck, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                if let failure = updates.startupFailure {
                    Text(failure).foregroundStyle(.red)
                    Link("GitHub Releases", destination: URL(string: "https://github.com/keelocker/keelocker/releases")!)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Download signed updates from GitHub. Installation replaces this copy of KeeLocker and restarts the app when you’re ready.")
            }

            Section {
                LabeledContent("Storage", value: "Encrypted KDBX files")
                LabeledContent("Version", value: appVersion)
            } header: {
                Text("About this build")
            } footer: {
                Text("Open and edit existing KeePass vaults. Changes save automatically; an in-memory demo is also available.")
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(width: 470, height: 640)
    }
}
