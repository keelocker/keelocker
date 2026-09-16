import SwiftUI

enum KeeTheme {
    static let accent = Color(red: 0.294, green: 0.388, blue: 0.824)
    static let positive = Color(red: 0.184, green: 0.616, blue: 0.408)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let listSurface = Color(nsColor: .controlBackgroundColor)
    static let raisedSurface = Color(nsColor: .textBackgroundColor)
    static let separator = Color(nsColor: .separatorColor)

    enum Radius {
        static let compact: CGFloat = 7
        static let row: CGFloat = 10
        static let panel: CGFloat = 14
        static let large: CGFloat = 18
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let regular: CGFloat = 16
        static let large: CGFloat = 24
        static let xLarge: CGFloat = 32
        static let huge: CGFloat = 40
    }
}
extension ItemColor {
    var color: Color {
        switch self {
        case .indigo: Color(red: 0.32, green: 0.39, blue: 0.82)
        case .blue: Color(red: 0.20, green: 0.48, blue: 0.84)
        case .cyan: Color(red: 0.15, green: 0.58, blue: 0.72)
        case .mint: Color(red: 0.20, green: 0.63, blue: 0.55)
        case .green: Color(red: 0.18, green: 0.58, blue: 0.34)
        case .orange: Color(red: 0.86, green: 0.46, blue: 0.18)
        case .pink: Color(red: 0.82, green: 0.32, blue: 0.50)
        case .purple: Color(red: 0.54, green: 0.34, blue: 0.76)
        case .graphite: Color(red: 0.28, green: 0.30, blue: 0.34)
        }
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

extension AppearanceChoice {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
