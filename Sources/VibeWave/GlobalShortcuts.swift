import AppKit
import Carbon.HIToolbox
import Combine
import VibeWaveCore

enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case playPause, stop, next, previous, seekForward, seekBackward
    case volumeUp, volumeDown, mute, repeatMode, shuffle, showWindow

    var id: Self { self }

    func title(in language: AppLanguage) -> String {
        let ru = language == .ru
        switch self {
        case .playPause: return ru ? "Воспроизведение / пауза" : "Play / Pause"
        case .stop: return ru ? "Остановить" : "Stop"
        case .next: return ru ? "Следующий трек" : "Next Track"
        case .previous: return ru ? "Предыдущий трек" : "Previous Track"
        case .seekForward: return ru ? "Перемотать на 5 секунд вперёд" : "Skip Forward 5 Seconds"
        case .seekBackward: return ru ? "Перемотать на 5 секунд назад" : "Skip Back 5 Seconds"
        case .volumeUp: return ru ? "Увеличить громкость" : "Volume Up"
        case .volumeDown: return ru ? "Уменьшить громкость" : "Volume Down"
        case .mute: return ru ? "Включить / выключить звук" : "Mute / Unmute"
        case .repeatMode: return ru ? "Сменить режим повтора" : "Cycle Repeat Mode"
        case .shuffle: return ru ? "Включить / выключить перемешивание" : "Toggle Shuffle"
        case .showWindow: return ru ? "Показать окно" : "Show Window"
        }
    }
}

/// Код соответствует физической клавише. Подпись сохраняется из раскладки,
/// которая действовала в момент назначения.
struct ShortcutBinding: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    fileprivate static let supportedModifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)

    init(keyCode: Int, modifiers: Int, keyLabel: String) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
        self.keyLabel = keyLabel
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }

        let code = Int(event.keyCode)
        let translated = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        let label = Self.specialKeys[code] ?? (translated.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value)
        } ? translated.uppercased() : "")
        self.init(keyCode: code, modifiers: modifiers, keyLabel: label.isEmpty ? "#\(code)" : label)
    }

    var description: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + keyLabel
    }

    fileprivate var isValid: Bool {
        keyCode <= 255 && modifiers & ~Self.supportedModifiers == 0 &&
            modifiers & UInt32(controlKey | optionKey | cmdKey) != 0 &&
            !keyLabel.isEmpty && keyLabel.utf8.count <= 48 &&
            !keyLabel.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    fileprivate func matches(_ other: Self) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "␣", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_DownArrow: "↓", kVK_UpArrow: "↑",
        kVK_ANSI_KeypadEnter: "⌤", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
        kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20"
    ]
}

enum ShortcutIssue: Error, Equatable {
    case needsModifier
    case reserved
    case duplicate(ShortcutAction)
    case unavailable(OSStatus)

    func message(in language: AppLanguage) -> String {
        let ru = language == .ru
        switch self {
        case .needsModifier:
            return ru ? "Удерживайте ⌃, ⌥ или ⌘ вместе с клавишей." : "Hold ⌃, ⌥ or ⌘ while pressing the key."
        case .reserved:
            return ru ? "Это сочетание зарезервировано для macOS или меню приложения." :
                "This shortcut is reserved for macOS or an app menu."
        case .duplicate(let action):
            let title = action.title(in: language)
            return ru ? "Сочетание уже назначено действию «\(title)»." : "This shortcut is already assigned to “\(title)”."
        case .unavailable(let status):
            if status == OSStatus(eventHotKeyExistsErr) {
                return ru ? "Сочетание уже занято в macOS." : "This shortcut is already in use in macOS."
            }
            return ru ? "macOS отклонила сочетание (\(status))." : "macOS rejected the shortcut (\(status))."
        }
    }
}

private let hotKeySignature: OSType = 0x5662576B // VbWk

private let shortcutEventHandler: EventHandlerUPP = { _, event, context in
    guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr, identifier.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let shortcuts = Unmanaged<GlobalShortcuts>.fromOpaque(context).takeUnretainedValue()
    let id = identifier.id
    DispatchQueue.main.async { [weak shortcuts] in shortcuts?.invoke(id) }
    return noErr
}

/// Carbon сообщает только о зарегистрированных сочетаниях. Глобальное
/// наблюдение за вводом и разрешения универсального доступа здесь не нужны.
@MainActor
final class GlobalShortcuts: ObservableObject {
    private struct Configuration: Codable {
        var enabled: Bool
        var bindings: [String: ShortcutBinding]
    }

    private struct Registration {
        let id: UInt32
        let reference: EventHotKeyRef
    }

    static let defaultsKey = "app.globalShortcuts"
    @Published private(set) var enabled: Bool
    @Published private(set) var bindings: [ShortcutAction: ShortcutBinding]
    @Published private(set) var conflicts: [ShortcutAction: ShortcutIssue] = [:]

    private let defaults: UserDefaults
    private var actionHandler: ((ShortcutAction) -> Void)?
    private var eventHandler: EventHandlerRef?
    private var registrations: [ShortcutAction: Registration] = [:]
    private var nextID: UInt32 = 0
    private var capturing = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.data(forKey: Self.defaultsKey).flatMap {
            try? JSONDecoder().decode(Configuration.self, from: $0)
        }
        enabled = stored?.enabled ?? false
        if let stored = stored {
            var valid: [ShortcutAction: ShortcutBinding] = [:]
            for action in ShortcutAction.allCases {
                if let binding = stored.bindings[action.rawValue], binding.isValid, !Self.isReserved(binding),
                   !valid.values.contains(where: { $0.matches(binding) }) {
                    valid[action] = binding
                }
            }
            bindings = valid
        } else {
            bindings = Self.defaultBindings
        }
    }

    deinit {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        if let handler = eventHandler { RemoveEventHandler(handler) }
    }

    func start(actionHandler: @escaping (ShortcutAction) -> Void) {
        self.actionHandler = actionHandler
        activateBindings()
    }

    func stop() {
        unregisterAll()
        if let handler = eventHandler { RemoveEventHandler(handler) }
        eventHandler = nil
        actionHandler = nil
        capturing = false
        conflicts = [:]
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        save()
        activateBindings()
    }

    func beginCapture() {
        capturing = true
        unregisterAll()
    }

    func endCapture() {
        guard capturing else { return }
        capturing = false
        activateBindings()
    }

    func assign(_ binding: ShortcutBinding, to action: ShortcutAction) throws {
        guard binding.isValid else { throw ShortcutIssue.needsModifier }
        guard !Self.isReserved(binding) else { throw ShortcutIssue.reserved }
        if let existing = bindings.first(where: { $0.key != action && $0.value.matches(binding) }) {
            throw ShortcutIssue.duplicate(existing.key)
        }
        if let previous = bindings[action], previous.matches(binding), registrations[action] != nil {
            bindings[action] = binding
            save()
            return
        }

        // Проверяем новый вариант до удаления прежнего. В выключенном режиме
        // и при записи пробная регистрация освобождается сразу же.
        let registration = try register(binding)
        if enabled && !capturing && actionHandler != nil {
            if let previous = registrations.updateValue(registration, forKey: action) {
                UnregisterEventHotKey(previous.reference)
            }
        } else {
            UnregisterEventHotKey(registration.reference)
        }
        bindings[action] = binding
        conflicts[action] = nil
        save()
    }

    func clear(_ action: ShortcutAction) {
        if let registration = registrations.removeValue(forKey: action) {
            UnregisterEventHotKey(registration.reference)
        }
        bindings[action] = nil
        conflicts[action] = nil
        save()
    }

    func reset() {
        enabled = false
        bindings = Self.defaultBindings
        save()
        activateBindings()
    }

    fileprivate func invoke(_ id: UInt32) {
        guard enabled, !capturing,
              let action = registrations.first(where: { $0.value.id == id })?.key else { return }
        actionHandler?(action)
    }

    private func activateBindings() {
        unregisterAll()
        conflicts = [:]
        guard enabled, !capturing, actionHandler != nil else { return }
        for action in ShortcutAction.allCases {
            guard let binding = bindings[action] else { continue }
            do {
                registrations[action] = try register(binding)
            } catch let issue as ShortcutIssue {
                conflicts[action] = issue
            } catch {
                conflicts[action] = .unavailable(OSStatus(eventInternalErr))
            }
        }
    }

    private func register(_ binding: ShortcutBinding) throws -> Registration {
        let target = GetApplicationEventTarget()
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(target, shortcutEventHandler, 1, &eventType,
                                             Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
            guard status == noErr else { throw ShortcutIssue.unavailable(status) }
        }
        nextID &+= 1
        let identifier = EventHotKeyID(signature: hotKeySignature, id: nextID)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, identifier, target,
                                         OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference = reference else { throw ShortcutIssue.unavailable(status) }
        return Registration(id: nextID, reference: reference)
    }

    private func unregisterAll() {
        for registration in registrations.values { UnregisterEventHotKey(registration.reference) }
        registrations.removeAll()
    }

    private func save() {
        let values = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        let config = Configuration(enabled: enabled, bindings: values)
        if let data = try? JSONEncoder().encode(config) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// AppKit передаёт ⌘-сочетания меню по символу, Carbon регистрирует
    /// их по коду. Проверяем оба варианта, включая нелатинские раскладки.
    private static func isReserved(_ binding: ShortcutBinding) -> Bool {
        guard binding.modifiers == UInt32(cmdKey) else { return false }
        let menuKeys = ["A", "C", "M", "O", "Q", "V", "W", "X", "Z", ",", "H", "␣", "⇥", "`"]
        let menuCodes = [
            kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_M, kVK_ANSI_O, kVK_ANSI_Q, kVK_ANSI_V,
            kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Z, kVK_ANSI_Comma, kVK_ANSI_H,
            kVK_Space, kVK_Tab, kVK_ANSI_Grave
        ]
        return menuKeys.contains(binding.keyLabel) || menuCodes.contains(Int(binding.keyCode))
    }

    private static let defaultBindings: [ShortcutAction: ShortcutBinding] = [
        .playPause: makeDefault(kVK_ANSI_P, "P"), .stop: makeDefault(kVK_ANSI_S, "S"),
        .next: makeDefault(kVK_RightArrow, "→"), .previous: makeDefault(kVK_LeftArrow, "←"),
        .seekForward: makeDefault(kVK_ANSI_F, "F"), .seekBackward: makeDefault(kVK_ANSI_B, "B"),
        .volumeUp: makeDefault(kVK_UpArrow, "↑"), .volumeDown: makeDefault(kVK_DownArrow, "↓"),
        .mute: makeDefault(kVK_ANSI_M, "M"), .repeatMode: makeDefault(kVK_ANSI_R, "R"),
        .shuffle: makeDefault(kVK_ANSI_L, "L"), .showWindow: makeDefault(kVK_ANSI_W, "W")
    ]

    private static func makeDefault(_ code: Int, _ label: String) -> ShortcutBinding {
        ShortcutBinding(keyCode: code, modifiers: controlKey | optionKey | cmdKey, keyLabel: label)
    }
}
