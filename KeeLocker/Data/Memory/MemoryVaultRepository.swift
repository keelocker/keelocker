import Foundation

@MainActor
final class MemoryVaultRepository: VaultRepository {
    let capabilities = VaultCapabilities.editable
    let requiresPassword = false
    private(set) var vault: Vault
    private var previousParents: [UUID: UUID] = [:]
    private var versions: [UUID: [VaultEntry]] = [:]

    init(items: [VaultItem] = MockVault.items) {
        vault = Vault(name: "Personal Vault", groups: VaultGroup.sampleGroups, entries: items)
    }

    init(vault: Vault) { self.vault = vault }

    func load(password: String, keyFile: URL?) async throws -> Vault { vault }

    func entry(_ id: UUID) async throws -> VaultEntry {
        guard let entry = vault.entries.first(where: { $0.id == id }) else { throw VaultFailure.invalidOperation }
        return entry
    }

    func execute(_ command: VaultCommand) async throws -> VaultCommandResult {
        switch command {
        case .reload: break
        case .createEntry(let entry):
            try requireWritableGroup(entry.group.id)
            guard !entry.isRedacted, !vault.entries.contains(where: { $0.id == entry.id }) else { throw VaultFailure.invalidOperation }
            vault.entries.insert(committed(entry), at: 0)
        case .updateEntry(let entry):
            try requireWritableEntry(entry.id)
            try requireWritableGroup(entry.group.id)
            guard !entry.isRedacted else { throw VaultFailure.invalidOperation }
            guard let i = vault.entries.firstIndex(where: { $0.id == entry.id }) else { throw VaultFailure.invalidOperation }
            vault.entries[i] = committed(entry)
        case .deleteEntry(let id):
            try requireWritableEntry(id)
            if vault.recycleBinEnabled {
                let bin = try ensureRecycleBin()
                try move(id, to: bin, preservingHistory: true)
            } else {
                vault.entries.removeAll { $0.id == id }
                versions[id] = nil
                previousParents[id] = nil
            }
        case .restoreEntry(let id):
            guard let source = vault.entries.first(where: { $0.id == id }),
                  vault.recycledGroupIDs.contains(source.group.id),
                  let root = vault.groups.first(where: { $0.parentID == nil }) else { throw VaultFailure.invalidOperation }
            let previous = previousParents[id].flatMap { parent in
                vault.groups.first { $0.id == parent && !vault.recycledGroupIDs.contains($0.id) }
            }
            try move(id, to: previous ?? root, preservingHistory: true)
        case .deleteEntryPermanently(let id):
            guard let source = vault.entries.first(where: { $0.id == id }),
                  vault.recycledGroupIDs.contains(source.group.id) else { throw VaultFailure.invalidOperation }
            vault.entries.removeAll { $0.id == id }
            versions[id] = nil
            previousParents[id] = nil
        case .moveEntry(let id, let groupID):
            try requireWritableEntry(id)
            try requireWritableGroup(groupID)
            guard let group = vault.groups.first(where: { $0.id == groupID }) else { throw VaultFailure.invalidOperation }
            try move(id, to: group)
        case .createGroup(let parent, let name):
            try requireWritableGroup(parent)
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultFailure.invalidOperation }
            guard let group = vault.groups.first(where: { $0.id == parent }) else { throw VaultFailure.invalidOperation }
            vault.groups.append(VaultGroup(id: UUID(), name: name, parentID: parent, path: group.path + " / " + name))
        case .renameGroup(let id, let name):
            try requireWritableGroup(id)
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultFailure.invalidOperation }
            guard let i = vault.groups.firstIndex(where: { $0.id == id }) else { throw VaultFailure.invalidOperation }
            vault.groups[i].name = name
            rebuildPaths()
        case .moveGroup(let id, let parent):
            try requireWritableGroup(id)
            try requireWritableGroup(parent)
            guard vault.groups.first(where: { $0.id == id })?.parentID != nil else { throw VaultFailure.invalidOperation }
            var ancestor: UUID? = parent
            var visited: Set<UUID> = []
            while let a = ancestor {
                guard a != id, visited.insert(a).inserted else { throw VaultFailure.invalidOperation }
                ancestor = vault.groups.first(where: { $0.id == a })?.parentID
            }
            guard let i = vault.groups.firstIndex(where: { $0.id == id }), vault.groups.contains(where: { $0.id == parent }) else { throw VaultFailure.invalidOperation }
            vault.groups[i].parentID = parent
            rebuildPaths()
        case .deleteGroup(let id):
            try requireWritableGroup(id)
            guard vault.groups.first(where: { $0.id == id })?.parentID != nil else { throw VaultFailure.invalidOperation }
            guard !vault.entries.contains(where: { $0.group.id == id }), !vault.groups.contains(where: { $0.parentID == id }) else { throw VaultFailure.invalidOperation }
            vault.groups.removeAll { $0.id == id }
        default: throw VaultFailure.invalidOperation
        }
        return VaultCommandResult(vault: vault)
    }

    func history(_ id: UUID) async throws -> [VaultEntry] { versions[id] ?? [] }

    private func requireWritableGroup(_ id: UUID) throws {
        guard vault.groups.contains(where: { $0.id == id }), !vault.recycledGroupIDs.contains(id) else {
            throw VaultFailure.invalidOperation
        }
    }

    private func requireWritableEntry(_ id: UUID) throws {
        guard let entry = vault.entries.first(where: { $0.id == id }) else { throw VaultFailure.invalidOperation }
        try requireWritableGroup(entry.group.id)
    }

    private func ensureRecycleBin() throws -> VaultGroup {
        if let id = vault.recycleBinID, vault.recycledGroupIDs.contains(id),
           let bin = vault.groups.first(where: { $0.id == id }) { return bin }
        guard let root = vault.groups.first(where: { $0.parentID == nil }) else { throw VaultFailure.invalidOperation }
        let bin = VaultGroup(id: UUID(), name: "Recycle Bin", parentID: root.id,
                             path: root.path + " / Recycle Bin", iconName: "trash",
                             createdAt: .now, modifiedAt: .now)
        vault.groups.append(bin)
        vault.recycleBinID = bin.id
        return bin
    }

    private func move(_ id: UUID, to group: VaultGroup, preservingHistory: Bool = false) throws {
        guard let i = vault.entries.firstIndex(where: { $0.id == id }) else { throw VaultFailure.invalidOperation }
        let previous = vault.entries[i]
        if !preservingHistory { versions[id, default: []].insert(previous, at: 0) }
        previousParents[id] = previous.group.id
        vault.entries[i].group = group
        if !preservingHistory { vault.entries[i].historyCount = (versions[id] ?? []).count }
    }

    private func committed(_ entry: VaultEntry) -> VaultEntry {
        var result = entry
        if case .imported(let icon) = result.icon {
            let stored = vault.customIcons.first { $0.data == icon.data } ?? icon
            if !vault.customIcons.contains(where: { $0.id == stored.id }) { vault.customIcons.append(stored) }
            result.icon = .custom(stored)
        }
        result.isIconModified = false
        return result
    }

    private func rebuildPaths() {
        func path(_ group: VaultGroup) -> String {
            guard let parent = vault.groups.first(where: { $0.id == group.parentID }) else { return group.name }
            return path(parent) + " / " + group.name
        }
        vault.groups = vault.groups.map { var group = $0; group.path = path(group); return group }
        for i in vault.entries.indices {
            if let group = vault.groups.first(where: { $0.id == vault.entries[i].group.id }) { vault.entries[i].group = group }
        }
    }

    func replaceEntries(_ entries: [VaultEntry]) { vault.entries = entries }
}

enum MockVault {
    static let items: [VaultItem] = [
        VaultItem(
            title: "Apple ID",
            username: "mila.petrenko@icloud.com",
            password: "harbor-lilac-orbit-47",
            website: "https://appleid.apple.com",
            notes: "Primary Apple account for App Store purchases and device backups.",
            tags: ["personal", "important"],
            customFields: [
                CustomField(name: "Recovery key", value: "RK8M-29QF-L7PA-2G4V", isSensitive: true),
                CustomField(name: "Support PIN", value: "8416", isSensitive: true)
            ],
            oneTimePassword: OneTimePassword(code: "482 731", period: 30),
            group: .personal,
            isFavorite: true,
            iconName: "apple.logo",
            iconColor: .graphite,
            modifiedAt: .now.addingTimeInterval(-1_940)
        ),
        VaultItem(
            title: "GitHub",
            username: "mila-petrenko",
            password: "quiet-signal-birch-992",
            website: "https://github.com",
            notes: "Development account. Recovery codes are stored in the secure archive.",
            tags: ["work", "developer"],
            customFields: [CustomField(name: "SSH key", value: "ed25519 · MBP 14", isSensitive: false)],
            oneTimePassword: OneTimePassword(code: "091 426", period: 30),
            group: .work,
            isFavorite: true,
            iconName: "chevron.left.forwardslash.chevron.right",
            iconColor: .purple,
            modifiedAt: .now.addingTimeInterval(-8_620)
        ),
        VaultItem(
            title: "Figma",
            username: "mila@northstar.studio",
            password: "canvas-ember-moon-184",
            website: "https://figma.com",
            notes: "Northstar Studio workspace owner.",
            tags: ["work", "design"],
            group: .work,
            iconName: "paintbrush.pointed.fill",
            iconColor: .pink,
            modifiedAt: .now.addingTimeInterval(-22_540)
        ),
        VaultItem(
            title: "Notion",
            username: "mila@northstar.studio",
            password: "paper-crane-willow-603",
            website: "https://notion.so",
            notes: "Team wiki and project planning.",
            tags: ["work", "docs"],
            group: .work,
            iconName: "doc.text.fill",
            iconColor: .graphite,
            modifiedAt: .now.addingTimeInterval(-76_000)
        ),
        VaultItem(
            title: "Proton Mail",
            username: "m.petrenko@proton.me",
            password: "violet-cabin-snow-725",
            website: "https://mail.proton.me",
            notes: "Private email address for financial accounts.",
            tags: ["personal", "email"],
            oneTimePassword: OneTimePassword(code: "774 209", period: 30),
            group: .personal,
            isFavorite: true,
            iconName: "envelope.fill",
            iconColor: .indigo,
            modifiedAt: .now.addingTimeInterval(-172_800)
        ),
        VaultItem(
            title: "Raiffeisen Online",
            username: "mpetrenko",
            password: "river-gold-cedar-316",
            website: "https://online.raiffeisen.ru",
            notes: "Daily banking. Never share the confirmation code by phone.",
            tags: ["finance", "bank"],
            customFields: [CustomField(name: "Client ID", value: "184 206 731", isSensitive: true)],
            group: .finance,
            iconName: "building.columns.fill",
            iconColor: .orange,
            modifiedAt: .now.addingTimeInterval(-259_220)
        ),
        VaultItem(
            title: "Wise",
            username: "+49 151 7284 0613",
            password: "spruce-market-wave-508",
            website: "https://wise.com",
            notes: "Travel card and international transfers.",
            tags: ["finance", "travel"],
            group: .finance,
            iconName: "arrow.left.arrow.right",
            iconColor: .green,
            modifiedAt: .now.addingTimeInterval(-431_000)
        ),
        VaultItem(
            title: "Air France",
            username: "mila.petrenko@icloud.com",
            password: "runway-sunrise-linen-637",
            website: "https://wwws.airfrance.com",
            notes: "Flying Blue account.",
            tags: ["travel", "miles"],
            customFields: [CustomField(name: "Flying Blue", value: "3084 726 193", isSensitive: false)],
            group: .travel,
            iconName: "airplane",
            iconColor: .blue,
            modifiedAt: .now.addingTimeInterval(-691_000)
        ),
        VaultItem(
            title: "Booking.com",
            username: "mila.petrenko@icloud.com",
            password: "hotel-fern-lantern-289",
            website: "https://booking.com",
            notes: "Personal travel reservations.",
            tags: ["travel"],
            group: .travel,
            iconName: "bed.double.fill",
            iconColor: .cyan,
            modifiedAt: .now.addingTimeInterval(-1_036_800)
        )
    ]
}
