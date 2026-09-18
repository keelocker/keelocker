import SwiftUI

struct ItemListView: View {
    @ObservedObject var store: VaultStore
    @Binding var sortOrder: ItemSortOrder
    @AppStorage("concealUsernames") private var concealUsernames = false

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
                        proxy.scrollTo(selectedID)
                    }
                }
            }
        }
        .background(KeeTheme.listSurface)
    }

    private var listHeader: some View {
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
