import AppKit
import SwiftUI

/// Окно без системной полосы macOS: заголовок и кнопки рисует RetroCaptionView.
/// Возможность стать key/main нужна для клавиатуры в borderless-окне.
final class RetroWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    private var restoredFrame: NSRect?
    var togglePlayback: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // Текстовый редактор получает событие раньше окна; пробел в названии не перехватывается.
        if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            togglePlayback?()
        } else { super.keyDown(with: event) }
    }

    override func zoom(_ sender: Any?) {
        if let previous = restoredFrame {
            restoredFrame = nil
            setFrame(previous, display: true, animate: true)
        } else if let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            restoredFrame = frame
            setFrame(visible, display: true, animate: true)
        }
    }
}

/// Единственный владелец окна; SwiftUI по-прежнему владеет содержимым экрана.
final class RetroWindowController: NSWindowController {
    init(model: PlayerModel) {
        let window = RetroWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 570),
                                 styleMask: [.borderless, .resizable, .miniaturizable, .closable],
                                 backing: .buffered, defer: false)
        window.togglePlayback = { [weak model] in model?.toggle() }
        window.title = "VibeWave"
        window.isReleasedWhenClosed = false
        window.hasShadow = true
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.contentMinSize = NSSize(width: 390, height: 440)
        window.contentView = NSHostingView(rootView: ContentView(model: model))
        super.init(window: window)
        if !window.setFrameUsingName("VibeWaveMainWindow") { window.center() }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) { window.center() }
        window.setFrameAutosaveName("VibeWaveMainWindow")
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        guard let window = window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

/// AppKit-полоска заголовка даёт настоящую область перетаскивания и рабочие
/// системные действия. Ни невидимых кнопок macOS, ни декоративных дублей здесь нет.
struct RetroWindowTitleBar: NSViewRepresentable {
    let theme: PlayerTheme
    func makeNSView(context: Context) -> RetroCaptionView { RetroCaptionView(theme: theme) }
    func updateNSView(_ view: RetroCaptionView, context: Context) { view.theme = theme }
}

final class RetroCaptionView: NSView {
    var theme: PlayerTheme { didSet { buttons.forEach { $0.theme = theme }; needsDisplay = true } }
    private var buttons: [RetroCaptionButton] = []
    override var isFlipped: Bool { true }

    init(theme: PlayerTheme) {
        self.theme = theme
        super.init(frame: .zero)
        for kind in [RetroCaptionButton.Kind.minimize, .maximize, .close] {
            let button = RetroCaptionButton(kind: kind, theme: theme)
            button.target = self
            button.action = #selector(performWindowAction(_:))
            addSubview(button)
            buttons.append(button)
        }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Заголовок окна VibeWave")
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: bounds.width - 4 - CGFloat(3 - index) * 22,
                                  y: (bounds.height - 18) / 2, width: 20, height: 18)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(theme.titleBar).setFill()
        bounds.fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12), .foregroundColor: NSColor.white
        ]
        ("♪  VibeWave" as NSString).draw(at: NSPoint(x: 7, y: (bounds.height - 15) / 2), withAttributes: attributes)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.zoom(nil) }
        else { window?.performDrag(with: event) }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func performWindowAction(_ sender: RetroCaptionButton) {
        switch sender.kind {
        case .minimize: window?.miniaturize(nil)
        case .maximize: window?.zoom(nil)
        case .close: window?.close()
        }
    }
}

/// Квадратная кнопка NSButton сохраняет стандартную обработку нажатия и доступность.
final class RetroCaptionButton: NSButton {
    enum Kind { case minimize, maximize, close }
    let kind: Kind
    var theme: PlayerTheme { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    init(kind: Kind, theme: PlayerTheme) {
        self.kind = kind
        self.theme = theme
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryPushIn)
        switch kind {
        case .minimize: toolTip = "Свернуть"
        case .maximize: toolTip = "Развернуть или восстановить"
        case .close: toolTip = "Закрыть окно"
        }
        setAccessibilityLabel(toolTip)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted ?? false
        NSColor(theme.panel).setFill()
        bounds.fill()
        let top = NSColor(pressed ? theme.shadow : theme.highlight)
        let bottom = NSColor(pressed ? theme.highlight : theme.edge)
        top.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        bottom.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        NSColor(theme.foreground).setStroke()
        NSColor(theme.foreground).setFill()
        let offset: CGFloat = pressed ? 1 : 0
        let glyph = NSBezierPath()
        glyph.lineWidth = 1.5
        switch kind {
        case .minimize:
            NSRect(x: 5 + offset, y: 12 + offset, width: 8, height: 2).fill()
        case .maximize:
            glyph.appendRect(NSRect(x: 5 + offset, y: 4 + offset, width: 9, height: 9))
            glyph.move(to: NSPoint(x: 5 + offset, y: 6 + offset))
            glyph.line(to: NSPoint(x: 14 + offset, y: 6 + offset))
            glyph.stroke()
        case .close:
            glyph.move(to: NSPoint(x: 6 + offset, y: 5 + offset))
            glyph.line(to: NSPoint(x: 14 + offset, y: 13 + offset))
            glyph.move(to: NSPoint(x: 14 + offset, y: 5 + offset))
            glyph.line(to: NSPoint(x: 6 + offset, y: 13 + offset))
            glyph.stroke()
        }
    }
}
