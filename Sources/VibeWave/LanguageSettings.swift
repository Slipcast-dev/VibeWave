import AppKit
import Combine
import VibeWaveCore

/// Текущий язык интерфейса. По умолчанию следует языку системы; выбор пользователя
/// («Русский», «English» или «Как в системе») сохраняется в настройках.
/// Интерфейс, меню и сообщения модели берут строки отсюда.
@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    static let defaultsKey = "app.language"

    @Published var preference: LanguagePreference {
        didSet { defaults.set(preference.rawValue, forKey: Self.defaultsKey) }
    }
    /// Меняется при смене языка системы, чтобы режим «Как в системе» сразу перестроил интерфейс.
    @Published private var systemLanguages: [String]

    var language: AppLanguage { preference.resolve(systemLanguages: systemLanguages) }
    var systemLanguage: AppLanguage { LanguagePreference.system.resolve(systemLanguages: systemLanguages) }
    var strings: Strings { .for(language) }

    private let defaults: UserDefaults
    private var observer: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = defaults.string(forKey: Self.defaultsKey).flatMap(LanguagePreference.init(rawValue:)) ?? .system
        systemLanguages = Locale.preferredLanguages
        observer = NotificationCenter.default.addObserver(forName: NSLocale.currentLocaleDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            let languages = Locale.preferredLanguages
            DispatchQueue.main.async { [weak self] in self?.systemLanguages = languages }
        }
    }
}
