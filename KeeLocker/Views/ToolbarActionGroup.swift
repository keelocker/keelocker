import SwiftUI

struct ToolbarActionGroup: ToolbarContent {
    @Binding var sortOrder: ItemSortOrder
    let addAction: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(id: "list.sort", placement: .automatic) {
            sortMenu
        }
        ToolbarItem(id: "list.add", placement: .automatic) {
            addButton
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortOrder) {
                ForEach(ItemSortOrder.allCases) { order in
                    Label(order.title, systemImage: order.iconName)
                        .tag(order)
                }
            }
        } label: {
            Label("Sort logins", systemImage: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .help("Sort logins")
        .accessibilityLabel("Sort logins")
        .accessibilityIdentifier("toolbar.sort")
    }

    private var addButton: some View {
        Button(action: addAction) {
            Label("New login", systemImage: "plus")
        }
        .help("New login (⌘N)")
        .accessibilityIdentifier("toolbar.add")
    }
}
