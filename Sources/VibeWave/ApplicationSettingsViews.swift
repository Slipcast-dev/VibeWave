import SwiftUI
import VibeWaveCore

@MainActor
struct GeneralSettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var preferences: SettingsPreferences
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RetroChoice(title: label("Язык интерфейса", "Interface language"), selection: $languages.preference,
                        options: [
                            (.system, label("Как в системе", "System")),
                            (.ru, AppLanguage.ru.nativeName), (.en, AppLanguage.en.nativeName)
                        ])
            Toggle(label("Восстанавливать очередь и позицию при запуске",
                         "Restore queue and position at launch"), isOn: $model.restorePlaybackOnLaunch)
            Text(label("Трек откроется на паузе.", "The track opens paused."))
                .font(.caption).foregroundColor(.secondary)
            Toggle(label("Завершать приложение при закрытии окна плеера",
                         "Quit when the player window closes"), isOn: $preferences.quitOnClose)
            Button(label("Сбросить общие настройки", "Reset general settings")) {
                languages.preference = .system
                model.restorePlaybackOnLaunch = false
                preferences.quitOnClose = false
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ ru: String, _ en: String) -> String { languages.language == .ru ? ru : en }
}

@MainActor
struct MetadataSettingsView: View {
    @ObservedObject var preferences: SettingsPreferences
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(label("Загружать встроенную обложку в редакторе",
                         "Load embedded artwork in the tag editor"), isOn: $preferences.showArtwork)
            Toggle(label("Подтверждать запись тегов и обложек",
                         "Confirm writing tags and artwork"), isOn: $preferences.confirmTagEdits)
            Button(label("Сбросить настройки метаданных", "Reset metadata settings")) {
                preferences.showArtwork = true
                preferences.confirmTagEdits = false
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ ru: String, _ en: String) -> String { languages.language == .ru ? ru : en }
}

@MainActor
struct UpdateSettingsView: View {
    @ObservedObject var preferences: SettingsPreferences
    let updater: Updater?
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(label("Проверять обновления при запуске", "Check for updates at launch"),
                   isOn: $preferences.automaticUpdates)
            if let updater = updater {
                UpdateCheckControls(updater: updater)
            } else {
                Text(label("В этой сборке проверка обновлений недоступна.",
                           "Update checks are unavailable in this build."))
                    .foregroundColor(.secondary)
            }
            Button(label("Сбросить настройки обновлений", "Reset update settings")) {
                preferences.automaticUpdates = true
            }.disabled(preferences.automaticUpdates)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(_ ru: String, _ en: String) -> String { languages.language == .ru ? ru : en }
}

@MainActor
private struct UpdateCheckControls: View {
    @ObservedObject var updater: Updater
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        Text(label("Установленная версия", "Installed version") + " " + updater.currentVersion)
        HStack {
            Button(label("Проверить сейчас", "Check Now")) { updater.checkNow() }.disabled(updater.busy)
            if updater.status == .checking || updater.status == .downloading { ProgressView().controlSize(.small) }
        }
        if !statusText.isEmpty { Text(statusText).foregroundColor(.secondary) }
    }

    private var statusText: String {
        switch updater.status {
        case .idle: return ""
        case .checking: return label("Проверка обновлений…", "Checking for updates…")
        case .noCompatibleUpdate: return label("Совместимых обновлений нет.", "No compatible update is available.")
        case .deferred: return label("Установка отложена.", "Installation deferred.")
        case .downloading: return label("Загрузка и проверка обновления…", "Downloading and verifying the update…")
        case .waitingForStop: return label("Обновление установится после остановки или выхода.",
                                            "The update will install after stopping playback or quitting.")
        case .failed: return label("Не удалось проверить или установить обновление.",
                                    "Could not check for or install the update.")
        }
    }

    private func label(_ ru: String, _ en: String) -> String { languages.language == .ru ? ru : en }
}
