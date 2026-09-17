import Foundation

enum ItemSortOrder: String, CaseIterable, Identifiable {
    case recent
    case title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "Recently updated"
        case .title: "Title"
        }
    }

    var iconName: String {
        switch self {
        case .recent: "clock"
        case .title: "textformat"
        }
    }
}
