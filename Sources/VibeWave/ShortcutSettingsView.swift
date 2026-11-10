import AppKit
import Carbon.HIToolbox
import SwiftUI
import VibeWaveCore

@MainActor
struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: GlobalShortcuts
    var onReset: () -> Void = {}
    @ObservedObject private var languages = LanguageSettings.shared
    @State private var recording: ShortcutAction?
    @State private var monitor: Any?
    @State private var recordingWindowNumber: Int?
    @State private var issue: ShortcutIssue?
    @State private var showReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(label("Глобальные сочетания", "Global Shortcuts"), isOn: Binding(
                get: { shortcuts.enabled },
                set: { value in
                    finishRecording()
                    issue = nil
                    shortcuts.setEnabled(value)
                }
            ))
            Text(label("Назначьте сочетание с ⌃, ⌥ или ⌘. Оно работает, когда VibeWave открыт в фоне.",
                       "Assign a shortcut with ⌃, ⌥ or ⌘ to use it while VibeWave runs in the background."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let issue = issue {
                Text(issue.message(in: languages.language))
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(ShortcutAction.allCases) { action in
                        shortcutRow(action)
                        Divider()
                    }
                }
            }
            Button(label("Сбросить сочетания…", "Reset Shortcuts…")) {
                finishRecording()
                showReset = true
            }
        }
        .confirmationDialog(label("Восстановить стандартные сочетания?", "Restore Default Shortcuts?"),
                            isPresented: $showReset, titleVisibility: .visible) {
            Button(label("Сбросить сочетания", "Reset Shortcuts"), role: .destructive) {
                issue = nil
                shortcuts.reset()
                onReset()
            }
        }
        .onDisappear { finishRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            if let window = notification.object as? NSWindow, window.windowNumber == recordingWindowNumber { finishRecording() }
        }
    }

    private func shortcutRow(_ action: ShortcutAction) -> some View {
        let title = action.title(in: languages.language)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Button {
                    if recording == action { finishRecording() }
                    else { startRecording(action) }
                } label: {
                    Text(bindingLabel(action))
                        .lineLimit(1)
                        .frame(minWidth: 112)
                }
                .accessibilityLabel(Text(title + " · " + bindingLabel(action)))
                Button(label("Очистить", "Clear")) {
                    finishRecording()
                    issue = nil
                    shortcuts.clear(action)
                }
                .disabled(shortcuts.bindings[action] == nil)
                .accessibilityLabel(Text(label("Очистить сочетание", "Clear shortcut") + " · " + title))
            }
            if let conflict = shortcuts.conflicts[action], recording == nil {
                Text(conflict.message(in: languages.language)).foregroundColor(.red).font(.caption)
            }
        }
    }

    private func bindingLabel(_ action: ShortcutAction) -> String {
        if recording == action { return label("Нажмите клавиши…", "Press Keys…") }
        return shortcuts.bindings[action]?.description ?? label("Назначить…", "Assign…")
    }

    private func startRecording(_ action: ShortcutAction) {
        finishRecording()
        issue = nil
        guard let window = NSApp.keyWindow else { return }
        recording = action
        recordingWindowNumber = window.windowNumber
        // Временно снимаем собственные сочетания: повторное нажатие
        // уже назначенного варианта должен получить редактор, а не плеер.
        shortcuts.beginCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard let window = window, event.window === window else { return event }
            if event.isARepeat { return nil }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == kVK_Escape, modifiers.isEmpty {
                finishRecording()
                return nil
            }
            do {
                try shortcuts.assign(ShortcutBinding(event: event), to: action)
                issue = nil
                finishRecording()
            } catch let error as ShortcutIssue {
                issue = error
            } catch {
                issue = .unavailable(OSStatus(eventInternalErr))
            }
            return nil
        }
        if monitor == nil {
            finishRecording()
            issue = .unavailable(OSStatus(eventInternalErr))
        }
    }

    private func finishRecording() {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingWindowNumber = nil
        if recording != nil {
            recording = nil
            shortcuts.endCapture()
        }
    }

    private func label(_ russian: String, _ english: String) -> String {
        languages.language == .ru ? russian : english
    }
}
