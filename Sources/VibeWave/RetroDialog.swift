import SwiftUI

/// Общие панели диалогов используют те же цвета, шрифт и грани, что основной плеер.
private struct RetroPanelStyle: ViewModifier {
    private let theme = PlayerTheme.retro

    func body(content: Content) -> some View {
        content
            .font(.custom("Arial", size: 12))
            .foregroundColor(theme.foreground)
            .tint(theme.accent)
            .buttonStyle(RetroButtonStyle(theme: theme, toolbar: true))
            .toggleStyle(RetroCheckboxStyle())
            .textFieldStyle(RetroTextFieldStyle())
            .background(theme.panel)
            .preferredColorScheme(.light)
    }
}

extension View {
    func retroPanel() -> some View { modifier(RetroPanelStyle()) }
}

struct RetroDialog<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    private let theme = PlayerTheme.retro

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.custom("Arial", size: 12).bold())
                .foregroundColor(theme.selectionText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(theme.titleBar)
                .padding(3)
            content().padding(12)
        }
        .retroPanel()
        .retroBevel(theme)
    }
}

/// Меню раскрывается штатным механизмом macOS, кнопка повторяет оформление плеера.
@MainActor
struct RetroChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var showsTitle = true

    var body: some View {
        HStack(spacing: 8) {
            if showsTitle { Text(title) }
            RetroMenuButton(title: options.first { $0.0 == selection }?.1 ?? title, items: {
                options.map { value, name in
                    .action(name, checked: value == selection) { selection = value }
                }
            }, showsDisclosure: true)
            .buttonStyle(RetroButtonStyle(theme: .retro, toolbar: true, expands: true))
            .accessibilityLabel(title)
            .accessibilityValue(options.first { $0.0 == selection }?.1 ?? "")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RetroTextFieldStyle: TextFieldStyle {
    private let theme = PlayerTheme.retro
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(theme.background)
            .retroBevel(theme, sunken: true)
    }
}

private struct RetroCheckboxStyle: ToggleStyle {
    private let theme = PlayerTheme.retro
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                ZStack {
                    Rectangle().fill(enabled ? theme.background : theme.panel)
                        .retroBevel(theme, sunken: true)
                    if configuration.isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .black))
                    }
                }.frame(width: 15, height: 15)
                configuration.label
            }
            .foregroundColor(enabled ? theme.foreground : theme.secondary.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

/// Две обычные ретро-кнопки меняют значение с заданным шагом и сохраняют границы.
struct RetroStepper: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            Spacer(minLength: 8)
            Button { value = max(range.lowerBound, value - step) } label: { Text("−") }
                .disabled(value <= range.lowerBound)
                .accessibilityLabel(title + " −")
            Button { value = min(range.upperBound, value + step) } label: { Text("+") }
                .disabled(value >= range.upperBound)
                .accessibilityLabel(title + " +")
        }
    }
}
