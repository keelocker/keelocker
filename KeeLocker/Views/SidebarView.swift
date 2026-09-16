import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: VaultStore
    @Environment(\.openSettings) private var openSettings
    @State private var showsVaultSwitcher = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                vaultMenu
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .padding(.bottom, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        sidebarSection(title: "Vault") {
                            SidebarRow(
                                title: "All items",
                                iconName: "square.stack.3d.up.fill",
                                count: store.items.count,
                                isSelected: store.sidebarSelection == .allItems
                            ) {
                                store.navigate(to: .allItems)
                            }

                            SidebarRow(
                                title: "Favorites",
                                iconName: "star.fill",
                                count: store.favoriteCount,
                                isSelected: store.sidebarSelection == .favorites
                            ) {
                                store.navigate(to: .favorites)
                            }
                        }

                        sidebarSection(title: "Groups") {
                            ForEach(VaultGroup.allCases) { group in
                                SidebarRow(
                                    title: group.rawValue,
                                    iconName: group.iconName,
                                    count: store.count(in: group),
                                    isSelected: store.sidebarSelection == .group(group)
                                ) {
                                    store.navigate(to: .group(group))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)

                Divider()
                    .opacity(0.7)

                VStack(spacing: 2) {
                    SidebarActionRow(title: "Settings", iconName: "gearshape") {
                        openSettings()
                    }
                    SidebarActionRow(
                        title: "Lock vault",
                        iconName: "lock",
                        roleColor: .secondary
                    ) {
                        store.lock()
                    }
                }
                .padding(10)
            }
        }
    }

    private var vaultMenu: some View {
        Button {
            showsVaultSwitcher.toggle()
        } label: {
            Text("Personal Vault")
        }
        .buttonStyle(VaultSwitcherButtonStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Current vault: Personal Vault")
        .popover(isPresented: $showsVaultSwitcher, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Vaults")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                Button {
                    showsVaultSwitcher = false
                } label: {
                    HStack(spacing: 10) {
                        VaultIcon(size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Personal Vault")
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(store.items.count) items · Local mock vault")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(KeeTheme.accent)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        KeeTheme.accent.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(12)
            .frame(width: 270)
        }
    }

    private func sidebarSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)

            VStack(spacing: 2, content: content)
        }
    }
}

private struct VaultIcon: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
                .fill(KeeTheme.accent)
            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.39, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct VaultSwitcherButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            VaultIcon(size: 44)

            Text("Personal Vault")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 6)

            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .contentShape(Rectangle())
        .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
        .opacity(configuration.isPressed ? 0.82 : 1)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: configuration.isPressed
        )
    }
}

private struct SidebarRow: View {
    let title: String
    let iconName: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                Spacer()
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        isSelected
                            ? KeeTheme.accent.opacity(0.86)
                            : Color(nsColor: .tertiaryLabelColor)
                    )
            }
            .foregroundStyle(isSelected ? KeeTheme.accent : Color.primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background {
                RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous)
                    .fill(backgroundColor)
            }
            .contentShape(RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isSelected { return KeeTheme.accent.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.055) }
        return .clear
    }
}

private struct SidebarActionRow: View {
    let title: String
    let iconName: String
    var roleColor: Color = .primary
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(roleColor)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.055) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { isHovered = $0 }
    }
}
