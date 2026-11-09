import AppKit
import Combine

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
final class VibeWaveAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = PlayerModel()
    private var playerWindow: RetroWindowController?
    private var languageObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installIcon()
        installMenu()
        // objectWillChange приходит до изменения: меню строится на следующем проходе цикла.
        languageObserver = LanguageSettings.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.installMenu() }
        showPlayer()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPlayer()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.openFiles(urls)
        showPlayer()
    }

    func applicationWillTerminate(_ notification: Notification) { model.stop() }

    func installIcon() {
        guard let url = Bundle.main.url(forResource: "VibeWaveIcon", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return }
        NSImage(named: NSImage.applicationIconName)?.setName(nil)
        image.setName(NSImage.applicationIconName)
        NSApp.applicationIconImage = image
    }

    private func showPlayer() {
        if playerWindow == nil { playerWindow = RetroWindowController(model: model) }
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
        appMenu.addItem(withTitle: s.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let file = NSMenu(title: s.menuFile)
        let add = file.addItem(withTitle: s.menuAddFiles, action: #selector(addFiles), keyEquivalent: "o")
        add.target = self
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

        let windowMenu = NSMenu(title: s.menuWindow)
        let minimize = windowMenu.addItem(withTitle: s.minimize, action: #selector(minimizePlayer), keyEquivalent: "m")
        minimize.target = self
        let zoom = windowMenu.addItem(withTitle: s.zoom, action: #selector(zoomPlayer), keyEquivalent: "")
        zoom.target = self
        let windowItem = NSMenuItem(title: s.menuWindow, action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func addFiles() { showPlayer(); model.importFiles() }
    @objc private func closePlayer() { playerWindow?.window?.close() }
    @objc private func minimizePlayer() { playerWindow?.window?.miniaturize(nil) }
    @objc private func zoomPlayer() { playerWindow?.window?.zoom(nil) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(addFiles) { return !model.importing }
        return true
    }
}
