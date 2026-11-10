import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeWaveCore

/// Окно эквалайзера в стиле Windows 95: включение, пресеты, сброс,
/// предусиление и 10 полос от 32 Гц до 16 кГц (±12 дБ).
/// Изменения применяются сразу и сохраняются моделью.
@MainActor
struct EqualizerPanel: View {
    @ObservedObject var model: PlayerModel
    let theme: PlayerTheme
    @ObservedObject private var presets: EqualizerPresetLibrary
    @State private var managesPresets = false
    @ObservedObject private var languages = LanguageSettings.shared
    private var s: Strings { languages.strings }
    private let range = Double(EqualizerSettings.gainRange.lowerBound)...Double(EqualizerSettings.gainRange.upperBound)

    init(model: PlayerModel, theme: PlayerTheme) {
        self.model = model
        self.theme = theme
        _presets = ObservedObject(wrappedValue: model.userEqualizerPresets)
    }

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

            if managesPresets {
                UserEqualizerPresetsPanel(model: model, library: presets)
            }
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
        let userPreset = current == nil ? presets.presets.first {
            $0.preamp == model.equalizer.preamp && $0.gains == model.equalizer.gains
        } : nil
        let labels = UserEqualizerPresetLabels(language: languages.language)
        return RetroMenuButton(title: s.eqPresets) {
            var items = EqualizerPreset.allCases.map { preset in
                RetroMenuButton.Item.action(s.eqPresetName(preset), checked: current == preset) {
                    model.equalizer = EqualizerSettings(preset: preset)
                }
            }
            if !presets.presets.isEmpty {
                items.append(.separator)
                items += presets.presets.map { preset in
                    .action(preset.name, checked: userPreset?.id == preset.id) { model.equalizer = preset.settings }
                }
            }
            if current == nil && userPreset == nil { items += [.separator, .action(s.eqCustom, checked: true) {}] }
            items += [.separator, .action(labels.manage, checked: managesPresets) { managesPresets.toggle() }]
            return items
        }
        .help(userPreset?.name ?? current.map(s.eqPresetName) ?? s.eqCustom)
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

/// Управление остаётся в панели EQ. Отдельный режим выбора позволяет
/// переименовать, экспортировать или удалить пресет, не меняя звук.
@MainActor
private struct UserEqualizerPresetsPanel: View {
    let model: PlayerModel
    @ObservedObject var library: EqualizerPresetLibrary
    @ObservedObject private var languages = LanguageSettings.shared
    @State private var selectedID: UUID?
    @State private var editing: NameEdit?
    @State private var name = ""
    @State private var removing: UserEqualizerPreset?
    @State private var busy = false
    @State private var failure: UserEqualizerPresetError?

    private enum NameEdit { case create, rename(UUID) }

    private var labels: UserEqualizerPresetLabels { .init(language: languages.language) }
    private var selected: UserEqualizerPreset? {
        library.presets.first { $0.id == selectedID } ?? library.presets.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let selected = selected {
                Picker(labels.collection, selection: Binding(get: { self.selected?.id }, set: { selectedID = $0 })) {
                    ForEach(library.presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .disabled(editing != nil || removing != nil || busy)
                HStack {
                    Button(labels.apply) { model.equalizer = selected.settings }
                    Button(labels.rename) {
                        editing = .rename(selected.id)
                        name = selected.name
                        failure = nil
                    }
                    Button(labels.exportFile) { exportPreset(selected) }
                    Button(labels.remove) { removing = selected }
                }
                .disabled(editing != nil || removing != nil || busy)
            }
            HStack {
                Button(labels.saveCurrent) {
                    name = ""
                    editing = .create
                    failure = nil
                }
                Button(labels.importFile) { importPreset() }
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(editing != nil || removing != nil || busy || library.loadFailed)

            if let editing = editing {
                HStack {
                    TextField(labels.name, text: $name).onSubmit { saveName(editing) }
                    Button(labels.save) { saveName(editing) }
                    Button(labels.cancel) {
                        self.editing = nil
                        failure = nil
                    }
                }
            }

            if let removing = removing {
                Text(labels.confirmRemoval(removing.name))
                HStack {
                    Button(labels.remove) {
                        do {
                            try library.remove(removing.id)
                            self.removing = nil
                        } catch { report(error) }
                    }
                    Button(labels.cancel) { self.removing = nil }
                }
            }

            if let error = failure ?? (library.loadFailed ? .invalidLibrary : nil) {
                Text(labels.message(error)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func saveName(_ edit: NameEdit) {
        do {
            switch edit {
            case .create:
                selectedID = try library.add(name: name, settings: model.equalizer).id
            case .rename(let id):
                try library.rename(id, to: name)
            }
            editing = nil
            failure = nil
        } catch { report(error) }
    }

    private func importPreset() {
        let picker = NSOpenPanel()
        picker.title = labels.importFile
        picker.allowedContentTypes = [.json]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let url = picker.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let preset = try await Task.detached(priority: .utility) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let resolvedURL = url.resolvingSymlinksInPath()
                    guard try resolvedURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw UserEqualizerPresetError.invalidFile
                    }
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let data = try file.read(upToCount: EqualizerPresetFile.maximumSize + 1) ?? Data()
                    return try EqualizerPresetFile.decode(data)
                }.value
                selectedID = try library.addImported(preset).id
                failure = nil
            } catch { report(error, fromFile: true) }
        }
    }

    private func exportPreset(_ preset: UserEqualizerPreset) {
        let picker = NSSavePanel()
        picker.title = labels.exportFile
        picker.allowedContentTypes = [.json]
        picker.nameFieldStringValue = "VibeWave-EQ.json"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached(priority: .utility) {
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    try EqualizerPresetFile.encode(preset).write(to: url, options: .atomic)
                }.value
                failure = nil
            } catch { report(error, fromFile: true) }
        }
    }

    private func report(_ error: Error, fromFile: Bool = false) {
        if fromFile {
            // Системный диалог может закрыть всплывающую панель EQ.
            // Сообщение о файле показываем в основном окне.
            model.error = (error as? UserEqualizerPresetError).map(labels.message) ?? error.localizedDescription
        } else if let presetError = error as? UserEqualizerPresetError {
            failure = presetError
        } else {
            model.error = error.localizedDescription
        }
    }
}

private struct UserEqualizerPresetLabels {
    let language: AppLanguage

    private func text(_ russian: String, _ english: String) -> String { language == .ru ? russian : english }

    var manage: String { text("Управление пресетами", "Manage Presets") }
    var collection: String { text("Мои пресеты", "My Presets") }
    var apply: String { text("Применить", "Apply") }
    var rename: String { text("Переименовать…", "Rename…") }
    var exportFile: String { text("Экспорт…", "Export…") }
    var importFile: String { text("Импорт…", "Import…") }
    var remove: String { text("Удалить", "Delete") }
    var saveCurrent: String { text("Сохранить текущие настройки…", "Save Current Settings…") }
    var name: String { text("Название пресета", "Preset Name") }
    var save: String { text("Сохранить", "Save") }
    var cancel: String { text("Отмена", "Cancel") }

    func confirmRemoval(_ name: String) -> String {
        text("Удалить пресет «\(name)»?", "Delete the preset “\(name)”?")
    }

    func message(_ error: UserEqualizerPresetError) -> String {
        switch error {
        case .invalidName: return text("Введите название длиной от 1 до 64 знаков.", "Enter a preset name with 1 to 64 characters.")
        case .duplicateName: return text("Пресет с таким названием уже есть.", "A preset with this name already exists.")
        case .invalidValues: return text("В пресете неверные значения полос или предусиления.", "The preset has invalid band gains or preamp.")
        case .invalidFile: return text("Не удалось прочитать файл пресета VibeWave.", "Couldn’t read the VibeWave preset file.")
        case .unsupportedVersion: return text("Эта версия файла пресета не поддерживается.", "This preset file version is unsupported.")
        case .fileTooLarge: return text("Файл пресета слишком большой.", "The preset file is too large.")
        case .libraryFull: return text("Достигнут предел в 128 пользовательских пресетов.", "The library already has 128 user presets.")
        case .invalidLibrary: return text("Не удалось открыть сохранённые пресеты. Их данные сохранены.", "Couldn’t open the saved presets. Their data is still stored.")
        }
    }
}
