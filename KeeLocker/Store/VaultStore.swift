import Foundation

@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var items: [VaultItem] = []
    @Published var selectedItemID: VaultItem.ID? { didSet { if oldValue != selectedItemID { loadSelection() } } }
    @Published private(set) var selectedEntry: VaultEntry?
    @Published private(set) var newItemDraft: VaultEntry?
    @Published private(set) var isBusy = false
    @Published private(set) var isDirty = false
    @Published var operationFailure: VaultFailure? {
        didSet { if operationFailure == nil { scheduleAutomaticIcons() } }
    }
    @Published var quickUnlockFailure: QuickUnlockFailure?
    @Published private(set) var touchIDAvailable = false
    @Published var isInspectingBackups = false {
        didSet {
            if isInspectingBackups { pauseAutomaticIcons() }
            else { refreshIfNeeded(); scheduleAutomaticIcons() }
        }
    }
    @Published private(set) var canQuickUnlock = false
    private(set) var lastCommandApplied = false
    @Published var hasDraft = false {
        didSet {
            if hasDraft { pauseAutomaticIcons() }
            else { refreshIfNeeded(); scheduleAutomaticIcons() }
        }
    }
    @Published var inspectedEntryID: UUID? {
        didSet {
            if inspectedEntryID != nil { pauseAutomaticIcons() }
            else { refreshIfNeeded(); scheduleAutomaticIcons() }
        }
    }
    @Published private(set) var automaticallyDownloadsIcons = false
    @Published private(set) var editorGeneration = UUID()
    @Published private(set) var snapshotRevision = UUID()
    @Published var sidebarSelection: SidebarSelection = .allItems
    @Published var searchQuery = ""
    @Published private(set) var state: VaultState = .noVault
    @Published private(set) var groups: [VaultGroup] = []
    @Published private(set) var customIcons: [VaultCustomIcon] = []
    @Published private(set) var recycleBinID: UUID?
    @Published private(set) var recycleBinEnabled = true
    private(set) var recycledGroupIDs: Set<UUID> = []
    @Published private(set) var collapsedGroupIDs: Set<UUID> = []
    @Published private(set) var vaultName = "KeeLocker"
    @Published private(set) var fileURL: URL?
    @Published private(set) var capabilities: VaultCapabilities = .readOnly
    private var repository: (any VaultRepository)?
    private let quickUnlock: (any QuickUnlockService)?
    private let backupDirectory: URL?
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
    private let websiteIconLoader: FaviconDownloader.Loader
    private var automaticIconTask: Task<Void, Never>?
    private var automaticIconGeneration = UUID()
    private struct IconAttempt: Hashable {
        let id: UUID
        let website: String
    }
    private struct AutomaticIconCandidate {
        let item: VaultItem
        let origin: URL
    }
    private var automaticIconCandidates: [AutomaticIconCandidate] = []
    private var automaticIconCandidateIndex = 0
    private var automaticIconCandidatesRevision: UUID?
    // Rejected stale/detail results only suppress retries for that snapshot.
    private var iconAttempts: Set<IconAttempt> = []
    private var websiteIcons: [URL: VaultCustomIcon] = [:]
    private var failedIconOrigins: Set<URL> = []

    init(preferences: UserDefaults? = nil, quickUnlock: (any QuickUnlockService)? = nil,
         backupDirectory: URL? = nil,
         websiteIconLoader: @escaping FaviconDownloader.Loader = { try await FaviconDownloader().download($0) }) {
        self.preferences = preferences
        self.quickUnlock = quickUnlock
        self.backupDirectory = backupDirectory
        self.websiteIconLoader = websiteIconLoader
        if let path = preferences?.string(forKey: "lastVaultPath"), !path.isEmpty {
            openFile(URL(fileURLWithPath: path))
        }
    }

    deinit { unlockTask?.cancel(); refreshTask?.cancel(); automaticIconTask?.cancel() }

    init(items: [VaultItem]) {
        quickUnlock = nil
        backupDirectory = nil
        websiteIconLoader = { try await FaviconDownloader().download($0) }
        let memory = MemoryVaultRepository(items: items)
        repository = memory
        capabilities = memory.capabilities
        apply(memory.vault)
    }

    var isLocked: Bool { state != .unlocked }
    var sessionID: UUID { generation }
    var requiresPassword: Bool { repository?.requiresPassword ?? false }
    var supportsRecovery: Bool { repository?.supportsRecovery == true && fileURL != nil }
    var attachmentExportBackupDirectory: URL? { backupDirectory }
    var canEnableTouchID: Bool { repository?.supportsQuickUnlock == true && fileURL != nil && touchIDAvailable }
    var ordinaryGroups: [VaultGroup] { groups.filter { !recycledGroupIDs.contains($0.id) } }
    var activeItems: [VaultItem] { items.filter { !recycledGroupIDs.contains($0.group.id) } }
    var activeItemCount: Int { activeItems.count }
    var recycleBinCount: Int { items.count - activeItemCount }
    var canCreateInCurrentScope: Bool {
        guard !isLocked, !isBusy, !hasDraft, capabilities.canCreate else { return false }
        switch sidebarSelection {
        case .recycleBin: return false
        case .group(let group): return !recycledGroupIDs.contains(group.id)
        default: return true
        }
    }

    func isInRecycleBin(id: UUID) -> Bool {
        items.contains { $0.id == id && recycledGroupIDs.contains($0.group.id) }
    }

    func canEditEntry(id: UUID) -> Bool {
        !isLocked && capabilities.canEdit && items.contains { $0.id == id } && !isInRecycleBin(id: id)
    }

    var groupCreationParent: VaultGroup? {
        guard canCreateInCurrentScope else { return nil }
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
        VaultGroupTree.rows(ordinaryGroups, collapsed: collapsedGroupIDs)
    }
    var failure: VaultFailure? {
        if case let .error(failure) = state { return failure }
        return nil
    }

    func openFile(_ url: URL) {
        use(RustVaultRepository(url: url, backupDirectory: backupDirectory), fileURL: url)
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
            scopedItems = activeItems
        case .favorites:
            scopedItems = activeItems.filter(\.isFavorite)
        case .recycleBin:
            scopedItems = items.filter { recycledGroupIDs.contains($0.group.id) }
        case let .group(group):
            scopedItems = activeItems.filter { $0.group.id == group.id }
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
        case .recycleBin: "Recycle Bin"
        case let .group(group): group.rawValue
        }
    }

    var favoriteCount: Int {
        activeItems.filter(\.isFavorite).count
    }

    func count(in group: VaultGroup) -> Int {
        activeItems.filter { $0.group.id == group.id }.count
    }

    func navigate(to destination: SidebarSelection) {
        if case let .group(group) = destination {
            guard !recycledGroupIDs.contains(group.id) else { return }
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
        guard canEditEntry(id: item.id), !item.isRedacted else { return }
        run(.updateEntry(item))
    }

    func saveItem(_ item: VaultItem) async -> Bool {
        guard !isLocked, !isBusy, !item.isRedacted else { return false }
        let creating = newItemDraft?.id == item.id
        guard newItemDraft == nil || creating,
              creating ? capabilities.canCreate : canEditEntry(id: item.id) else { return false }
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
        state = repository == nil ? .noVault : .locked
        pauseAutomaticIcons()
        iconAttempts.removeAll()
        websiteIcons.removeAll()
        failedIconOrigins.removeAll()
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
        isInspectingBackups = false
        operationFailure = nil
        quickUnlockFailure = nil
        lastCommandApplied = false
        items = []
        newItemDraft = nil
        selectionBeforeNewItem = nil
        groups = []
        recycleBinID = nil
        recycleBinEnabled = true
        recycledGroupIDs = []
        customIcons = []
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
        guard isLocked, !isBusy, state != .unlocking, let repository else { return }
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
        guard isLocked, !isBusy, state != .unlocking, canQuickUnlock,
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
        guard allows(command) else {
            lastCommandApplied = false
            operationFailure = .invalidOperation
            return
        }
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
                self.scheduleAutomaticIcons()
            } catch {
                guard !Task.isCancelled, let self, self.generation == request else { return }
                self.operationFailure = (error as? VaultFailure) ?? .invalidOperation
                if self.operationFailure == .credentialsChanged { self.forgetSessionQuickUnlock() }
                self.isBusy = false
                self.refreshIfNeeded()
                self.scheduleAutomaticIcons()
            }
        }
    }

    private func allows(_ command: VaultCommand) -> Bool {
        func writableGroup(_ id: UUID) -> Bool {
            ordinaryGroups.contains { $0.id == id }
        }
        switch command {
        case .createEntry(let entry):
            return capabilities.canCreate && !entry.isRedacted && writableGroup(entry.group.id)
        case .updateEntry(let entry):
            return canEditEntry(id: entry.id) && !entry.isRedacted && writableGroup(entry.group.id)
        case .deleteEntry(let id):
            return capabilities.canDelete && canEditEntry(id: id)
        case .restoreEntry(let id):
            return capabilities.canEdit && isInRecycleBin(id: id)
        case .deleteEntryPermanently(let id):
            return capabilities.canDelete && isInRecycleBin(id: id)
        case .moveEntry(let id, let destination):
            return canEditEntry(id: id) && writableGroup(destination)
        case .createGroup(let parent, _):
            return capabilities.canCreate && writableGroup(parent)
        case .renameGroup(let id, _), .deleteGroup(let id):
            return capabilities.canEdit && writableGroup(id)
        case .moveGroup(let id, let destination):
            return capabilities.canEdit && writableGroup(id) && writableGroup(destination)
        case .putAttachment(let id, _, _), .deleteAttachment(let id, _):
            return canEditEntry(id: id)
        case .save, .saveAs, .reload:
            return true
        }
    }

    func waitForOperation() async {
        await operationTask?.value
        await waitForRefresh()
    }
    func waitForSelection() async { await selectionTask?.value }

    func backups() async throws -> [VaultBackup] {
        guard supportsRecovery, !isBusy, !hasDraft, let repository else { throw VaultFailure.invalidOperation }
        let request = generation
        let result = try await repository.backups()
        guard !Task.isCancelled, request == generation else { throw CancellationError() }
        return result
    }

    func restoreBackup(_ backup: VaultBackup, to destination: URL, password: String, keyFile: URL?) async throws -> VaultRecoveryResult {
        guard supportsRecovery, !isBusy, !hasDraft, let repository else { throw VaultFailure.invalidOperation }
        let request = generation
        isBusy = true
        defer {
            if request == generation {
                isBusy = false
                refreshIfNeeded()
                scheduleAutomaticIcons()
            }
        }
        let result = try await repository.restoreBackup(backup, to: destination, password: password, keyFile: keyFile)
        guard !Task.isCancelled, request == generation else { throw CancellationError() }
        return result
    }

    func refreshFromDisk() {
        guard !isLocked, repository != nil else { return }
        refreshPending = true
        refreshIfNeeded()
    }

    private func refreshIfNeeded() {
        guard refreshPending, !isLocked, !isBusy, !isDirty, !hasDraft, !isInspectingBackups, inspectedEntryID == nil,
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
            self.scheduleAutomaticIcons()
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
        recycledGroupIDs = vault.recycledGroupIDs
        recycleBinID = vault.recycleBinID.flatMap { recycledGroupIDs.contains($0) ? $0 : nil }
        recycleBinEnabled = vault.recycleBinEnabled
        customIcons = vault.customIcons
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
            if recycledGroupIDs.contains(old.id) { sidebarSelection = .recycleBin }
            else { sidebarSelection = ordinaryGroups.first(where: { $0.id == old.id }).map(SidebarSelection.group) ?? .allItems }
            if case let .group(selected) = sidebarSelection {
                collapsedGroupIDs.subtract(VaultGroupTree.ancestors(of: selected.id, in: groups))
            }
        }
        reconcileSelection()
        refreshIfNeeded()
        scheduleAutomaticIcons()
    }

    func setAutomaticIconDownloads(_ enabled: Bool) {
        guard automaticallyDownloadsIcons != enabled else { return }
        automaticallyDownloadsIcons = enabled
        pauseAutomaticIcons()
        iconAttempts.removeAll()
        websiteIcons.removeAll()
        failedIconOrigins.removeAll()
        scheduleAutomaticIcons()
    }

    private func pauseAutomaticIcons() {
        automaticIconGeneration = UUID()
        automaticIconTask?.cancel()
        automaticIconTask = nil
        automaticIconCandidates.removeAll()
        automaticIconCandidateIndex = 0
        automaticIconCandidatesRevision = nil
    }

    private var canDownloadAutomaticIcons: Bool {
        automaticallyDownloadsIcons && !isLocked && capabilities.canEdit && !isBusy && !isDirty
            && !hasDraft && !isInspectingBackups && inspectedEntryID == nil && !refreshPending && operationFailure == nil
    }

    private func scheduleAutomaticIcons() {
        guard canDownloadAutomaticIcons, automaticIconTask == nil, let repository else { return }
        if automaticIconCandidatesRevision != snapshotRevision {
            automaticIconCandidatesRevision = snapshotRevision
            iconAttempts.removeAll()
            automaticIconCandidates = activeItems.compactMap { item in
                guard item.needsWebsiteIcon, let origin = FaviconDownloader.origin(for: item.website),
                      !failedIconOrigins.contains(origin) else { return nil }
                return AutomaticIconCandidate(item: item, origin: origin)
            }
            automaticIconCandidateIndex = 0
        }
        var next: AutomaticIconCandidate?
        while automaticIconCandidateIndex < automaticIconCandidates.count {
            let candidate = automaticIconCandidates[automaticIconCandidateIndex]
            automaticIconCandidateIndex += 1
            if !failedIconOrigins.contains(candidate.origin),
               !iconAttempts.contains(IconAttempt(id: candidate.item.id, website: candidate.item.website)) {
                next = candidate
                break
            }
        }
        guard let next else { return }
        let item = next.item
        let origin = next.origin
        let session = generation
        let request = automaticIconGeneration
        let candidateRevision = snapshotRevision
        let attempt = IconAttempt(id: item.id, website: item.website)
        automaticIconTask = Task { [weak self] in
            guard let self else { return }
            var retryWhenIdle = false
            defer {
                if self.generation == session, self.automaticIconGeneration == request {
                    if retryWhenIdle, self.automaticIconCandidatesRevision == candidateRevision {
                        self.automaticIconCandidateIndex = max(0, self.automaticIconCandidateIndex - 1)
                    }
                    self.automaticIconTask = nil
                    self.scheduleAutomaticIcons()
                }
            }
            do {
                if self.failedIconOrigins.contains(origin) {
                    self.iconAttempts.insert(attempt)
                    return
                }
                let icon: VaultCustomIcon
                if let cached = self.websiteIcons[origin] { icon = cached }
                else { icon = try await self.websiteIconLoader(origin) }
                guard !Task.isCancelled, self.generation == session,
                      self.automaticIconGeneration == request else { return }
                self.websiteIcons[origin] = icon
                guard self.canDownloadAutomaticIcons else { retryWhenIdle = true; return }
                // Reserve the normal mutation slot while obtaining a complete current entry.
                // List summaries are redacted and cannot be used for replacement edits.
                self.isBusy = true
                let revision = self.snapshotRevision
                var current: VaultEntry
                do { current = try await repository.entry(item.id) }
                catch {
                    guard self.generation == session else { return }
                    self.isBusy = false
                    if !Task.isCancelled, self.automaticIconGeneration == request {
                        self.iconAttempts.insert(attempt)
                    }
                    self.refreshIfNeeded()
                    self.scheduleAutomaticIcons()
                    return
                }
                guard self.generation == session else { return }
                self.isBusy = false
                if !Task.isCancelled, self.automaticIconGeneration == request,
                   current.website != item.website || !current.needsWebsiteIcon || current.isRedacted {
                    self.iconAttempts.insert(attempt)
                }
                guard !Task.isCancelled, self.automaticIconGeneration == request,
                      self.canDownloadAutomaticIcons, self.snapshotRevision == revision,
                      !self.isInRecycleBin(id: current.id), !self.recycledGroupIDs.contains(current.group.id),
                      current.website == item.website, current.needsWebsiteIcon, !current.isRedacted else {
                    retryWhenIdle = !self.canDownloadAutomaticIcons
                    self.refreshIfNeeded()
                    self.scheduleAutomaticIcons()
                    return
                }
                self.iconAttempts.insert(attempt)
                current.useWebsiteIcon(icon, origin: origin)
                current.modifiedAt = .now
                self.run(.updateEntry(current), session: session)
                await self.operationTask?.value
                if self.generation == session, self.lastCommandApplied {
                    // Eligibility now comes from the persisted origin. Retaining a
                    // successful attempt would block switching back to this Website.
                    self.iconAttempts.remove(attempt)
                }
            } catch {
                guard !Task.isCancelled, self.generation == session,
                      self.automaticIconGeneration == request else { return }
                self.failedIconOrigins.insert(origin)
                self.iconAttempts.insert(attempt)
            }
        }
    }

    func waitForAutomaticIcons() async {
        while let task = automaticIconTask { await task.value }
    }
}
