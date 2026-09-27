import AppKit
import SwiftUI

struct RootView: View {
    @StateObject private var store = VaultStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var sortOrder: ItemSortOrder = .recent
    @State private var listToolbarTitleWidth: CGFloat?

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
            ItemListView(store: store, sortOrder: $sortOrder)
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
                    ToolbarActionGroup(sortOrder: $sortOrder, addAction: store.addItem)
                }
        } detail: {
            detailColumn
                .workspaceTitlebarBackground()
        }
        .navigationSplitViewStyle(.balanced)
        .background(TitlebarSplitResizeMonitor())
        .overlay(alignment: .topTrailing) {
            ToolbarSearchField(text: $store.searchQuery)
                .frame(width: 240)
                .padding(.trailing, KeeTheme.Spacing.medium)
                .frame(height: WorkspaceTitlebarMetrics.height)
                .offset(y: -WorkspaceTitlebarMetrics.height)
        }
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
        if let selectedID = store.selectedItemID,
           store.visibleItems.contains(where: { $0.id == selectedID }),
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

private struct ToolbarSearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: KeeTheme.Spacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isFocused)
                .onChange(of: text) { _, _ in
                    guard isFocused else { return }
                    Task { @MainActor in
                        isFocused = true
                    }
                }
                .onSubmit {
                    isFocused = false
                }
                .onExitCommand {
                    isFocused = false
                }
                .accessibilityLabel("Search logins")
                .accessibilityIdentifier("toolbar.search")
                .modifier(SearchFocusProbeModifier(isFocused: isFocused, text: text))

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(PressableButtonStyle())
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, KeeTheme.Spacing.medium)
        .frame(height: KeeTheme.Toolbar.controlHeight)
        .background(KeeTheme.raisedSurface, in: Capsule())
        .overlay {
            Capsule()
                .stroke(
                    isFocused
                        ? KeeTheme.accent.opacity(0.72)
                        : KeeTheme.separator.opacity(0.55),
                    lineWidth: isFocused ? 1 : 0.5
                )
        }
        .background {
            SearchFocusMonitor {
                isFocused = false
            }
        }
        .contentShape(Capsule())
        .onTapGesture {
            isFocused = true
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.searchContainer")
    }
}

private struct SearchFocusProbeModifier: ViewModifier {
    let isFocused: Bool
    let text: String

    @ViewBuilder
    func body(content: Content) -> some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["KEELOCKER_UI_TESTING"] == "1" {
            content.accessibilityValue("\(isFocused ? "focused" : "idle")|\(text)")
        } else {
            content
        }
#else
        content
#endif
    }
}

private struct SearchFocusMonitor: NSViewRepresentable {
    let onClickOutside: () -> Void

    func makeNSView(context: Context) -> MonitoringView {
        let view = MonitoringView()
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ view: MonitoringView, context: Context) {
        view.onClickOutside = onClickOutside
    }

    final class MonitoringView: NSView {
        var onClickOutside: () -> Void = {}
        private var eventMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        deinit {
            stopMonitoring()
        }

        private func startMonitoring() {
            guard eventMonitor == nil else { return }

            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] event in
                guard let self, event.window === self.window else { return event }

                let location = self.convert(event.locationInWindow, from: nil)
                guard !self.bounds.contains(location) else { return event }

                DispatchQueue.main.async { [weak self] in
                    self?.onClickOutside()
                }

                return event
            }
        }

        private func stopMonitoring() {
            guard let eventMonitor else { return }
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
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
