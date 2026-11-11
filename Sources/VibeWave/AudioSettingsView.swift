import SwiftUI
import VibeWaveCore

@MainActor
struct AudioSettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var languages = LanguageSettings.shared
    @State private var writeSelection: [Track] = []
    @State private var confirmWrite = false
    @State private var showEqualizer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                gainControls
                Divider()
                transitionControls
                Divider()
                Button(label("Эквалайзер и пресеты…", "Equalizer and presets…")) { showEqualizer = true }
            }.padding(14)
        }
        .sheet(isPresented: $showEqualizer) {
            VStack {
                EqualizerPanel(model: model, theme: .retro)
                Button(label("Закрыть", "Close")) { showEqualizer = false }.keyboardShortcut(.cancelAction)
            }.padding(8).retroPanel()
        }
        .alert(label("Записать ReplayGain в файлы?", "Write ReplayGain to files?"), isPresented: $confirmWrite) {
            Button(languages.strings.cancel, role: .cancel) { writeSelection = [] }
            Button(label("Записать", "Write"), role: .destructive) {
                model.writeAnalyzedGain(writeSelection)
                writeSelection = []
            }
        } message: {
            Text(label("Актуальные результаты анализа заменят поля ReplayGain в MP3 и FLAC.",
                       "Current analysis results will replace ReplayGain fields in MP3 and FLAC files."))
        }
    }

    @ViewBuilder
    private var gainControls: some View {
        Text("ReplayGain").fontWeight(.bold)
        RetroChoice(title: label("Режим", "Mode"), selection: $model.audioOptions.replayGain,
                    options: [
                        (.off, label("Выключен", "Off")), (.track, label("Трек", "Track")),
                        (.album, label("Альбом", "Album"))
                    ])
        Group {
            RetroStepper(title: label("Предусиление", "Preamp") + ": \(Int(model.audioOptions.preamp)) dB",
                    value: $model.audioOptions.preamp, range: -12...12)
            RetroStepper(title: label("Если усиление неизвестно", "Missing gain") + ": \(Int(model.audioOptions.missingGain)) dB",
                    value: $model.audioOptions.missingGain, range: -24...12)
            Toggle(label("Ограничивать усиление по пику", "Limit gain using sample peak"),
                   isOn: $model.audioOptions.preventClipping)
        }.disabled(model.audioOptions.replayGain == .off)
        Text(label("Для альбомного анализа откройте раздел со всеми треками альбома.",
                   "For album analysis, open a view containing all tracks from the album."))
            .font(.caption).foregroundColor(.secondary)
        HStack {
            Button(label("Анализировать текущий раздел", "Analyze current view")) {
                model.analyzeGain(model.gainTracks)
            }
            Button(label("Записать теги MP3/FLAC…", "Write MP3/FLAC tags…")) {
                writeSelection = model.gainTracks
                confirmWrite = true
            }
        }.disabled(model.gainJob != nil || model.writingTags || model.displayedTracks.isEmpty)
        if let progress = model.gainProgress {
            HStack {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                Text("\(progress.done) / \(progress.total)").monospacedDigit()
                Button(languages.strings.cancel) { model.gainJob?.cancel() }
            }
        }
        if let report = model.gainReport { Text(report).font(.caption).textSelection(.enabled) }
    }

    @ViewBuilder
    private var transitionControls: some View {
        Text(label("Переходы между треками", "Track transitions")).fontWeight(.bold)
        Toggle(label("Без пауз", "Gapless playback"), isOn: $model.audioOptions.gapless)
        let seconds = String(format: "%.1f", model.audioOptions.crossfade)
        RetroStepper(title: label("Плавное сведение", "Crossfade") + ": " + seconds + label(" с", " s"),
                value: $model.audioOptions.crossfade, range: 0.0...12.0, step: 0.5)
        Toggle(label("Не сводить треки одного альбома", "Skip crossfade within an album"),
               isOn: $model.audioOptions.preserveAlbums).disabled(model.audioOptions.crossfade == 0)
        Text(label("Переходы работают между треками с одинаковым форматом звукового потока.",
                   "Transitions work between tracks with matching audio stream formats."))
            .font(.caption).foregroundColor(.secondary)
        Button(label("Сбросить настройки звука", "Reset audio settings")) {
            model.audioOptions = AudioPlaybackOptions()
        }.disabled(model.audioOptions == AudioPlaybackOptions())
    }

    private func label(_ russian: String, _ english: String) -> String {
        languages.language == .ru ? russian : english
    }
}
