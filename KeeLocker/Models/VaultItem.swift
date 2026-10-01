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
    var modifiedAt: Date
    var createdAt: Date?
    var attachments: [AttachmentMetadata] = []
    var historyCount: Int = 0
    // List snapshots omit secrets and must never replace a complete entry.
    var isRedacted = false

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

enum SidebarSelection: Hashable {
    case allItems
    case favorites
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
