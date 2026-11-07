import SwiftUI

/// Общие цвета трёх тем. Геометрия элементов остаётся в стиле Windows 95.
/// Существующие значения light/dark сохраняют совместимость с настройками.
enum PlayerTheme: String, CaseIterable, Identifiable {
    case light, dark, retro
    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        case .retro: return "Windows 95"
        }
    }
    var scheme: ColorScheme { self == .dark ? .dark : .light }
    var background: Color {
        switch self {
        case .light, .retro: return .white
        case .dark: return Color(red: 0.065, green: 0.055, blue: 0.09)
        }
    }
    var panel: Color {
        switch self {
        case .light: return Color(white: 0.9)
        case .dark: return Color(red: 0.17, green: 0.14, blue: 0.22)
        case .retro: return Color(red: 0.753, green: 0.753, blue: 0.753)
        }
    }
    var foreground: Color { self == .dark ? Color(white: 0.95) : .black }
    var secondary: Color { self == .dark ? Color(white: 0.72) : Color(white: 0.3) }
    var accent: Color {
        switch self {
        case .light: return .black
        case .dark: return Color(red: 0.72, green: 0.51, blue: 1)
        case .retro: return Color(red: 0, green: 0, blue: 0.5)
        }
    }
    var titleBar: Color { self == .dark ? Color(red: 0.28, green: 0.12, blue: 0.46) : accent }
    var selection: Color { self == .dark ? Color(red: 0.34, green: 0.19, blue: 0.49) : accent }
    var selectionText: Color { .white }
    var highlight: Color { self == .dark ? Color(white: 0.42) : .white }
    var shadow: Color { self == .dark ? Color(white: 0.07) : Color(white: 0.5) }
    var edge: Color { self == .dark ? .black : Color(white: 0.2) }
}
