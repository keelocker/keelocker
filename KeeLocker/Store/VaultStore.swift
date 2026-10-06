import Foundation

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var items: [VaultItem] = []
    @Published var selectedItemID: VaultItem.ID? { didSet { if oldValue != selectedItemID { loadSelection() } } }
    @Published private(set) var selectedEntry: VaultEntry?
    @Published private(set) var newItemDraft: VaultEntry?
    @Published private(set) var isBusy = false
    @Published private(set) var isDirty = false
    @Published var operationFailure: VaultFailure?
    @Published var quickUnlockFailure: QuickUnlockFailure?
    @Published private(set) var touchIDAvailable = false
    @Published private(set) var canQuickUnlock = false
    private(set) var lastCommandApplied = false
    @Published var hasDraft = false { didSet { if !hasDraft { refreshIfNeeded() } } }
    @Published var inspectedEntryID: UUID? { didSet { if inspectedEntryID == nil { refreshIfNeeded() } } }
    @Published private(set) var editorGeneration = UUID()
    @Published private(set) var snapshotRevision = UUID()
    @Published var sidebarSelection: SidebarSelection = .allItems
    @Published var searchQuery = ""
    @Published private(set) var state: VaultState = .noVault
    @Published private(set) var groups: [VaultGroup] = []
    @Published private(set) var collapsedGroupIDs: Set<UUID> = []
    @Published private(set) var vaultName = "KeeLocker"
    @Published private(set) var fileURL: URL?
    @Published private(set) var capabilities: VaultCapabilities = .readOnly
    private var repository: (any VaultRepository)?
    private let quickUnlock: (any QuickUnlockService)?
    private var quickUnlockRegistration: QuickUnlockRegistration?
    private var unlockTask: Task<Void, Never>?
    private var generation = UUID()
    private var operationTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionGeneration = UUID()
    private var preferences: UserDefaults?
    private var fileMonitor: VaultFileMonitor?
    private var monitoredURL: URL?
    private var refreshTask: Task<Void, Never>?
    private var refreshPending = false
    private var lastRefreshFailure: VaultFailure?
    private var selectionBeforeNewItem: UUID?

    init(preferences: UserDefaults? = nil, quickUnlock: (any QuickUnlockService)? = nil) {
        self.preferences = preferences
        self.quickUnlock = quickUnlock
        if let path = preferences?.string(forKey: "lastVaultPath"), !path.isEmpty {
            openFile(URL(fileURLWithPath: path))
        }
    }

    deinit { unlockTask?.cancel(); refreshTask?.cancel() }

    init(items: [VaultItem]) {
        quickUnlock = nil
        let memory = MemoryVaultRepository(items: items)
        repository = memory
        capabilities = memory.capabilities
        apply(memory.vault)
    }

    var isLocked: Bool { state != .unlocked }
    var sessionID: UUID { generation }
    var requiresPassword: Bool { repository?.requiresPassword ?? false }
    var canEnableTouchID: Bool { repository?.supportsQuickUnlock == true && fileURL != nil && touchIDAvailable }
    var groupCreationParent: VaultGroup? {
        guard let root = rootGroupCreationParent else { return nil }
        if case let .group(selected) = sidebarSelection {
            return groups.first { $0.id == selected.id }
        }
        return root
    }
    var rootGroupCreationParent: VaultGroup? {
        guard !isLocked, !isBusy, !hasDraft, capabilities.canCreate else { return nil }
        return groups.first { $0.parentID == nil }
    }
    var visibleGroupRows: [VaultGroupTreeRow] {
        VaultGroupTree.rows(groups, collapsed: collapsedGroupIDs)
    }
    var failure: VaultFailure? {
        if case let .error(failure) = state { return failure }
        return nil
    }

    func openFile(_ url: URL) {
        use(RustVaultRepository(url: url), fileURL: url)
        preferences?.set(url.path, forKey: "lastVaultPath")
    }

    func use(_ repository: any VaultRepository, fileURL: URL? = nil) {
        lock()
        self.repository = repository
        self.fileURL = fileURL
        capabilities = repository.capabilities
        state = .locked
        refreshQuickUnlockAvailability()
    }

    func openDemo() {
        use(MemoryVaultRepository())
        unlock()
    }

    var visibleItems: [VaultItem] {
        let scopedItems: [VaultItem]

        switch sidebarSelection {
        case .allItems:
            scopedItems = items
        case .favorites:
            scopedItems = items.filter(\.isFavorite)
        case let .group(group):
            scopedItems = items.filter { $0.group == group }
        }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return scopedItems
        }

        let query = trimmedQuery.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return scopedItems.filter { item in
            ([item.title, item.username, item.website, item.group.rawValue, item.notes]
                + item.tags + item.customFields.filter { !$0.isSensitive }.map(\.value))
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(query)
        }
    }

    var currentTitle: String {
        switch sidebarSelection {
        case .allItems: "All items"
        case .favorites: "Favorites"
        case let .group(group): group.rawValue
        }
    }

    var favoriteCount: Int {
        items.filter(\.isFavorite).count
    }

    func count(in group: VaultGroup) -> Int {
        items.filter { $0.group == group }.count
    }

    func navigate(to destination: SidebarSelection) {
        if case let .group(group) = destination {
            collapsedGroupIDs.subtract(VaultGroupTree.ancestors(of: group.id, in: groups))
        }
        sidebarSelection = destination
        searchQuery = ""
        reconcileSelection()
    }

    func toggleGroupExpansion(_ id: UUID) {
        guard !isLocked, !hasDraft, let group = groups.first(where: { $0.id == id }),
              groups.contains(where: { $0.parentID == id }) else { return }
        if collapsedGroupIDs.remove(id) == nil {
            collapsedGroupIDs.insert(id)
            if case let .group(selected) = sidebarSelection,
               VaultGroupTree.ancestors(of: selected.id, in: groups).contains(id) {
                navigate(to: .group(group))
            }
        }
    }

    func reconcileSelection() {
        guard !visibleItems.contains(where: { $0.id == selectedItemID }) else { return }
        selectedItemID = visibleItems.first?.id
    }

    func updateItem(_ item: VaultItem) {
        guard capabilities.canEdit, !item.isRedacted else { return }
        run(.updateEntry(item))
    }

    func saveItem(_ item: VaultItem) async -> Bool {
        guard !isLocked, !isBusy, !item.isRedacted else { return false }
        let creating = newItemDraft?.id == item.id
        guard newItemDraft == nil || creating,
              creating ? capabilities.canCreate : capabilities.canEdit else { return false }
        let request = generation
        run(creating ? .createEntry(item) : .updateEntry(item), selectNew: creating)
        await waitForOperation()
        guard generation == request, lastCommandApplied else { return false }
        return true
    }

    func addItem() {
        guard let group = groupCreationParent else { return }

        selectionBeforeNewItem = selectedItemID
        newItemDraft = VaultItem(
            title: "New login",
            username: "",
            password: "",
            website: "",
            notes: "",
            tags: [],
            group: group,
            isFavorite: sidebarSelection == .favorites,
            iconName: "key.fill",
            iconColor: .indigo,
            modifiedAt: .now,
            createdAt: .now
        )
        hasDraft = true
        selectedItemID = nil
    }

    func cancelNewItem() {
        guard !isBusy, newItemDraft != nil else { return }
        newItemDraft = nil
        selectedItemID = selectionBeforeNewItem
        selectionBeforeNewItem = nil
        reconcileSelection()
        hasDraft = false
    }

    func lock() {
        quickUnlock?.cancel(request: generation)
        quickUnlockRegistration = nil
        generation = UUID()
        snapshotRevision = UUID()
        fileMonitor?.invalidate()
        fileMonitor = nil
        monitoredURL = nil
        refreshPending = false
        lastRefreshFailure = nil
        refreshTask?.cancel()
        refreshTask = nil
        unlockTask?.cancel()
        unlockTask = nil
        repository?.lock()
        operationTask?.cancel()
        selectionTask?.cancel()
        operationTask = nil
        selectedEntry = nil
        isBusy = false
        isDirty = false
        hasDraft = false
        inspectedEntryID = nil
        operationFailure = nil
        quickUnlockFailure = nil
        lastCommandApplied = false
        items = []
        newItemDraft = nil
        selectionBeforeNewItem = nil
        groups = []
        collapsedGroupIDs = []
        selectedItemID = nil
        sidebarSelection = .allItems
        vaultName = "KeeLocker"
        searchQuery = ""
        state = repository == nil ? .noVault : .locked
        refreshQuickUnlockAvailability()
    }

    func refreshQuickUnlockAvailability() {
        touchIDAvailable = quickUnlock?.isAvailable ?? false
        canQuickUnlock = canEnableTouchID && fileURL.map { quickUnlock?.contains($0) == true } == true
    }

    func forgetQuickUnlock() {
        if let fileURL { quickUnlock?.forget(fileURL) }
        quickUnlockRegistration = nil
        quickUnlockFailure = nil
        refreshQuickUnlockAvailability()
    }

    private func forgetSessionQuickUnlock() {
        if let quickUnlockRegistration { quickUnlock?.forget(quickUnlockRegistration) }
        quickUnlockRegistration = nil
        refreshQuickUnlockAvailability()
    }

    func unlock(password: String = "", keyFile: URL? = nil) {
        guard isLocked, state != .unlocking, let repository else { return }
        let request = UUID()
        generation = request
        state = .unlocking
        quickUnlockFailure = nil
        let attempt = repository.supportsQuickUnlock ? fileURL.flatMap { quickUnlock?.enrollmentAttempt(for: $0) } : nil
        unlockTask = Task { [weak self] in
            do {
                let vault = try await repository.load(password: password, keyFile: keyFile)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                let url = vault.fileURL ?? self.fileURL
                var registration: QuickUnlockRegistration?
                if let quickUnlock = self.quickUnlock, let url, let attempt, quickUnlock.isAvailable {
                    do {
                        let enrollment = try quickUnlock.prepareEnrollment(for: url, request: request, attempt: attempt)
                        defer { quickUnlock.finish(request: request) }
                        var material = try await repository.keyMaterial()
                        defer { material.resetBytes(in: 0..<material.count) }
                        guard !Task.isCancelled, self.generation == request else { return }
                        try await quickUnlock.cache(material, registration: enrollment, request: request)
                        registration = enrollment
                    } catch {
                        guard !Task.isCancelled, self.generation == request else { return }
                        self.quickUnlockFailure = error is CancellationError ? .cancelled : (error as? QuickUnlockFailure) ?? .storageFailed
                    }
                } else if let attempt {
                    self.quickUnlock?.forget(attempt)
                }
                guard !Task.isCancelled, self.generation == request else { return }
                self.apply(vault)
                self.quickUnlockRegistration = registration
                self.unlockTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.state = error is CancellationError ? .locked : .error((error as? VaultFailure) ?? .corruptedDatabase)
                self.unlockTask = nil
            }
        }
    }

    func unlockWithTouchID() {
        refreshQuickUnlockAvailability()
        guard isLocked, state != .unlocking, canQuickUnlock,
              let repository, let quickUnlock, let url = fileURL,
              let registration = quickUnlock.registration(for: url) else { return }
        let request = UUID()
        generation = request
        state = .unlocking
        quickUnlockFailure = nil
        unlockTask = Task { [weak self] in
            do {
                var material = try await quickUnlock.recover(registration: registration, request: request)
                defer { material.resetBytes(in: 0..<material.count) }
                guard !Task.isCancelled, let self, self.generation == request else { return }
                let vault = try await repository.load(keyMaterial: material)
                guard !Task.isCancelled, self.generation == request else { return }
                guard registration.matchesOpenedVault(vault.fileURL), quickUnlock.isCurrent(registration) else {
                    repository.lock()
                    throw QuickUnlockFailure.missingKey
                }
                self.apply(vault)
                self.quickUnlockRegistration = registration
                self.unlockTask = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                if let failure = error as? VaultFailure, failure != .wrongPassword {
                    self.state = .error(failure)
                } else {
                    self.state = .locked
                    self.quickUnlockFailure = error is CancellationError ? .cancelled : (error as? QuickUnlockFailure) ?? .invalidMaterial
                    if (error as? VaultFailure) == .wrongPassword || self.quickUnlockFailure == .missingKey || self.quickUnlockFailure == .invalidMaterial {
                        quickUnlock.forget(registration)
                    }
                }
                self.refreshQuickUnlockAvailability()
                self.unlockTask = nil
            }
        }
    }

    func waitForUnlock() async {
        await unlockTask?.value
        await waitForRefresh()
    }

    func run(_ command: VaultCommand, selectNew: Bool = false, session: UUID? = nil) {
        guard session == nil || session == generation,
              !isLocked, !isBusy, let repository else { return }
        let request = generation
        let oldIDs = Set(items.map(\.id))
        let oldGroupIDs = Set(groups.map(\.id))
        isBusy = true
        operationFailure = nil
        lastCommandApplied = false
        operationTask = Task { [weak self] in
            do {
                let result = try await repository.execute(command)
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.apply(result.vault)
                if case .reload = command {
                    self.newItemDraft = nil
                    self.selectionBeforeNewItem = nil
                    self.hasDraft = false
                    self.editorGeneration = UUID()
                    self.lastRefreshFailure = nil
                }
                self.lastCommandApplied = true
                if case .createGroup = command,
                   let created = result.vault.groups.first(where: { !oldGroupIDs.contains($0.id) }) {
                    self.navigate(to: .group(created))
                }
                if selectNew {
                    self.searchQuery = ""
                    self.selectedItemID = result.vault.entries.first { !oldIDs.contains($0.id) }?.id
                }
                self.loadSelection()
                await self.selectionTask?.value
                guard !Task.isCancelled, self.generation == request else { return }
                if case .createEntry(let draft) = command, self.newItemDraft?.id == draft.id {
                    self.newItemDraft = nil
                    self.selectionBeforeNewItem = nil
                    self.hasDraft = false
                }
                self.operationFailure = result.saveFailure
                self.isBusy = false
                self.refreshIfNeeded()
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.operationFailure = (error as? VaultFailure) ?? .invalidOperation
                if self.operationFailure == .credentialsChanged { self.forgetSessionQuickUnlock() }
                self.isBusy = false
                self.refreshIfNeeded()
            }
        }
    }

    func waitForOperation() async {
        await operationTask?.value
        await waitForRefresh()
    }
    func waitForSelection() async { await selectionTask?.value }

    func refreshFromDisk() {
        guard !isLocked, repository != nil else { return }
        refreshPending = true
        refreshIfNeeded()
    }

    private func refreshIfNeeded() {
        guard refreshPending, !isLocked, !isBusy, !isDirty, !hasDraft, inspectedEntryID == nil,
              let repository else { return }
        refreshPending = false
        isBusy = true
        let request = generation
        refreshTask = Task { [weak self] in
            do {
                let vault = try await repository.refresh()
                guard !Task.isCancelled, let self, self.generation == request else { return }
                if let vault {
                    self.apply(vault)
                    self.loadSelection(clearingCurrent: false)
                }
                await self.selectionTask?.value
                guard !Task.isCancelled, self.generation == request else { return }
                self.lastRefreshFailure = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                let failure = (error as? VaultFailure) ?? .failedToReadFile
                if failure == .credentialsChanged { self.forgetSessionQuickUnlock() }
                if self.lastRefreshFailure != failure {
                    self.operationFailure = failure
                    self.lastRefreshFailure = failure
                }
            }
            guard let self, self.generation == request else { return }
            self.refreshTask = nil
            self.isBusy = false
            self.refreshIfNeeded()
        }
    }

    func waitForRefresh() async {
        while let task = refreshTask { await task.value }
        await selectionTask?.value
    }

    private func loadSelection(clearingCurrent: Bool = true) {
        selectionTask?.cancel()
        if clearingCurrent { selectedEntry = nil }
        let selection = UUID()
        selectionGeneration = selection
        guard let id = selectedItemID, let repository, !isLocked else { return }
        let request = generation
        selectionTask = Task { [weak self] in
            do {
                let entry = try await repository.entry(id)
                guard !Task.isCancelled, let self, self.generation == request,
                      self.selectionGeneration == selection, self.selectedItemID == id else { return }
                self.selectedEntry = entry
            } catch {
                guard !Task.isCancelled, let self, self.generation == request, self.selectionGeneration == selection else { return }
                self.selectedEntry = nil
                self.operationFailure = (error as? VaultFailure) ?? .invalidOperation
            }
        }
    }

    func refreshOTP() async {
        guard let id = selectedItemID, selectedEntry?.oneTimePassword != nil, !isBusy, let repository else { return }
        let request = generation
        if let entry = try? await repository.entry(id), request == generation, selectedItemID == id {
            selectedEntry?.oneTimePassword = entry.oneTimePassword
        }
    }

    func history(_ id: UUID) async throws -> [VaultEntry] {
        guard let repository, !isLocked else { throw VaultFailure.invalidOperation }
        let request = generation
        let result = try await repository.history(id)
        guard request == generation else { throw CancellationError() }
        return result
    }

    func attachment(_ id: UUID, name: String) async throws -> Data {
        guard let repository, !isLocked else { throw VaultFailure.invalidOperation }
        let request = generation
        let result = try await repository.attachment(id, name: name)
        guard request == generation else { throw CancellationError() }
        return result
    }

    private func apply(_ vault: Vault) {
        snapshotRevision = UUID()
        vaultName = vault.name
        groups = vault.groups
        collapsedGroupIDs.formIntersection(Set(vault.groups.map(\.id)))
        items = vault.entries
        isDirty = vault.isDirty
        if let url = vault.fileURL {
            if fileURL != url { quickUnlockRegistration = nil }
            fileURL = url
            preferences?.set(url.path, forKey: "lastVaultPath")
        }
        state = .unlocked
        refreshQuickUnlockAvailability()
        if let fileURL, fileURL != monitoredURL {
            fileMonitor?.invalidate()
            monitoredURL = fileURL
            fileMonitor = VaultFileMonitor(url: fileURL) { [weak self] in self?.refreshFromDisk() }
            // Catch changes between the repository load and monitor installation,
            // including time spent awaiting biometric enrollment.
            refreshPending = true
        }
        if case .group(let old) = sidebarSelection {
            sidebarSelection = vault.groups.first(where: { $0.id == old.id }).map(SidebarSelection.group) ?? .allItems
            if case let .group(selected) = sidebarSelection {
                collapsedGroupIDs.subtract(VaultGroupTree.ancestors(of: selected.id, in: groups))
            }
        }
        reconcileSelection()
        refreshIfNeeded()
    }
}
