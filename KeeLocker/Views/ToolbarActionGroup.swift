import Foundation
import SwiftUI

struct ToolbarActionGroup: View {
    @Binding var sortOrder: ItemSortOrder
    let addAction: () -> Void

    @State private var isSortHovered = false
    @State private var isAddHovered = false

    var body: some View {
        HStack(spacing: 0) {
            ToolbarActionSlot(isHovered: $isSortHovered) {
                Menu {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(ItemSortOrder.allCases) { order in
                            Label(order.title, systemImage: order.iconName)
                                .tag(order)
                        }
                    }
                } label: {
                    ToolbarActionGlyph(
                        systemName: "arrow.up.arrow.down",
                        font: .system(size: 15, weight: .semibold)
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(Color.primary)
                .buttonStyle(PressableButtonStyle())
                .frame(
                    width: ToolbarActionMetrics.slotSize,
                    height: ToolbarActionMetrics.slotSize
                )
                .help("Sort logins")
                .accessibilityLabel("Sort logins")
                .accessibilityIdentifier("toolbar.sort")
                .modifier(ToolbarHoverProbeModifier(isHovered: isSortHovered))
            }

            ToolbarActionSlot(isHovered: $isAddHovered) {
                Button(action: addAction) {
                    ToolbarActionGlyph(
                        systemName: "plus",
                        font: .system(size: 16, weight: .medium)
                    )
                }
                .buttonStyle(PressableButtonStyle())
                .frame(
                    width: ToolbarActionMetrics.slotSize,
                    height: ToolbarActionMetrics.slotSize
                )
                .help("New login (⌘N)")
                .accessibilityLabel("New login")
                .accessibilityIdentifier("toolbar.add")
                .modifier(ToolbarHoverProbeModifier(isHovered: isAddHovered))
            }
        }
        .background(KeeTheme.raisedSurface, in: Capsule())
        .overlay {
            Capsule()
                .stroke(KeeTheme.separator.opacity(0.55), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.actions")
    }
}

private struct ToolbarHoverProbeModifier: ViewModifier {
    let isHovered: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["KEELOCKER_UI_TESTING"] == "1" {
            content.accessibilityValue(isHovered ? "hovered" : "idle")
        } else {
            content
        }
#else
        content
#endif
    }
}

private enum ToolbarActionMetrics {
    static let slotSize = KeeTheme.Toolbar.controlHeight
    static let hoverDiameter: CGFloat = 32
    static let hoverOpacity: Double = 0.075
}

private struct ToolbarActionSlot<Content: View>: View {
    @Binding var isHovered: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    isHovered
                        ? Color.primary.opacity(ToolbarActionMetrics.hoverOpacity)
                        : .clear
                )
                .frame(
                    width: ToolbarActionMetrics.hoverDiameter,
                    height: ToolbarActionMetrics.hoverDiameter
                )

            content()
        }
        .frame(
            width: ToolbarActionMetrics.slotSize,
            height: ToolbarActionMetrics.slotSize
        )
        .onHover { isHovered in
            self.isHovered = isHovered
        }
    }
}

private struct ToolbarActionGlyph: View {
    let systemName: String
    let font: Font

    var body: some View {
        Image(systemName: systemName)
            .font(font)
            .foregroundStyle(Color.primary)
            .frame(
                width: ToolbarActionMetrics.hoverDiameter,
                height: ToolbarActionMetrics.hoverDiameter
            )
            .contentShape(Circle())
    }
}
