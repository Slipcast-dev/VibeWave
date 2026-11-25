import AppKit
import Combine
import VibeWaveCore

/// Ручная и автоматическая проверки используют одну загрузку и общую
/// цепочку проверки подписи. Установка ждёт штатной остановки плеера.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle, checking, noCompatibleUpdate, deferred, downloading, waitingForStop, failed
    }

    @Published private(set) var status: Status = .idle
    var busy: Bool { status == .checking || status == .downloading || prepared != nil }
    var currentVersion: String { configuration.currentVersion }

    struct Configuration {
        var feedURL: URL
        /// Открытые ключи подписи: основной `VWUpdatePublicKey` и дополнительные `VWUpdatePublicKeys`
        /// (для перехода на новый ключ).
        var publicKeys: [String]
        var bundleURL: URL
        var bundleIdentifier: String
        var currentVersion: String

        /// Настройки из Info.plist запущенного приложения. nil — обновление невозможно:
        /// запуск не из .app, нет ключа, приложение открыто из образа диска или из карантинной копии
        /// (App Translocation) либо лежит на томе только для чтения.
        static func fromMainBundle() -> Configuration? {
            let bundle = Bundle.main
            guard bundle.bundleURL.pathExtension == "app",
                  let feed = (bundle.object(forInfoDictionaryKey: "VWUpdateFeedURL") as? String).flatMap(URL.init(string:)),
                  let key = bundle.object(forInfoDictionaryKey: "VWUpdatePublicKey") as? String, !key.isEmpty,
                  let identifier = bundle.bundleIdentifier,
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  !bundle.bundleURL.path.contains("/AppTranslocation/"),
                  (try? bundle.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) != true
            else { return nil }
            let extra = (bundle.object(forInfoDictionaryKey: "VWUpdatePublicKeys") as? [String] ?? []).filter { !$0.isEmpty }
            return Configuration(feedURL: feed, publicKeys: [key] + extra.filter { $0 != key }, bundleURL: bundle.bundleURL,
                                 bundleIdentifier: identifier, currentVersion: version)
        }
    }

    private let model: PlayerModel
    private let configuration: Configuration
    private let session: URLSession
    private let workDirectory: URL
    /// Проверенное новое приложение, ожидающее установки, и SHA-256 его исполняемого файла.
    private var prepared: (app: URL, digest: String)?
    private var installing = false
    private var idleObserver: AnyCancellable?

    init(model: PlayerModel, configuration: Configuration, session: URLSession? = nil) {
        self.model = model
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 20
        settings.timeoutIntervalForResource = 15 * 60
        settings.requestCachePolicy = .reloadIgnoringLocalCacheData
        settings.httpAdditionalHeaders = ["User-Agent": "VibeWave/\(configuration.currentVersion)"]
        self.session = session ?? URLSession(configuration: settings)
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("VibeWave-Update", isDirectory: true)
    }

    private var strings: Strings { LanguageSettings.shared.strings }

    /// Повторно проверяем настройку после задержки: её могли выключить сразу после запуска.
    func checkOnLaunch(isEnabled: @escaping @MainActor () -> Bool) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self = self, self.status == .idle, isEnabled() else { return }
            await self.check()
        }
    }

    func checkNow() {
        Task { [weak self] in await self?.check() }
    }

    private func check() async {
        guard !busy else { return }
        status = .checking
        do {
            let manifest = try await fetchManifest()
            guard AppVersion(manifest.version) != nil, AppVersion(manifest.minimumSystemVersion) != nil,
                  manifest.url.scheme == "https" else { throw UpdateInstaller.Failure.download }
            guard manifest.isOffered(currentVersion: configuration.currentVersion,
                                     systemVersion: ProcessInfo.processInfo.operatingSystemVersion) else {
                status = .noCompatibleUpdate
                return
            }
            // Заметки и предложение установки показываются только после проверки подписи описания.
            try UpdateSignature.verifyManifest(manifest, publicKeys: configuration.publicKeys)
            guard ask(manifest) else { status = .deferred; return }
            status = .downloading
            do {
                prepared = try await download(manifest)
                status = .waitingForStop
                installWhenIdle()
            } catch let failure as UpdateSignature.Failure {
                model.error = strings.updateVerificationFailed(manifest.version) + " (\(failure))"
                status = .failed
            } catch let failure as UpdateInstaller.Failure where failure != .download {
                model.error = strings.updateVerificationFailed(manifest.version) + " (\(failure.localizedDescription))"
                status = .failed
            }
        } catch {
            status = .failed
        }
    }

    private func fetchManifest() async throws -> UpdateManifest {
        let (data, response) = try await session.data(from: configuration.feedURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateInstaller.Failure.download }
        return try JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    private func ask(_ manifest: UpdateManifest) -> Bool {
        let alert = NSAlert()
        alert.messageText = strings.updateTitle
        var text = strings.updateMessage(manifest.version, configuration.currentVersion)
        if let notes = manifest.notes(for: LanguageSettings.shared.language), !notes.isEmpty { text += "\n\n" + notes }
        alert.informativeText = text
        alert.addButton(withTitle: strings.updateNow)
        alert.addButton(withTitle: strings.updateLater)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func download(_ manifest: UpdateManifest) async throws -> (app: URL, digest: String) {
        let (temporary, response) = try await session.download(from: manifest.url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateInstaller.Failure.download }
        let work = workDirectory
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let archive = work.appendingPathComponent("VibeWave-\(manifest.version).zip")
        try FileManager.default.moveItem(at: temporary, to: archive)
        let keys = configuration.publicKeys
        let identifier = configuration.bundleIdentifier
        // Проверка подписи кода и распаковка — в фоне, чтобы не задерживать музыку и интерфейс.
        return try await Task.detached(priority: .utility) {
            let app = try UpdateInstaller.prepare(archive: archive, manifest: manifest, publicKeys: keys,
                                                  bundleIdentifier: identifier, workDirectory: work)
            return (app, try UpdateInstaller.executableDigest(app))
        }.value
    }

    /// Обновление ставится, когда ничего не играет: музыка не обрывается на середине трека.
    private func installWhenIdle() {
        guard prepared != nil else { return }
        if model.current == nil {
            install(relaunch: true)
            return
        }
        idleObserver = model.$current
            .receive(on: DispatchQueue.main)
            .sink { [weak self] current in
                guard current == nil else { return }
                self?.install(relaunch: true)
            }
    }

    /// Вызывается при завершении приложения: подготовленное обновление ставится без перезапуска.
    func installOnTerminate() {
        install(relaunch: false)
    }

    private func install(relaunch: Bool) {
        guard let (app, digest) = prepared, !installing else { return }
        installing = true
        idleObserver = nil
        do {
            try UpdateInstaller.launchInstaller(newApp: app, target: configuration.bundleURL,
                                                waitingFor: ProcessInfo.processInfo.processIdentifier,
                                                relaunch: relaunch, digest: digest)
        } catch {
            installing = false
            prepared = nil
            status = .failed
            return
        }
        if relaunch { NSApp.terminate(nil) }
    }
}
