import Foundation

struct VaultItem: Identifiable, Hashable {
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
        modifiedAt: Date
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
    }
}

struct CustomField: Identifiable, Hashable {
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

struct OneTimePassword: Hashable {
    var code: String
    var period: Int

    var safePeriod: Int {
        max(period, 1)
    }
}

extension VaultItem {
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

enum VaultGroup: String, CaseIterable, Identifiable, Hashable {
    case personal = "Personal"
    case work = "Work"
    case finance = "Finance"
    case travel = "Travel"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .personal: "person.crop.circle"
        case .work: "briefcase"
        case .finance: "creditcard"
        case .travel: "airplane"
        }
    }
}

enum ItemColor: String, Hashable {
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
