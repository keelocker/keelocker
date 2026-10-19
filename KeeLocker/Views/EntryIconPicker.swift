import SwiftUI

struct EntryIconPicker: View {
    let selected: VaultEntryIcon?
    let customIcons: [VaultCustomIcon]
    let onSelect: (VaultEntryIcon) -> Void
    let onImport: () -> Void
    var canDownload = false
    var isDownloading = false
    var onDownload: (() -> Void)? = nil
    @State private var search = ""

    private let columns = Array(repeating: GridItem(.fixed(44), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose icon").font(.headline)
            TextField("Search icons", text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("icon.search")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Standard icons").font(.subheadline).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(StandardVaultIcon.all.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { icon in
                            choice(.builtIn(icon.id), name: icon.name, identifier: "icon.standard.\(icon.id)")
                        }
                    }
                    if !customIcons.isEmpty {
                        Text("Custom icons").font(.subheadline).foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(customIcons.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { icon in
                                choice(.custom(icon), name: icon.name, identifier: "icon.custom.\(icon.id)")
                            }
                        }
                    }
                }
                .padding(3)
            }
            .frame(height: 284)
            Divider()
            if let onDownload {
                HStack(spacing: 8) {
                    if isDownloading { ProgressView().controlSize(.mini) }
                    Button(action: onDownload) {
                        Label(isDownloading ? "Cancel download" : "Download from website", systemImage: "arrow.down.circle")
                    }
                    .disabled(!canDownload && !isDownloading)
                    .accessibilityIdentifier("icon.download")
                }
                if !canDownload && !isDownloading {
                    Text("Add a website to download its icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button(action: onImport) { Label("Import image…", systemImage: "photo.badge.plus") }
                .accessibilityIdentifier("icon.import")
        }
        .padding(16)
        .frame(width: 348)
    }

    private func choice(_ icon: VaultEntryIcon, name: String, identifier: String) -> some View {
        Button { onSelect(icon) } label: {
            VaultIconTile(icon: icon, fallbackSymbol: "key.fill", fallbackColor: .indigo, size: 36)
                .padding(4)
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(selected == icon ? KeeTheme.accent : Color.clear, lineWidth: 2)
                }
        }
        .buttonStyle(PressableButtonStyle())
        .help(name)
        .accessibilityLabel(name)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected == icon ? .isSelected : [])
    }
}
