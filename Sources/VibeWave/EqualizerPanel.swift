import SwiftUI
import VibeWaveCore

/// Окно эквалайзера в стиле Windows 95: включение, пресеты, сброс,
/// предусиление и 10 полос от 32 Гц до 16 кГц (±12 дБ).
/// Изменения применяются сразу и сохраняются моделью.
@MainActor
struct EqualizerPanel: View {
    @ObservedObject var model: PlayerModel
    let theme: PlayerTheme
    @ObservedObject private var languages = LanguageSettings.shared
    private var s: Strings { languages.strings }
    private let range = Double(EqualizerSettings.gainRange.lowerBound)...Double(EqualizerSettings.gainRange.upperBound)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(s.eqTitle).fontWeight(.bold)
                Spacer(minLength: 12)
                Button { model.equalizer.enabled.toggle() } label: { Text(s.eqOn) }
                    .buttonStyle(RetroButtonStyle(theme: theme, isOn: model.equalizer.enabled, toolbar: true))
                    .help(s.eqOnHelp)
                    .accessibilityValue(model.equalizer.enabled ? s.eqOn : "")
                presetMenu
                Button { model.equalizer = EqualizerSettings(enabled: model.equalizer.enabled) } label: { Text(s.eqReset) }
                    .help(s.eqResetHelp)
            }
            HStack(alignment: .top, spacing: 4) {
                scale
                band(title: s.eqPreamp, accessibility: s.eqPreamp, value: gainBinding { $0.preamp } set: { $0.preamp = $1 })
                Rectangle().fill(theme.shadow).frame(width: 1, height: 150).padding(.horizontal, 3)
                ForEach(EqualizerSettings.bandLabels.indices, id: \.self) { index in
                    let label = EqualizerSettings.bandLabels[index]
                    band(title: label, accessibility: s.eqBand(label),
                         value: gainBinding { $0.gains[index] } set: { $0.gains[index] = $1 })
                }
            }
            .padding(8)
            .background(theme.panel).retroBevel(theme, sunken: true)
        }
        .font(.custom("Arial", size: 12))
        .foregroundColor(theme.foreground)
        .buttonStyle(RetroButtonStyle(theme: theme, toolbar: true))
        .padding(10)
        .background(theme.panel)
        .preferredColorScheme(.light)
    }

    private var presetMenu: some View {
        let current = model.equalizer.preset
        return RetroMenuButton(title: s.eqPresets) {
            var items = EqualizerPreset.allCases.map { preset in
                RetroMenuButton.Item.action(s.eqPresetName(preset), checked: current == preset) {
                    model.equalizer = EqualizerSettings(preset: preset)
                }
            }
            if current == nil { items += [.separator, .action(s.eqCustom, checked: true) {}] }
            return items
        }
        .help(current.map(s.eqPresetName) ?? s.eqCustom)
    }

    /// Шкала слева от ползунков.
    private var scale: some View {
        VStack(alignment: .trailing) {
            Text("+12")
            Spacer()
            Text("0")
            Spacer()
            Text("−12")
        }
        .font(.custom("Arial", size: 9))
        .foregroundColor(theme.secondary)
        .frame(width: 22, height: 120)
        .padding(.top, 15)
    }

    private func band(title: String, accessibility: String, value: Binding<Double>) -> some View {
        VStack(spacing: 3) {
            Text(s.eqDecibels(Float(value.wrappedValue)))
                .font(.custom("Arial", size: 9)).lineLimit(1).fixedSize()
                .frame(width: 34, height: 12)
            RetroVerticalSlider(value: value, range: range, theme: theme, valueText: { s.eqDecibels(Float($0)) })
                .frame(width: 24, height: 120)
                .help("\(accessibility): \(s.eqDecibels(Float(value.wrappedValue)))")
                .accessibilityLabel(accessibility)
            Text(title).font(.custom("Arial", size: 10).weight(.bold)).lineLimit(1).fixedSize()
        }
        .frame(width: 34)
    }

    /// Изменение полосы или предусиления сразу включает эквалайзер: результат слышен без лишнего щелчка.
    private func gainBinding(get: @escaping (EqualizerSettings) -> Float,
                             set: @escaping (inout EqualizerSettings, Float) -> Void) -> Binding<Double> {
        Binding(
            get: { Double(get(model.equalizer)) },
            set: { newValue in
                var settings = model.equalizer
                set(&settings, Float(newValue.rounded()))
                settings.enabled = true
                if settings != model.equalizer { model.equalizer = settings }
            }
        )
    }
}
