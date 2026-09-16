import XCTest
@testable import KeeLocker

@MainActor
final class VaultStoreTests: XCTestCase {
    func testSearchIgnoresSurroundingWhitespace() {
        let store = VaultStore(items: MockVault.items)

        store.searchQuery = "  github  "

        XCTAssertEqual(store.visibleItems.map(\.title), ["GitHub"])
    }

    func testLockedVaultRefusesNewItems() {
        let store = VaultStore(items: MockVault.items)
        let initialIDs = store.items.map(\.id)

        store.lock()
        store.addItem()

        XCTAssertEqual(store.items.map(\.id), initialIDs)
    }

    func testReconcileSelectionDropsItemRemovedFromFavorites() {
        let store = VaultStore(items: MockVault.items)
        guard let selectedID = store.items.first(where: \.isFavorite)?.id else {
            return XCTFail("Mock vault must contain a favorite item")
        }
        store.sidebarSelection = .favorites
        store.selectedItemID = selectedID

        guard let index = store.items.firstIndex(where: { $0.id == selectedID }) else {
            return XCTFail("Selected favorite must exist in the store")
        }
        var updatedItem = store.items[index]
        updatedItem.isFavorite = false
        store.updateItem(updatedItem)

        XCTAssertNotEqual(store.selectedItemID, selectedID)
        XCTAssertTrue(store.selectedItemID.map { id in
            store.visibleItems.contains(where: { $0.id == id })
        } ?? store.visibleItems.isEmpty)
    }
}

final class VaultItemValidationTests: XCTestCase {
    func testWebsiteURLAcceptsOnlyHTTPURLsWithHost() {
        var item = MockVault.items[0]

        item.website = "https://example.com/account"
        XCTAssertEqual(item.websiteURL?.absoluteString, "https://example.com/account")

        item.website = "https://"
        XCTAssertNil(item.websiteURL)

        item.website = "file:///tmp/example"
        XCTAssertNil(item.websiteURL)
    }

    func testOneTimePasswordPeriodIsNeverBelowOne() {
        XCTAssertEqual(OneTimePassword(code: "123 456", period: 0).safePeriod, 1)
        XCTAssertEqual(OneTimePassword(code: "123 456", period: 30).safePeriod, 30)
    }
}
