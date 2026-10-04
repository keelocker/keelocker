import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @StateObject private var store = ProcessInfo.processInfo.arguments.contains("--demo-vault")
        ? VaultStore(items: MockVault.items)
        : VaultStore(preferences: ProcessInfo.processInfo.arguments.contains("--ignore-last-vault") ? nil : .standard,
                     quickUnlock: ProcessInfo.processInfo.arguments.contains("--disable-touch-id") ? nil : SessionQuickUnlock.shared)
    @State private var showsUnlock = false
    @State private var didOfferInitialUnlock = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sortOrder: ItemSortOrder = .recent
    @State private var listToolbarTitleWidth: CGFloat?

    var body: some View {
        Group {
            if store.isLocked {
                LockedVaultView(
                    filename: store.fileURL?.lastPathComponent,
                    hasVault: store.state != .noVault,
                    onUnlock: requestUnlock,
                    onOpen: openVault,
                    onDemo: store.openDemo
                )
            } else {
                workspace
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .tint(KeeTheme.accent)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .focusedSceneValue(\.createVaultItem, createVaultItemAction)
        .focusedSceneValue(\.createVaultGroup, createVaultGroupAction)
        .focusedSceneValue(\.openVault, openVault)
        .focusedSceneValue(\.saveVault, canSave ? { store.run(.save) } : nil)
        .focusedSceneValue(\.saveVaultAs, canSave ? { VaultDialogs.saveAs(store) } : nil)
        .background(VaultWindowGuard(store: store))
        .overlay(alignment: .bottomTrailing) { if store.isBusy { ProgressView().controlSize(.small).padding() } }
        .alert(store.operationFailure?.title ?? "Touch ID", isPresented: Binding(get: {
            store.operationFailure != nil || (!store.isLocked && !showsUnlock && store.quickUnlockFailure != nil)
        }, set: { if !$0 { store.operationFailure = nil; store.quickUnlockFailure = nil } })) {
            if store.operationFailure == .conflict {
                Button("Save Copy…") {
                    store.operationFailure = nil
                    VaultDialogs.saveAs(store)
                }
                Button("Reload Latest", role: .destructive) {
                    store.operationFailure = nil
                    store.run(.reload)
                }
                Button("Cancel", role: .cancel) { store.operationFailure = nil }
            } else {
                Button("OK") { store.operationFailure = nil; store.quickUnlockFailure = nil }
            }
        } message: { Text(store.operationFailure?.message ?? store.quickUnlockFailure?.message ?? "") }
        .task {
            if !didOfferInitialUnlock {
                didOfferInitialUnlock = true
                if store.state == .locked, store.requiresPassword { showsUnlock = true }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await store.refreshOTP()
            }
        }
        .sheet(isPresented: $showsUnlock, onDismiss: {
            if store.state != .unlocked { store.lock() }
        }) {
            UnlockVaultView(store: store) { showsUnlock = false }
        }
        .sheet(isPresented: Binding(get: { store.inspectedEntryID != nil }, set: { if !$0 { store.inspectedEntryID = nil } })) {
            if let id = store.inspectedEntryID { EntryFilesAndHistory(store: store, id: id) }
        }
        .onChange(of: store.state) { _, state in
            if state == .unlocked { showsUnlock = false }
        }
    }

    private func requestUnlock() {
        if store.requiresPassword { showsUnlock = true } else { store.unlock() }
    }

    private func openVault() {
        guard VaultDialogs.mayLeave(store) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Open Vault"
        let session = store.sessionID
        panel.begin { response in
            guard response == .OK, let url = panel.url, store.sessionID == session,
                  VaultDialogs.mayLeave(store) else { return }
            store.openFile(url)
            showsUnlock = true
        }
    }

    private var createVaultItemAction: (() -> Void)? {
        guard !store.isLocked, !store.isBusy, !store.hasDraft, store.capabilities.canCreate else { return nil }
        return { store.addItem() }
    }

    private var createVaultGroupAction: (() -> Void)? {
        guard store.groupCreationParent != nil else { return nil }
        return { VaultDialogs.newGroup(store) }
    }

    private var workspace: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store, onOpenVault: openVault)
                .disabled(store.hasDraft)
                .navigationSplitViewColumnWidth(min: 220, ideal: 242, max: 272)
        } content: {
            ItemListView(store: store, sortOrder: $sortOrder)
                .disabled(store.hasDraft)
                .navigationSplitViewColumnWidth(
                    min: columnVisibility == .all ? 300 : 336,
                    ideal: 336,
                    max: 390
                )
                .workspaceTitlebarBackground()
                .background(ListToolbarAlignment(titleWidth: $listToolbarTitleWidth))
                .toolbar {
                    if #available(macOS 26.0, *) {
                        ToolbarItem(id: "list.title", placement: .automatic) {
                            listTitle
                        }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(id: "list.title", placement: .automatic) {
                            listTitle
                        }
                    }
                    ToolbarActionGroup(sortOrder: $sortOrder, canCreate: store.capabilities.canCreate && !store.isBusy && !store.hasDraft, addAction: store.addItem)
                }
        } detail: {
            detailColumn
                .workspaceTitlebarBackground()
        }
        .navigationSplitViewStyle(.balanced)
        .background(TitlebarSplitResizeMonitor())
        .searchable(text: Binding(get: { store.searchQuery }, set: {
            if !store.hasDraft && !store.isBusy { store.searchQuery = $0 }
        }), placement: .toolbar, prompt: "Search")
    }

    private var listTitle: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(store.currentTitle)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text("\(store.visibleItems.count) \(store.visibleItems.count == 1 ? "login" : "logins")")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: listToolbarTitleWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.listTitle")
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let draft = store.newItemDraft {
            ItemDetailView(
                item: .constant(draft),
                canEdit: store.capabilities.canCreate && !store.isBusy,
                canFavorite: store.capabilities.canFavorite,
                hasDraft: $store.hasDraft,
                isNew: true,
                onSave: { item in await store.saveItem(item) },
                onCancel: store.cancelNewItem
            )
            .id(draft.id)
            .disabled(store.isBusy)
        } else if let selectedID = store.selectedItemID,
           store.visibleItems.contains(where: { $0.id == selectedID }),
           store.items.contains(where: { $0.id == selectedID }) {
            ItemDetailView(
                item: Binding(
                    get: { store.selectedEntry ?? store.items.first { $0.id == selectedID } ?? .empty },
                    set: store.updateItem
                ),
                canEdit: store.capabilities.canEdit && store.selectedEntry != nil && !store.isBusy,
                canFavorite: store.capabilities.canFavorite,
                hasDraft: $store.hasDraft,
                onSave: { item in await store.saveItem(item) },
                onBeginEditing: { !store.isBusy && !store.isLocked && store.selectedEntry != nil }
            )
            .id(selectedID)
            .id(store.editorGeneration)
            .disabled(store.isBusy)
            .contextMenu {
                if let item = store.items.first(where: { $0.id == selectedID }) { EntryCommands(store: store, item: item) }
            }
        } else {
            EmptyDetailView()
        }
    }

    private var canSave: Bool { !store.isLocked && !store.isBusy && !store.hasDraft && store.capabilities.canSave }
}

private extension View {
    func workspaceTitlebarBackground() -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(KeeTheme.canvas)
                .overlay(alignment: .bottom) {
                    Divider()
                }
                .frame(height: WorkspaceTitlebarMetrics.height)
                .offset(y: -WorkspaceTitlebarMetrics.height)
                .allowsHitTesting(false)
        }
    }
}

private enum WorkspaceTitlebarMetrics {
    static let height: CGFloat = 52
}

// SwiftUI's window-wide flexible spacer cannot align items to the middle split column.
// Measure public NSToolbarItem views and let the title absorb only this column's free space.
private struct ListToolbarAlignment: NSViewRepresentable {
    @Binding var titleWidth: CGFloat?

    func makeNSView(context: Context) -> AlignmentView { AlignmentView() }

    func updateNSView(_ view: AlignmentView, context: Context) {
        view.updateTitleWidth = { titleWidth = $0 }
        view.scheduleUpdate()
    }

    final class AlignmentView: NSView {
        var updateTitleWidth: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var updatePending = false
        private var lastWidth: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard let window else { return }
            for name in [NSWindow.didUpdateNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.scheduleUpdate()
                })
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self, let split = notification.object as? NSSplitView,
                      split.window === self.window else { return }
                self.scheduleUpdate()
            })
            scheduleUpdate()
        }

        override func layout() {
            super.layout()
            scheduleUpdate()
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }

        func scheduleUpdate() {
            guard !updatePending else { return }
            updatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePending = false
                guard let toolbar = self.window?.toolbar, self.bounds.width > 0,
                      let title = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "list.title" })?.view,
                      let add = toolbar.items.first(where: { $0.itemIdentifier.rawValue == "list.add" })?.view,
                      title.window === self.window, add.window === self.window else { return }
                let trailingEdge = self.convert(self.bounds, to: nil).maxX - KeeTheme.Spacing.small
                let addTrailingEdge = add.convert(add.bounds, to: nil).maxX
                let width = max(1, title.bounds.width + trailingEdge - addTrailingEdge)
                if let lastWidth = self.lastWidth, abs(width - lastWidth) < 0.5 {
                    return
                }
                self.lastWidth = width
                self.updateTitleWidth?(width)
            }
        }
    }
}

private struct TitlebarSplitResizeMonitor: NSViewRepresentable {
    // The titlebar can move the window even while the split divider shows a resize cursor.
    // Disable window movement on hover, before AppKit handles the mouse-down event.
    func makeNSView(context: Context) -> MonitoringView {
        MonitoringView()
    }

    func updateNSView(_ view: MonitoringView, context: Context) {}

    final class MonitoringView: NSView {
        private var eventMonitor: Any?
        private var resignObserver: Any?
        private weak var trackedTitlebar: NSView?
        private var titlebarTrackingArea: NSTrackingArea?
        private weak var draggedSplit: NSSplitView?
        private var draggedDividerIndex: Int?
        private var initialDividerPosition: CGFloat = 0
        private var initialMouseX: CGFloat = 0
        private weak var movementWindow: NSWindow?
        private var wasWindowMovable: Bool?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            if window != nil {
                startMonitoring()
            }
        }

        deinit {
            stopMonitoring()
        }

        private func startMonitoring() {
            guard let window else { return }
            // Mouse-move events in the titlebar reach the standard buttons' parent view.
            if let titlebar = window.standardWindowButton(.closeButton)?.superview {
                let trackingArea = NSTrackingArea(
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                    owner: self,
                    userInfo: nil
                )
                titlebar.addTrackingArea(trackingArea)
                trackedTitlebar = titlebar
                titlebarTrackingArea = trackingArea
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.draggedSplit = nil
                self.draggedDividerIndex = nil
                self.restoreWindowMovability()
            }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                if self.draggedDividerIndex == nil && event.window !== self.window {
                    return event
                }
                return self.handle(event)
            }
        }

        private func stopMonitoring() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            if let resignObserver {
                NotificationCenter.default.removeObserver(resignObserver)
                self.resignObserver = nil
            }
            if let trackedTitlebar, let titlebarTrackingArea {
                trackedTitlebar.removeTrackingArea(titlebarTrackingArea)
            }
            trackedTitlebar = nil
            titlebarTrackingArea = nil
            draggedSplit = nil
            draggedDividerIndex = nil
            restoreWindowMovability()
        }

        override func mouseEntered(with event: NSEvent) {
            if draggedDividerIndex == nil {
                updateWindowMovability(at: event.locationInWindow)
            }
        }

        override func mouseMoved(with event: NSEvent) {
            if draggedDividerIndex == nil {
                updateWindowMovability(at: event.locationInWindow)
            }
        }

        override func mouseExited(with event: NSEvent) {
            if draggedDividerIndex == nil {
                restoreWindowMovability()
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                guard let window,
                      let divider = titlebarDivider(in: window, at: event.locationInWindow) else {
                    return event
                }
                window.makeFirstResponder(nil)
                blockWindowMovement(window)
                draggedSplit = divider.split
                draggedDividerIndex = divider.index
                initialDividerPosition = divider.position
                initialMouseX = event.locationInWindow.x
                return nil

            case .leftMouseDragged:
                guard let draggedSplit, let draggedDividerIndex else { return event }
                let position = initialDividerPosition + event.locationInWindow.x - initialMouseX
                draggedSplit.setPosition(position, ofDividerAt: draggedDividerIndex)
                return nil

            case .leftMouseUp:
                guard draggedDividerIndex != nil else { return event }
                draggedSplit = nil
                draggedDividerIndex = nil
                let location = event.locationInWindow
                let dragWindow = window
                // Wait until AppKit finishes the mouse-up before allowing titlebar dragging again.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.window === dragWindow,
                          self.draggedDividerIndex == nil else { return }
                    self.updateWindowMovability(at: location)
                }
                return nil

            default:
                return event
            }
        }

        private func updateWindowMovability(at location: NSPoint) {
            guard let window else { return }
            if titlebarDivider(in: window, at: location) == nil {
                restoreWindowMovability()
            } else {
                blockWindowMovement(window)
            }
        }

        private func blockWindowMovement(_ window: NSWindow) {
            guard movementWindow !== window else { return }
            restoreWindowMovability()
            movementWindow = window
            wasWindowMovable = window.isMovable
            window.isMovable = false
        }

        private func restoreWindowMovability() {
            if let movementWindow, let wasWindowMovable {
                movementWindow.isMovable = wasWindowMovable
            }
            movementWindow = nil
            wasWindowMovable = nil
        }

        private func titlebarDivider(
            in window: NSWindow,
            at location: NSPoint
        ) -> (split: NSSplitView, index: Int, position: CGFloat)? {
            let distanceFromTop = window.frame.height - location.y
            guard (0...WorkspaceTitlebarMetrics.height).contains(distanceFromTop),
                  let contentView = window.contentView else { return nil }
            return findDivider(in: contentView, at: location)
        }

        private func findDivider(
            in view: NSView,
            at location: NSPoint
        ) -> (split: NSSplitView, index: Int, position: CGFloat)? {
            if let split = view as? NSSplitView, split.isVertical {
                let x = split.convert(location, from: nil).x
                for (index, pane) in split.arrangedSubviews.dropLast().enumerated() {
                    let position = pane.frame.maxX
                    if abs(x - position) <= 6 {
                        return (split, index, position)
                    }
                }
            }

            for child in view.subviews {
                if let divider = findDivider(in: child, at: location) {
                    return divider
                }
            }
            return nil
        }
    }
}

private struct LockedVaultView: View {
    let filename: String?
    let hasVault: Bool
    let onUnlock: () -> Void
    let onOpen: () -> Void
    let onDemo: () -> Void

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
                    Text(hasVault ? "KeeLocker is locked" : "Open a vault")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.35)
                    Text(filename ?? "Open a KeePass database to get started.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                Button(action: hasVault ? onUnlock : onOpen) {
                    Label(hasVault ? "Unlock vault" : "Open Vault…", systemImage: "lock.open.fill")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(KeeTheme.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableButtonStyle())
                .keyboardShortcut(.defaultAction)
                if hasVault {
                    Button("Open another vault…", action: onOpen)
                } else {
                    Button("Open demo vault", action: onDemo)
                }
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
