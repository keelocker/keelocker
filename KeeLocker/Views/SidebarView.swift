import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: VaultStore
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        sidebarSection(title: "Vault") {
                            SidebarRow(
                                title: "All items",
                                iconName: "square.stack.3d.up.fill",
                                count: store.activeItemCount,
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

                            if store.recycleBinEnabled || store.recycleBinID != nil {
                                SidebarRow(title: "Recycle Bin", iconName: "trash",
                                           count: store.recycleBinCount,
                                           isSelected: store.sidebarSelection == .recycleBin) {
                                    store.navigate(to: .recycleBin)
                                }
                                .accessibilityIdentifier("sidebar.recycleBin")
                            }
                        }

                        sidebarSection(title: "Groups") {
                            groupTree
                        }
                        .animation(
                            reduceMotion || store.isLocked ? nil : KeeTheme.Motion.groupExpansion,
                            value: store.collapsedGroupIDs
                        )
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.hidden)

                Divider()
                    .opacity(0.7)

                vaultFooter
                    .padding(10)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Group…") { VaultDialogs.newGroup(store, atRoot: true) }
                .disabled(store.rootGroupCreationParent == nil)
        }
    }

    private var groupTree: some View {
        let rows = store.visibleGroupRows
        let stride = SidebarRowLayout.height + SidebarRowLayout.spacing
        return VStack(spacing: SidebarRowLayout.spacing) {
            ForEach(rows) { row in
                groupRow(row)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -4)))
            }
        }
        .background {
            Canvas { context, _ in
                var branches: [(depth: Int, start: Int)] = []
                var guides = Path()
                func finishBranch(_ branch: (depth: Int, start: Int), end: Int) {
                    let x = 10 + SidebarRowLayout.disclosureWidth / 2
                        + CGFloat(branch.depth) * SidebarRowLayout.indentation
                    guides.move(to: CGPoint(x: x, y: CGFloat(branch.start + 1) * stride - SidebarRowLayout.spacing))
                    guides.addLine(to: CGPoint(x: x, y: CGFloat(end) * stride - SidebarRowLayout.spacing))
                }
                for (index, row) in rows.enumerated() {
                    while let branch = branches.last, row.depth <= branch.depth {
                        finishBranch(branches.removeLast(), end: index)
                    }
                    if row.hasChildren && row.isExpanded {
                        branches.append((row.depth, index))
                    }
                }
                for branch in branches { finishBranch(branch, end: rows.count) }
                context.stroke(guides, with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func groupRow(_ row: VaultGroupTreeRow) -> some View {
        let group = row.group
        let selected: Bool = {
            if case let .group(current) = store.sidebarSelection { return current.id == group.id }
            return false
        }()
        let indentation = CGFloat(row.depth) * SidebarRowLayout.indentation
        return SidebarRow(title: group.name, iconName: group.iconName,
                          count: store.count(in: group), isSelected: selected,
                          leadingInset: SidebarRowLayout.disclosureWidth + indentation,
                          hoverExcludedRange: row.hasChildren
                            ? (10 + indentation)..<(10 + indentation + SidebarRowLayout.disclosureWidth) : nil) {
            store.navigate(to: .group(group))
        }
        .accessibilityIdentifier("sidebar.group.\(group.id.uuidString)")
        .help(group.path)
        .overlay(alignment: .leading) {
            if row.hasChildren {
                Button { store.toggleGroupExpansion(group.id) } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(selected ? KeeTheme.accent : Color.secondary)
                        .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                }
                .buttonStyle(GroupDisclosureButtonStyle())
                .padding(.leading, 10 + indentation)
                .accessibilityLabel("\(row.isExpanded ? "Collapse" : "Expand") \(group.name)")
                .accessibilityIdentifier("sidebar.disclosure.\(group.id.uuidString)")
            }
        }
        .contextMenu { GroupCommands(store: store, group: group) }
    }

    private var vaultFooter: some View {
        HStack(spacing: SidebarRowLayout.iconToLabelSpacing) {
            HStack(spacing: SidebarRowLayout.iconToLabelSpacing) {
                Image(systemName: "externaldrive")
                    .font(.system(size: SidebarRowLayout.fontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: SidebarRowLayout.iconWidth)
                    .accessibilityHidden(true)
                Text(store.vaultName)
                    .font(.system(size: SidebarRowLayout.fontSize, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Current vault: \(store.vaultName)")
            .accessibilityIdentifier("sidebar.vaultName")
            .help(store.vaultName)

            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("sidebar.settings")

            Button {
                if VaultDialogs.mayLeave(store) { store.lock() }
            } label: {
                Image(systemName: "lock")
            }
            .buttonStyle(SidebarFooterButtonStyle())
            .help("Lock vault")
            .accessibilityLabel("Lock vault")
            .accessibilityIdentifier("sidebar.lock")
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
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

            VStack(spacing: SidebarRowLayout.spacing, content: content)
        }
    }
}

private struct GroupDisclosureButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 8, weight: .medium))
            .frame(width: SidebarRowLayout.disclosureWidth, height: SidebarRowLayout.height)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.08 : 0)))
                    .frame(width: SidebarRowLayout.disclosureHighlightWidth, height: 20)
            }
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct SidebarFooterButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 30, height: 30)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.08 : 0)),
                in: RoundedRectangle(cornerRadius: KeeTheme.Radius.compact, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: KeeTheme.Radius.compact, style: .continuous))
            .onHover { isHovered = $0 }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private enum SidebarRowLayout {
    static let height: CGFloat = 30
    static let spacing: CGFloat = 2
    static let fontSize: CGFloat = 13
    static let iconWidth: CGFloat = 16
    static let iconToLabelSpacing: CGFloat = 7
    static let indentation: CGFloat = 12
    static let disclosureWidth: CGFloat = 18
    // A centered 12 pt highlight leaves 3 pt before the folder's icon slot.
    static let disclosureHighlightWidth: CGFloat = 12
}

private struct SidebarRow: View {
    let title: String
    let iconName: String
    var count: Int? = nil
    var isSelected = false
    var leadingInset: CGFloat = 0
    var hoverExcludedRange: Range<CGFloat>? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarRowLayout.iconToLabelSpacing) {
                Image(systemName: iconName)
                    .font(.system(size: SidebarRowLayout.fontSize, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isSelected ? KeeTheme.accent : Color.secondary)
                    .frame(width: SidebarRowLayout.iconWidth)
                Text(title)
                    .font(.system(size: SidebarRowLayout.fontSize, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text(count.formatted())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(
                            isSelected
                                ? KeeTheme.accent.opacity(0.86)
                                : Color(nsColor: .tertiaryLabelColor)
                        )
                }
            }
            .foregroundStyle(isSelected ? KeeTheme.accent : Color.primary)
            .padding(.leading, 10 + leadingInset)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, minHeight: SidebarRowLayout.height)
            .background {
                RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous)
                    .fill(backgroundColor)
            }
            .contentShape(RoundedRectangle(cornerRadius: KeeTheme.Radius.row, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                isHovered = !(hoverExcludedRange?.contains(location.x) ?? false)
            case .ended:
                isHovered = false
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundColor: Color {
        if isSelected { return KeeTheme.accent.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.055) }
        return .clear
    }
}
