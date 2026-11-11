import SwiftUI
import VibeWaveCore

/// Разделы открываются в одном окне и используют текущий язык приложения.
@MainActor
struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var preferences: SettingsPreferences
    let shortcuts: GlobalShortcuts
    let updater: Updater?
    @ObservedObject private var languages = LanguageSettings.shared

    @State private var section = 0
    @State private var soundSection = 0
    @State private var librarySection = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RetroSettingsTabs(selection: $section, titles: [
                label("Общие", "General"), label("Звук", "Audio"), label("Медиатека", "Library"),
                label("Метаданные и обложки", "Metadata & Artwork"),
                label("Горячие клавиши", "Shortcuts"), label("Обновления", "Updates")
            ], vertical: true)
            .frame(width: 175)
            Group {
                switch section {
                case 0: GeneralSettingsView(model: model, preferences: preferences)
                case 1: soundSettings
                case 2: librarySettings
                case 3: MetadataSettingsView(preferences: preferences)
                case 4: shortcutSettings
                default: UpdateSettingsView(preferences: preferences, updater: updater)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .retroBevel(.retro, sunken: true)
        }
        .padding(10)
        .frame(width: 760, height: 490)
        .retroPanel()
    }

    private var soundSettings: some View {
        let strings = languages.strings
        return VStack(alignment: .leading, spacing: 8) {
            RetroSettingsTabs(selection: $soundSection, titles: [
                label("Обработка звука", "Audio Processing"), strings.menuPlayback, strings.audioFormatsTitle
            ])
            Group {
                switch soundSection {
                case 0: AudioSettingsView(model: model)
                case 1: PlaybackSettingsView(model: model)
                default: AudioFormatsSettingsView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(8)
    }

    private var librarySettings: some View {
        let strings = languages.strings
        return VStack(alignment: .leading, spacing: 8) {
            RetroSettingsTabs(selection: $librarySection, titles: [
                strings.searchTracks, strings.playlists, strings.listeningHistory
            ])
            Group {
                switch librarySection {
                case 0: SearchSettingsView(model: model)
                case 1: PlaylistFileSettingsView(model: model)
                default: ListeningSettingsView(model: model)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.padding(8)
    }

    private var shortcutSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(label("Системные медиаклавиши и Пункт управления",
                         "System media keys and Control Center"), isOn: $preferences.mediaKeys)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            Divider()
            ShortcutSettingsView(shortcuts: shortcuts) { preferences.mediaKeys = true }
        }
    }

    private func label(_ ru: String, _ en: String) -> String { languages.language == .ru ? ru : en }
}

/// Панель плеера, меню и окно используют одни параметры транспорта.
@MainActor
struct PlaybackSettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        let strings = languages.strings
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.menuPlayback).fontWeight(.bold)
            Toggle(strings.shuffle, isOn: $model.shuffleEnabled)
            RetroChoice(title: strings.repeatLabel, selection: $model.repeatMode,
                        options: RepeatMode.allCases.map { ($0, strings.repeatModeName($0)) })
            Button(strings.resetPlaybackSettings) {
                model.shuffleEnabled = false
                model.repeatMode = .off
            }
            .disabled(!model.shuffleEnabled && model.repeatMode == .off)
        }
        .padding(20)
        .frame(width: 360)
    }
}

/// Значения подставляются в диалог экспорта и при чтении старых списков.
@MainActor
private struct PlaylistFileSettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        let strings = languages.strings
        VStack(alignment: .leading, spacing: 12) {
            RetroChoice(title: strings.playlistExportFormat, selection: $model.playlistFileOptions.format,
                        options: PlaylistFileFormat.allCases.map { ($0, $0.label) })
            RetroChoice(title: strings.playlistExportEncoding, selection: $model.playlistFileOptions.exportEncoding,
                        options: PlaylistFileEncoding.allCases.map { ($0, $0.label) })
            RetroChoice(title: strings.playlistLegacyEncoding, selection: $model.playlistFileOptions.legacyImportEncoding,
                        options: PlaylistFileEncoding.allCases.map { ($0, $0.label) })
            Text(strings.playlistEncodingHelp).font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(strings.playlistRelativePaths, isOn: $model.playlistFileOptions.relativePaths)
            Toggle(strings.playlistReportMissing, isOn: $model.playlistFileOptions.reportMissingFiles)
            Button(strings.playlistReset) { model.playlistFileOptions = PlaylistFileOptions() }
                .disabled(model.playlistFileOptions == PlaylistFileOptions())
        }
        .padding(16)
    }
}

@MainActor
private struct ListeningSettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var languages = LanguageSettings.shared
    @State private var confirmingClear = false

    var body: some View {
        let strings = languages.strings
        VStack(alignment: .leading, spacing: 8) {
            Toggle(strings.listeningEnabled, isOn: $model.listeningOptions.enabled)
            RetroStepper(title: strings.listeningThreshold(model.listeningOptions.thresholdSeconds),
                         value: Binding(get: { Double(model.listeningOptions.thresholdSeconds) },
                                        set: { model.listeningOptions.thresholdSeconds = Int($0) }),
                         range: 1...300)
                .disabled(!model.listeningOptions.enabled)
            Text(strings.listeningThresholdHelp).font(.caption).foregroundColor(.secondary)
            RetroChoice(title: strings.listeningRetention, selection: $model.listeningOptions.retentionDays,
                        options: [7, 30, 90, 365, 0].map {
                            ($0, $0 == 0 ? strings.listeningForever : strings.listeningDays($0))
                        })
            Divider()
            if model.listeningActivity.events.isEmpty {
                Text(strings.listeningEmpty).foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.listeningActivity.events.suffix(50).reversed())) { event in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(event.title).lineLimit(1)
                                    let count = model.listeningActivity.summaries[event.url.standardizedFileURL.path]?.count ?? 0
                                    Text(strings.listenCount(count)).font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(event.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            HStack {
                Button(strings.listeningClear) { confirmingClear = true }
                    .disabled(model.listeningActivity.summaries.isEmpty)
                Button(languages.language == .ru ? "Сбросить настройки истории" : "Reset history settings") {
                    model.listeningOptions = ListeningOptions()
                }.disabled(model.listeningOptions == ListeningOptions())
            }
        }
        .padding(16)
        .alert(strings.listeningClear, isPresented: $confirmingClear) {
            Button(strings.cancel, role: .cancel) {}
            Button(strings.listeningClear, role: .destructive) { model.clearListeningHistory() }
        } message: {
            Text(strings.listeningClearHelp)
        }
    }
}

@MainActor
private struct AudioFormatsSettingsView: View {
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        let strings = languages.strings
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(strings.audioFormatsHelp).foregroundColor(.secondary)
                ForEach(AudioFormat.allCases) { format in
                    Divider()
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(format.name).fontWeight(.semibold)
                            Text(format.fileExtensions.map { "." + $0 }.joined(separator: ", "))
                                .font(.caption).monospaced()
                        }
                        Spacer()
                        Text(format.writesTags ? strings.audioFormatTagsReadWrite :
                            format.readsTags ? strings.audioFormatTagsRead : strings.audioFormatPlaybackOnly)
                            .foregroundColor(.secondary)
                    }
                }
            }.padding(14)
        }
    }
}


/// Переключатели разделов повторяют прямоугольные кнопки основной панели.
@MainActor
private struct RetroSettingsTabs: View {
    @Binding var selection: Int
    let titles: [String]
    var vertical = false

    var body: some View {
        Group {
            if vertical {
                VStack(alignment: .leading, spacing: 5) { buttons }
            } else {
                HStack(spacing: 4) { buttons }
            }
        }
    }

    private var buttons: some View {
        ForEach(titles.indices, id: \.self) { index in
            Button { selection = index } label: {
                Text(titles[index])
                    .lineLimit(vertical ? 2 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: vertical ? 155 : nil, alignment: .leading)
            }
            .buttonStyle(RetroButtonStyle(theme: .retro, isOn: selection == index, toolbar: true))
            .accessibilityAddTraits(selection == index ? .isSelected : [])
        }
    }
}
