import SwiftUI

@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @AppStorage("selectedTheme") var selectedThemeRaw: String = AppTheme.midnight.rawValue
    @AppStorage("useSystemAppearance") var useSystemAppearance: Bool = true

    var selectedTheme: AppTheme {
        get { AppTheme(rawValue: selectedThemeRaw) ?? .midnight }
        set { selectedThemeRaw = newValue.rawValue }
    }

    var primaryGradient: LinearGradient {
        selectedTheme.primaryGradient
    }

    var backgroundColor: Color {
        selectedTheme.backgroundColor
    }

    var cardColor: Color {
        selectedTheme.cardColor
    }

    var textColor: Color {
        selectedTheme.textColor
    }

    var secondaryTextColor: Color {
        selectedTheme.secondaryTextColor
    }
}

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case midnight = "Midnight"
    case ocean = "Ocean"
    case forest = "Forest"
    case sunset = "Sunset"
    case lavender = "Lavender"
    case minimal = "Minimal"
    case cherry = "Cherry"
    case aurora = "Aurora"

    var id: String { rawValue }

    var isPremium: Bool {
        switch self {
        case .midnight, .minimal: return false
        default: return true
        }
    }

    var previewColors: [Color] {
        switch self {
        case .midnight: return [Color(hex: "1a1a2e"), Color(hex: "16213e"), Color(hex: "6275fc")]
        case .ocean: return [Color(hex: "0a1628"), Color(hex: "1a3a5c"), Color(hex: "4fc3f7")]
        case .forest: return [Color(hex: "0d1f0d"), Color(hex: "1b3a1b"), Color(hex: "4caf50")]
        case .sunset: return [Color(hex: "1a0a0a"), Color(hex: "3d1a1a"), Color(hex: "ff6b35")]
        case .lavender: return [Color(hex: "1a1028"), Color(hex: "2d1f4e"), Color(hex: "b39ddb")]
        case .minimal: return [Color(hex: "f5f5f5"), Color(hex: "ffffff"), Color(hex: "333333")]
        case .cherry: return [Color(hex: "1a0510"), Color(hex: "3d0f24"), Color(hex: "e91e63")]
        case .aurora: return [Color(hex: "0a1a1a"), Color(hex: "1a3a3a"), Color(hex: "00e5ff")]
        }
    }

    var primaryGradient: LinearGradient {
        switch self {
        case .midnight:
            return LinearGradient(colors: [Color(hex: "6275fc"), Color(hex: "8b5cf6")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .ocean:
            return LinearGradient(colors: [Color(hex: "4fc3f7"), Color(hex: "0288d1")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .forest:
            return LinearGradient(colors: [Color(hex: "66bb6a"), Color(hex: "2e7d32")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .sunset:
            return LinearGradient(colors: [Color(hex: "ff6b35"), Color(hex: "d32f2f")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .lavender:
            return LinearGradient(colors: [Color(hex: "b39ddb"), Color(hex: "7e57c2")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .minimal:
            return LinearGradient(colors: [Color(hex: "333333"), Color(hex: "555555")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .cherry:
            return LinearGradient(colors: [Color(hex: "e91e63"), Color(hex: "c2185b")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        case .aurora:
            return LinearGradient(colors: [Color(hex: "00e5ff"), Color(hex: "00b8d4")],
                                  startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var backgroundColor: Color {
        previewColors[0]
    }

    var cardColor: Color {
        previewColors[1]
    }

    var accentColor: Color {
        previewColors[2]
    }

    var textColor: Color {
        self == .minimal ? Color(hex: "1a1a1a") : .white
    }

    var secondaryTextColor: Color {
        self == .minimal ? Color(hex: "666666") : Color.white.opacity(0.6)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
