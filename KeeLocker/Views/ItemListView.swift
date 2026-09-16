import SwiftUI

struct ItemListView: View {
    @ObservedObject var store: VaultStore
    @AppStorage("concealUsernames") private var concealUsernames = false
    @State private var sortOrder: ItemSortOrder = .recent

    private var sortedItems: [VaultItem] {
        switch sortOrder {
        case .recent:
            store.visibleItems.sorted { $0.modifiedAt > $1.modifiedAt }
        case .title:
            store.visibleItems.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            listHeader
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            if sortedItems.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(sortedItems) { item in
                                ItemRowView(
                                    item: item,
                                    isSelected: store.selectedItemID == item.id,
                                    concealsUsername: concealUsernames
                                ) {
                                    store.selectedItemID = item.id
                                }
                                .id(item.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: store.selectedItemID) { _, selectedID in
                        guard let selectedID else { return }
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }
        }
        .background(KeeTheme.listSurface)
        .onChange(of: store.searchQuery) { _, _ in
            store.reconcileSelection()
        }
    }

    private var listHeader: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.currentTitle)
                        .font(.system(size: 23, weight: .semibold))
                        .tracking(-0.22)
                    Text("\(store.visibleItems.count) \(store.visibleItems.count == 1 ? "login" : "logins")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(ItemSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.iconName)
                                .tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .menuStyle(.borderlessButton)
                .help("Sort logins")
            }

            SearchField(text: $store.searchQuery)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: store.searchQuery.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(store.searchQuery.isEmpty ? "No logins here" : "No matching logins")
                .font(.headline)
            Text(store.searchQuery.isEmpty ? "Add a login to this section." : "Try another title, username or website.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search logins", text: $text)
                .textFieldStyle(.plain)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private enum ItemSortOrder: String, CaseIterable, Identifiable {
    case recent
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recently updated"
        case .title: "Title"
        }
    }

    var iconName: String {
        switch self {
        case .recent: "clock"
        case .title: "textformat"
        }
    }
}

private struct ItemRowView: View {
    let item: VaultItem
    let isSelected: Bool
    let concealsUsername: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                EntryIcon(item: item, size: 40)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        if item.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.orange)
                        }
                    }
                    Text(usernameLabel)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Text(item.modifiedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 68)
            .background(
                RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isSelected { return KeeTheme.accent.opacity(0.13) }
        if isHovered { return Color.primary.opacity(0.05) }
        return .clear
    }

    private var usernameLabel: String {
        guard !item.username.isEmpty else { return "No username" }
        return concealsUsername ? "••••••••••" : item.username
    }
}

struct EntryIcon: View {
    let item: VaultItem
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(item.iconColor.color)
            Image(systemName: item.iconName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.white.opacity(0.94))
        }
        .frame(width: size, height: size)
        .shadow(color: item.iconColor.color.opacity(0.16), radius: 5, y: 2)
        .accessibilityHidden(true)
    }
}
