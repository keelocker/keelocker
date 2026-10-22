import Foundation

struct VaultItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var username: String
    var password: String
    var website: String
    var notes: String
    var tags: [String]
    var customFields: [CustomField]
    var oneTimePassword: OneTimePassword?
    var group: VaultGroup
    var isFavorite: Bool
    var iconName: String
    var iconColor: ItemColor
    var icon: VaultEntryIcon?
    // Encrypted with the entry; nil means an icon chosen independently of Website.
    var websiteIconOrigin: URL?
    var hasExplicitIcon = false
    // Only an icon choice/import/download changes the KDBX icon during an edit.
    var isIconModified = false
    var modifiedAt: Date
    var createdAt: Date?
    var attachments: [AttachmentMetadata] = []
    var historyCount: Int = 0
    // List snapshots omit secrets and must never replace a complete entry.
    var isRedacted = false

    mutating func chooseIcon(_ icon: VaultEntryIcon) {
        self.icon = icon
        websiteIconOrigin = nil
        hasExplicitIcon = true
        isIconModified = true
    }

    mutating func useWebsiteIcon(_ icon: VaultCustomIcon, origin: URL) {
        self.icon = .imported(icon)
        websiteIconOrigin = origin
        hasExplicitIcon = false
        isIconModified = true
    }

    init(
        id: UUID = UUID(),
        title: String,
        username: String,
        password: String,
        website: String,
        notes: String,
        tags: [String],
        customFields: [CustomField] = [],
        oneTimePassword: OneTimePassword? = nil,
        group: VaultGroup,
        isFavorite: Bool = false,
        iconName: String,
        iconColor: ItemColor,
        modifiedAt: Date,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.username = username
        self.password = password
        self.website = website
        self.notes = notes
        self.tags = tags
        self.customFields = customFields
        self.oneTimePassword = oneTimePassword
        self.group = group
        self.isFavorite = isFavorite
        self.iconName = iconName
        self.iconColor = iconColor
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }
}

struct CustomField: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var value: String
    var isSensitive: Bool

    init(id: UUID = UUID(), name: String, value: String, isSensitive: Bool = false) {
        self.id = id
        self.name = name
        self.value = value
        self.isSensitive = isSensitive
    }
}

struct OneTimePassword: Hashable, Sendable {
    var code: String
    var period: Int

    var safePeriod: Int {
        max(period, 1)
    }
}

extension VaultItem {
    var needsWebsiteIcon: Bool {
        guard !isIconModified, !hasExplicitIcon else { return false }
        if let websiteIconOrigin {
            guard let current = FaviconDownloader.origin(for: website) else { return false }
            return current != websiteIconOrigin
        }
        if case .builtIn(0) = icon { return true }
        return icon == nil && iconName == "key.fill"
    }

    static var empty: VaultItem {
        VaultItem(title: "", username: "", password: "", website: "", notes: "", tags: [],
                  group: .personal, iconName: "key.fill", iconColor: .indigo, modifiedAt: .distantPast)
    }

    var websiteURL: URL? {
        guard let components = URLComponents(string: website),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return components.url
    }
}

struct VaultGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var parentID: UUID?
    var path: String
    var iconName: String = "folder"
    var createdAt: Date?
    var modifiedAt: Date?

    var rawValue: String { path }

    static let personal = VaultGroup(id: UUID(), name: "Personal", path: "Personal", iconName: "person.crop.circle")
    static let work = VaultGroup(id: UUID(), name: "Work", path: "Work", iconName: "briefcase")
    static let finance = VaultGroup(id: UUID(), name: "Finance", path: "Finance", iconName: "creditcard")
    static let travel = VaultGroup(id: UUID(), name: "Travel", path: "Travel", iconName: "airplane")
    static let sampleGroups = [personal, work, finance, travel]
}

enum ItemColor: String, Hashable, Sendable {
    case indigo
    case blue
    case cyan
    case mint
    case green
    case orange
    case pink
    case purple
    case graphite
}

struct VaultCustomIcon: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    let data: Data
}

enum VaultEntryIcon: Hashable, Sendable {
    case builtIn(UInt64)
    case custom(VaultCustomIcon)
    case imported(VaultCustomIcon)

    var name: String {
        switch self {
        case .builtIn(let id): StandardVaultIcon.find(id)?.name ?? "Key"
        case .custom(let icon), .imported(let icon): icon.name
        }
    }

    var imageData: Data? {
        switch self {
        case .builtIn: nil
        case .custom(let icon), .imported(let icon): icon.data
        }
    }
}

struct StandardVaultIcon: Identifiable, Sendable {
    let id: UInt64
    let name: String
    let symbol: String
    let color: ItemColor

    static func find(_ id: UInt64) -> StandardVaultIcon? {
        all.first { $0.id == id }
    }

    // KDBX IDs are interoperable; SF Symbols are KeeLocker's presentation.
    static let all: [StandardVaultIcon] = {
        let definitions: [(String, String, ItemColor)] = [
            ("Key", "key.fill", .indigo), ("Network", "network", .blue),
            ("Warning", "exclamationmark.triangle.fill", .orange), ("Server", "server.rack", .graphite),
            ("Clipboard", "clipboard.fill", .orange), ("Communication", "bubble.left.and.bubble.right.fill", .green),
            ("Packages", "shippingbox.fill", .orange), ("Text editor", "square.and.pencil", .graphite),
            ("Connection", "cable.connector", .blue), ("Identity", "person.fill", .blue),
            ("Contacts", "person.crop.rectangle.fill", .green), ("Camera", "camera.fill", .graphite),
            ("Wi-Fi", "wifi", .blue), ("Key ring", "key.horizontal.fill", .indigo),
            ("Power", "bolt.fill", .orange), ("Scanner", "scanner.fill", .graphite),
            ("Bookmarks", "bookmark.fill", .pink), ("Disc", "opticaldisc.fill", .graphite),
            ("Display", "display", .blue), ("Email", "envelope.fill", .indigo),
            ("Settings", "gearshape.fill", .graphite), ("Checklist", "checklist", .green),
            ("Document", "doc.fill", .graphite), ("Desktop", "desktopcomputer", .blue),
            ("Remote connection", "point.3.connected.trianglepath.dotted", .blue), ("Inbox", "tray.fill", .indigo),
            ("Save", "externaldrive.fill", .blue), ("Remote storage", "externaldrive.connected.to.line.below.fill", .blue),
            ("Media", "play.rectangle.fill", .pink), ("Secure shell", "lock.shield.fill", .green),
            ("Terminal", "terminal.fill", .graphite), ("Printer", "printer.fill", .graphite),
            ("Storage", "internaldrive.fill", .blue), ("Launch", "play.fill", .green),
            ("Tools", "wrench.fill", .graphite), ("Internet", "globe", .blue),
            ("Compression", "archivebox.fill", .orange), ("Percentage", "percent", .green),
            ("Shared folder", "folder.badge.person.crop", .blue), ("Time", "clock.fill", .orange),
            ("Search", "magnifyingglass", .blue), ("Graphics", "paintbrush.pointed.fill", .pink),
            ("Memory", "memorychip.fill", .green), ("Trash", "trash.fill", .graphite),
            ("Note", "note.text", .orange), ("Cancel", "xmark.circle.fill", .pink),
            ("Help", "questionmark.circle.fill", .blue), ("Software", "app.fill", .purple),
            ("Folder", "folder.fill", .blue), ("Open folder", "folder", .blue),
            ("Archive", "archivebox", .orange), ("Unlocked", "lock.open.fill", .green),
            ("Locked", "lock.fill", .indigo), ("Checkmark", "checkmark.circle.fill", .green),
            ("Signature", "signature", .graphite), ("Picture", "photo.fill", .pink),
            ("Address book", "person.crop.square.fill", .green), ("Table", "tablecells.fill", .blue),
            ("Private key", "key.viewfinder", .indigo), ("Development", "chevron.left.forwardslash.chevron.right", .purple),
            ("Home", "house.fill", .green), ("Favorite", "star.fill", .orange),
            ("Linux", "terminal", .graphite), ("Web server", "server.rack", .orange),
            ("Apple", "apple.logo", .graphite), ("Reference", "book.fill", .graphite),
            ("Finance", "banknote.fill", .green), ("Certificate", "checkmark.seal.fill", .blue),
            ("Mobile", "iphone", .blue)
        ]
        return definitions.enumerated().map { id, value in
            Self(id: UInt64(id), name: value.0, symbol: value.1, color: value.2)
        }
    }()
}

enum SidebarSelection: Hashable {
    case allItems
    case favorites
    case recycleBin
    case group(VaultGroup)
}

struct VaultGroupTreeRow: Identifiable {
    let group: VaultGroup
    let depth: Int
    let hasChildren: Bool
    let isExpanded: Bool
    var id: UUID { group.id }
}

enum VaultGroupTree {
    static func recycleBinGroups(_ id: UUID?, in groups: [VaultGroup]) -> Set<UUID> {
        // Never classify the entire vault as trash for an imported root reference.
        guard let id, id.uuidString != "00000000-0000-0000-0000-000000000000",
              groups.contains(where: { $0.id == id && $0.parentID != nil }) else { return [] }
        let children = Dictionary(grouping: groups, by: \.parentID)
        var result: Set<UUID> = []
        var pending = [id]
        while let current = pending.popLast() {
            guard result.insert(current).inserted else { continue }
            pending.append(contentsOf: (children[current] ?? []).map(\.id))
        }
        return result
    }

    static func rows(_ groups: [VaultGroup], collapsed: Set<UUID>) -> [VaultGroupTreeRow] {
        let ids = Set(groups.map(\.id))
        let children = Dictionary(grouping: groups) { group in
            group.parentID.flatMap { ids.contains($0) ? $0 : nil }
        }
        var result: [VaultGroupTreeRow] = []
        var visited: Set<UUID> = []
        func append(_ group: VaultGroup, depth: Int) {
            guard visited.insert(group.id).inserted else { return }
            let descendants = children[group.id] ?? []
            let expanded = !collapsed.contains(group.id)
            result.append(VaultGroupTreeRow(group: group, depth: depth,
                                            hasChildren: !descendants.isEmpty, isExpanded: expanded))
            if expanded {
                for child in descendants { append(child, depth: depth + 1) }
            }
        }
        for root in children[nil] ?? [] { append(root, depth: 0) }
        return result
    }

    static func ancestors(of id: UUID, in groups: [VaultGroup]) -> [UUID] {
        let byID = Dictionary(groups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var visited: Set<UUID> = [id]
        var result: [UUID] = []
        var parent = byID[id]?.parentID
        while let current = parent, let group = byID[current], visited.insert(current).inserted {
            result.append(current)
            parent = group.parentID
        }
        return result
    }
}

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
