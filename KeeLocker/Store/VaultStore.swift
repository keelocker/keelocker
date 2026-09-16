import Foundation

@MainActor
final class VaultStore: ObservableObject {
    @Published var items: [VaultItem]
    @Published var selectedItemID: VaultItem.ID?
    @Published var sidebarSelection: SidebarSelection = .allItems
    @Published var searchQuery = ""
    @Published var isLocked = false

    init(items: [VaultItem] = MockVault.items) {
        self.items = items
        self.selectedItemID = items.first?.id
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
            [item.title, item.username, item.website, item.group.rawValue]
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
        sidebarSelection = destination
        searchQuery = ""
        reconcileSelection()
    }

    func reconcileSelection() {
        guard !visibleItems.contains(where: { $0.id == selectedItemID }) else { return }
        selectedItemID = visibleItems.first?.id
    }

    func updateItem(_ item: VaultItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        reconcileSelection()
    }

    func addItem() {
        guard !isLocked else { return }

        let item = VaultItem(
            title: "New login",
            username: "",
            password: "",
            website: "https://",
            notes: "",
            tags: [],
            group: .personal,
            iconName: "key.fill",
            iconColor: .indigo,
            modifiedAt: .now
        )
        items.insert(item, at: 0)
        sidebarSelection = .allItems
        searchQuery = ""
        selectedItemID = item.id
    }

    func lock() {
        searchQuery = ""
        isLocked = true
    }

    func unlock() {
        isLocked = false
        reconcileSelection()
    }
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
