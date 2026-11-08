import SwiftUI

/// Единственное оформление приложения — Windows 95: серые панели с объёмными
/// рамками, белые списки, тёмно-синие заголовок и выделение.
enum PlayerTheme {
    case retro
    var background: Color { .white }
    var panel: Color { Color(red: 0.753, green: 0.753, blue: 0.753) }
    var foreground: Color { .black }
    var listText: Color { .black }
    var secondary: Color { Color(white: 0.3) }
    var accent: Color { Color(red: 0, green: 0, blue: 0.5) }
    var titleBar: Color { accent }
    var selection: Color { accent }
    var selectionText: Color { .white }
    var highlight: Color { .white }
    var shadow: Color { Color(white: 0.5) }
    var edge: Color { Color(white: 0.2) }
}
