import SwiftUI

struct RootView: View {
    @StateObject private var store = VaultStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if store.isLocked {
                LockedVaultView(onUnlock: store.unlock)
            } else {
                workspace
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .tint(KeeTheme.accent)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .focusedSceneValue(\.createVaultItem, createVaultItemAction)
    }

    private var createVaultItemAction: (() -> Void)? {
        guard !store.isLocked else { return nil }
        return { store.addItem() }
    }

    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 220, ideal: 242, max: 272)
        } content: {
            ItemListView(store: store)
                .navigationSplitViewColumnWidth(min: 300, ideal: 336, max: 390)
                .workspaceTitlebarBackground()
        } detail: {
            detailColumn
                .workspaceTitlebarBackground()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: store.addItem) {
                    Label("New login", systemImage: "plus")
                }
                .help("New login (⌘N)")

                Menu {
                    Button("Import vault…", systemImage: "square.and.arrow.down") { }
                        .disabled(true)
                    Button("Export vault…", systemImage: "square.and.arrow.up") { }
                        .disabled(true)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .help("More actions")
            }
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let selectedID = store.selectedItemID,
           let index = store.items.firstIndex(where: { $0.id == selectedID }) {
            ItemDetailView(
                item: Binding(
                    get: { store.items[index] },
                    set: store.updateItem
                )
            )
            .id(selectedID)
        } else {
            EmptyDetailView()
        }
    }
}

private extension View {
    func workspaceTitlebarBackground() -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(KeeTheme.canvas)
                .overlay(alignment: .bottom) {
                    Divider()
                }
                .frame(height: 52)
                .offset(y: -52)
                .allowsHitTesting(false)
        }
    }
}

private struct LockedVaultView: View {
    let onUnlock: () -> Void

    var body: some View {
        ZStack {
            KeeTheme.canvas
                .ignoresSafeArea()

            VStack(spacing: KeeTheme.Spacing.large) {
                ZStack {
                    RoundedRectangle(cornerRadius: KeeTheme.Radius.large, style: .continuous)
                        .fill(KeeTheme.accent)
                        .frame(width: 72, height: 72)
                        .shadow(color: KeeTheme.accent.opacity(0.20), radius: 18, y: 8)

                    Image(systemName: "lock.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(spacing: KeeTheme.Spacing.small) {
                    Text("KeeLocker is locked")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.35)
                    Text("Your in-memory vault is ready when you are.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Button(action: onUnlock) {
                    Label("Unlock vault", systemImage: "lock.open.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(KeeTheme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        ZStack {
            KeeTheme.canvas
                .ignoresSafeArea()

            VStack(spacing: KeeTheme.Spacing.medium) {
                Image(systemName: "key.horizontal")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a login")
                    .font(.title3.weight(.semibold))
                Text("Choose an item from the list to view its details.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
