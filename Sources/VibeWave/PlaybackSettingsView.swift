import SwiftUI
import VibeWaveCore

/// Разделы открываются в одном окне и используют текущий язык приложения.
@MainActor
struct SettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        let strings = languages.strings
        TabView {
            PlaybackSettingsView(model: model).tabItem { Text(strings.menuPlayback) }
            PlaylistFileSettingsView(model: model).tabItem { Text(strings.playlists) }
            ListeningSettingsView(model: model).tabItem { Text(strings.listeningHistory) }
            SearchSettingsView(model: model).tabItem { Text(strings.searchTracks) }
        }
        .padding(12)
        .frame(width: 470, height: 340)
    }
}

/// Первый раздел настроек. Панель плеера, меню и окно используют одни параметры модели.
@MainActor
struct PlaybackSettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        let strings = languages.strings
        VStack(alignment: .leading, spacing: 12) {
            Text(strings.menuPlayback).font(.headline)
            Toggle(strings.shuffle, isOn: $model.shuffleEnabled)
            Picker(strings.repeatLabel, selection: $model.repeatMode) {
                ForEach(RepeatMode.allCases, id: \.self) { mode in
                    Text(strings.repeatModeName(mode)).tag(mode)
                }
            }
            .pickerStyle(.menu)
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
            Picker(strings.playlistExportFormat, selection: $model.playlistFileOptions.format) {
                ForEach(PlaylistFileFormat.allCases, id: \.self) { format in
                    Text(format.label).tag(format)
                }
            }
            Picker(strings.playlistExportEncoding, selection: $model.playlistFileOptions.exportEncoding) {
                ForEach(PlaylistFileEncoding.allCases, id: \.self) { encoding in
                    Text(encoding.label).tag(encoding)
                }
            }
            Picker(strings.playlistLegacyEncoding, selection: $model.playlistFileOptions.legacyImportEncoding) {
                ForEach(PlaylistFileEncoding.allCases, id: \.self) { encoding in
                    Text(encoding.label).tag(encoding)
                }
            }
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
            Stepper(strings.listeningThreshold(model.listeningOptions.thresholdSeconds),
                    value: $model.listeningOptions.thresholdSeconds, in: 1...300)
                .disabled(!model.listeningOptions.enabled)
            Text(strings.listeningThresholdHelp).font(.caption).foregroundColor(.secondary)
            Picker(strings.listeningRetention, selection: $model.listeningOptions.retentionDays) {
                ForEach([7, 30, 90, 365, 0], id: \.self) { days in
                    Text(days == 0 ? strings.listeningForever : strings.listeningDays(days)).tag(days)
                }
            }
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
            Button(strings.listeningClear) { confirmingClear = true }
                .disabled(model.listeningActivity.summaries.isEmpty)
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
