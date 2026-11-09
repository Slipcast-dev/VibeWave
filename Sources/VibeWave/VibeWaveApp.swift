import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        installIcon()
        installMenu()
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
    private func installMenu() {
        let main = NSMenu()
        let appMenu = NSMenu(title: "VibeWave")
        appMenu.addItem(withTitle: "О VibeWave", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Завершить VibeWave", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let file = NSMenu(title: "Файл")
        let add = file.addItem(withTitle: "Добавить файлы…", action: #selector(addFiles), keyEquivalent: "o")
        add.target = self
        let close = file.addItem(withTitle: "Закрыть окно", action: #selector(closePlayer), keyEquivalent: "w")
        close.target = self
        let fileItem = NSMenuItem(title: "Файл", action: nil, keyEquivalent: ""); fileItem.submenu = file; main.addItem(fileItem)

        let edit = NSMenu(title: "Правка")
        edit.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: ""); editItem.submenu = edit; main.addItem(editItem)

        let windowMenu = NSMenu(title: "Окно")
        let minimize = windowMenu.addItem(withTitle: "Свернуть", action: #selector(minimizePlayer), keyEquivalent: "m")
        minimize.target = self
        let zoom = windowMenu.addItem(withTitle: "Развернуть или восстановить", action: #selector(zoomPlayer), keyEquivalent: "")
        zoom.target = self
        let windowItem = NSMenuItem(title: "Окно", action: nil, keyEquivalent: ""); windowItem.submenu = windowMenu; main.addItem(windowItem)
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
