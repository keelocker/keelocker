import SwiftUI

struct SettingsView: View {
    @AppStorage("appearance") private var appearanceRawValue = AppearanceChoice.system.rawValue
    @AppStorage("concealUsernames") private var concealUsernames = false
    @AppStorage("clearClipboard") private var clearClipboard = true

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
        .frame(width: 470, height: 350)
    }
}
