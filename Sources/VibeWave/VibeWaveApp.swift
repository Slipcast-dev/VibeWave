import AppKit
import Combine
import SwiftUI
import VibeWaveCore

/// AppKit управляет единственным окном без стандартной полосы macOS;
/// интерфейс внутри окна остаётся SwiftUI.
@main
struct VibeWaveApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = VibeWaveAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class VibeWaveAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSWindowDelegate {
    let model = PlayerModel()
    private var playerWindow: RetroWindowController?
    private var settingsWindow: NSWindowController?
    private var languageObserver: AnyCancellable?
    private var updater: Updater?
    private let preferences = SettingsPreferences.shared
    private let shortcuts = GlobalShortcuts()
    private lazy var mediaControls = MediaKeyControls(model: model)
    private var mediaObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installIcon()
        installMenu()
        // objectWillChange приходит до изменения: меню строится на следующем проходе цикла.
        languageObserver = LanguageSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.installMenu() }
        model.restorePlaybackSession()
        showPlayer()
        shortcuts.start { [weak self] action in self?.performShortcut(action) }
        mediaObserver = preferences.$mediaKeys
            .sink { [weak self] enabled in
                if enabled { self?.mediaControls.start() } else { self?.mediaControls.stop() }
            }
        // Автообновление работает только у собранного приложения с ключом проверки в Info.plist.
        if let configuration = Updater.Configuration.fromMainBundle() {
            updater = Updater(model: model, configuration: configuration)
            updater?.checkOnLaunch { [weak preferences] in preferences?.automaticUpdates == true }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPlayer()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.openFiles(urls)
        showPlayer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.savePlaybackSession()
        model.stop(preservingSession: true)
        PersistenceQueue.shared.flush()
        shortcuts.stop()
        mediaControls.stop()
        updater?.installOnTerminate()
    }

    func windowWillClose(_ notification: Notification) {
        guard preferences.quitOnClose, notification.object as? NSWindow === playerWindow?.window else { return }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func installIcon() {
        guard let url = Bundle.main.url(forResource: "VibeWaveIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSImage(named: NSImage.applicationIconName)?.setName(nil)
        image.setName(NSImage.applicationIconName)
        NSApp.applicationIconImage = image
    }

    private func showPlayer() {
        if playerWindow == nil {
            playerWindow = RetroWindowController(model: model)
            playerWindow?.window?.delegate = self
        }
        playerWindow?.present()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Стандартные меню сохраняют привычные сочетания клавиш и редактирование названий.
    /// Меню перестраивается при смене языка интерфейса.
    private func installMenu() {
        let s = LanguageSettings.shared.strings
        let main = NSMenu()
        let appMenu = NSMenu(title: "VibeWave")
        appMenu.addItem(withTitle: s.menuAbout, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: s.menuSettings, action: #selector(showSettings), keyEquivalent: ",").target = self
        settingsWindow?.window?.title = s.settingsTitle
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: s.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let file = NSMenu(title: s.menuFile)
        let add = file.addItem(withTitle: s.menuAddFiles, action: #selector(addFiles), keyEquivalent: "o")
        add.target = self
        file.addItem(withTitle: s.importPlaylistFile, action: #selector(importPlaylist), keyEquivalent: "").target = self
        file.addItem(withTitle: s.exportPlaylistFile, action: #selector(exportPlaylist), keyEquivalent: "").target = self
        file.addItem(.separator())
        let close = file.addItem(withTitle: s.closeWindow, action: #selector(closePlayer), keyEquivalent: "w")
        close.target = self
        let fileItem = NSMenuItem(title: s.menuFile, action: nil, keyEquivalent: ""); fileItem.submenu = file; main.addItem(fileItem)

        let edit = NSMenu(title: s.menuEdit)
        edit.addItem(withTitle: s.menuUndo, action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: s.menuCut, action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: s.menuCopy, action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: s.menuPaste, action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: s.menuSelectAll, action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: s.menuEdit, action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)

        let playbackMenu = NSMenu(title: s.menuPlayback)
        playbackMenu.addItem(withTitle: s.shuffle, action: #selector(toggleShuffle), keyEquivalent: "").target = self
        let repeatMenu = NSMenu(title: s.repeatLabel)
        for (index, mode) in RepeatMode.allCases.enumerated() {
            let item = repeatMenu.addItem(withTitle: s.repeatModeName(mode), action: #selector(setRepeatMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
        }
        let repeatItem = NSMenuItem(title: s.repeatLabel, action: nil, keyEquivalent: "")
        repeatItem.submenu = repeatMenu
        playbackMenu.addItem(repeatItem)
        let playbackItem = NSMenuItem(title: s.menuPlayback, action: nil, keyEquivalent: "")
        playbackItem.submenu = playbackMenu
        main.addItem(playbackItem)

        let windowMenu = NSMenu(title: s.menuWindow)
        let minimize = windowMenu.addItem(withTitle: s.minimize, action: #selector(minimizePlayer), keyEquivalent: "m")
        minimize.target = self
        let zoom = windowMenu.addItem(withTitle: s.zoom, action: #selector(zoomPlayer), keyEquivalent: "")
        zoom.target = self
        let windowItem = NSMenuItem(title: s.menuWindow, action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(model: model, preferences: preferences, shortcuts: shortcuts, updater: updater)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.title = model.strings.settingsTitle
            window.center()
            settingsWindow = NSWindowController(window: window)
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private func performShortcut(_ action: ShortcutAction) {
        switch action {
        case .playPause: model.toggle()
        case .stop: model.stop()
        case .next: model.next()
        case .previous: model.previous()
        case .seekForward: if model.current != nil { model.seek(model.engine.currentTime + 5) }
        case .seekBackward: if model.current != nil { model.seek(model.engine.currentTime - 5) }
        case .volumeUp: model.adjustVolume(by: 0.05)
        case .volumeDown: model.adjustVolume(by: -0.05)
        case .mute: model.muted.toggle()
        case .repeatMode: model.cycleRepeat()
        case .shuffle: model.shuffleEnabled.toggle()
        case .showWindow: showPlayer()
        }
    }

    @objc private func toggleShuffle() { model.shuffleEnabled.toggle() }

    @objc private func setRepeatMode(_ item: NSMenuItem) {
        model.repeatMode = RepeatMode.allCases[item.tag]
    }

    @objc private func importPlaylist() { showPlayer(); model.choosePlaylistFiles() }
    @objc private func exportPlaylist() { model.choosePlaylistExport() }
    @objc private func addFiles() { showPlayer(); model.importFiles() }
    @objc private func closePlayer() {
        if let settings = settingsWindow?.window, settings.isKeyWindow { settings.close() }
        else { playerWindow?.window?.close() }
    }
    @objc private func minimizePlayer() { playerWindow?.window?.miniaturize(nil) }
    @objc private func zoomPlayer() { playerWindow?.window?.zoom(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(addFiles) || menuItem.action == #selector(importPlaylist) { return !model.importing }
        if menuItem.action == #selector(exportPlaylist) { return model.selected != nil }
        if menuItem.action == #selector(toggleShuffle) {
            menuItem.state = model.shuffleEnabled ? .on : .off
        }
        if menuItem.action == #selector(setRepeatMode(_:)) {
            menuItem.state = model.repeatMode == RepeatMode.allCases[menuItem.tag] ? .on : .off
        }
        return true
    }
}
