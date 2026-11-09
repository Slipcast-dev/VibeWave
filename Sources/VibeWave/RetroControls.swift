import AppKit
import SwiftUI

/// Две пары светлых/тёмных граней создают классическую объёмную рамку.
/// Рамка декоративная: она не перехватывает клики и перетаскивание файлов.
struct RetroBevel: View {
    let theme: PlayerTheme
    var sunken = false
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: height - 0.5))
                path.addLine(to: CGPoint(x: 0.5, y: 0.5))
                path.addLine(to: CGPoint(x: width - 0.5, y: 0.5))
            }.stroke(sunken ? theme.shadow : theme.highlight, lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: 0.5, y: height - 0.5))
                path.addLine(to: CGPoint(x: width - 0.5, y: height - 0.5))
                path.addLine(to: CGPoint(x: width - 0.5, y: 0.5))
            }.stroke(sunken ? theme.highlight : theme.edge, lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: 1.5, y: height - 1.5))
                path.addLine(to: CGPoint(x: 1.5, y: 1.5))
                path.addLine(to: CGPoint(x: width - 1.5, y: 1.5))
            }.stroke(sunken ? theme.edge : theme.panel, lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: 1.5, y: height - 1.5))
                path.addLine(to: CGPoint(x: width - 1.5, y: height - 1.5))
                path.addLine(to: CGPoint(x: width - 1.5, y: 1.5))
            }.stroke(sunken ? theme.panel : theme.shadow, lineWidth: 1)
        }.allowsHitTesting(false)
    }
}

extension View {
    func retroBevel(_ theme: PlayerTheme, sunken: Bool = false) -> some View {
        overlay(RetroBevel(theme: theme, sunken: sunken))
    }
}

/// Нажатая кнопка меняет направление граней и сдвигает содержимое на пиксель.
/// Состояния disabled и фокус остаются частью обычной SwiftUI Button.
struct RetroButtonStyle: ButtonStyle {
    let theme: PlayerTheme
    /// Компактная кнопка для панелей плеера и плейлиста.
    var compact = false
    /// Фиксированная ширина (кнопки транспорта одинакового размера).
    var width: CGFloat? = nil
    /// Включённый переключатель рисуется вдавленным.
    var isOn = false
    /// Кнопка нижней панели: крупнее компактной, но ниже обычной.
    var toolbar = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let sunken = configuration.isPressed || isOn
        configuration.label
            .font(.custom("Arial", size: compact && !toolbar ? 11 : 12))
            .lineLimit(1)
            // Текст не сжимается и не обрезается: кнопка растёт по его ширине.
            .fixedSize()
            .foregroundColor(enabled ? theme.foreground : theme.secondary.opacity(0.6))
            .offset(x: sunken ? 1 : 0, y: sunken ? 1 : 0)
            .frame(width: width)
            .padding(.horizontal, width == nil ? (toolbar ? 10 : compact ? 7 : 10) : 0)
            .padding(.vertical, toolbar ? 5 : compact ? 4 : 7)
            .background(isOn ? Color(white: 0.85) : theme.panel)
            .retroBevel(theme, sunken: sunken)
            .contentShape(Rectangle())
    }
}

/// Прямоугольный ползунок с классическим бегунком вместо современного круглого.
/// Управляется мышью, стрелками клавиатуры и действиями доступности.
struct RetroSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let theme: PlayerTheme
    @Environment(\.isEnabled) private var enabled

    private var fraction: Double {
        guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
    var body: some View {
        GeometryReader { geometry in
            let travel = max(1, geometry.size.width - 14)
            ZStack(alignment: .leading) {
                Rectangle().fill(theme.panel).frame(height: 5).retroBevel(theme, sunken: true)
                Rectangle().fill(theme.panel).frame(width: 14, height: 22)
                    .retroBevel(theme)
                    .overlay(Rectangle().fill(theme.shadow).frame(width: 1, height: 12))
                    .offset(x: travel * fraction)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard enabled else { return }
                let progress = min(1, max(0, (event.location.x - 7) / travel))
                value = range.lowerBound + progress * (range.upperBound - range.lowerBound)
            })
        }
        .frame(height: 24)
        .opacity(enabled ? 1 : 0.5)
        .focusable(enabled)
        .onMoveCommand { direction in
            guard enabled else { return }
            if direction == .left || direction == .down { adjust(-1) }
            if direction == .right || direction == .up { adjust(1) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(LanguageSettings.shared.strings.percent(Int(fraction * 100)))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: adjust(1)
            case .decrement: adjust(-1)
            @unknown default: break
            }
        }
    }
    private func adjust(_ direction: Double) {
        let step = (range.upperBound - range.lowerBound) / 100
        value = min(range.upperBound, max(range.lowerBound, value + direction * step))
    }
}

/// Вертикальный ползунок (полосы эквалайзера): бегунок в стиле Windows 95, риска нуля,
/// двойной щелчок возвращает к нулю. Мышь, стрелки и действия доступности.
struct RetroVerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    let theme: PlayerTheme
    /// Значение для VoiceOver, например «+3 дБ».
    var valueText: (Double) -> String = { String(format: "%.0f", $0) }
    @Environment(\.isEnabled) private var enabled

    private var fraction: Double {
        guard value.isFinite, range.upperBound > range.lowerBound else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
    }
    private var zero: Double { range.contains(0) ? 0 : range.lowerBound }

    var body: some View {
        GeometryReader { geometry in
            let thumb: CGFloat = 12
            let travel = max(1, geometry.size.height - thumb)
            let zeroFraction = (zero - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .top) {
                Rectangle().fill(theme.shadow).frame(width: geometry.size.width, height: 1)
                    .offset(y: thumb / 2 + travel * (1 - zeroFraction))
                Rectangle().fill(theme.panel).frame(width: 5).retroBevel(theme, sunken: true)
                    .padding(.vertical, thumb / 2 - 2)
                Rectangle().fill(theme.panel).frame(width: geometry.size.width - 2, height: thumb)
                    .retroBevel(theme)
                    .overlay(Rectangle().fill(theme.shadow).frame(width: geometry.size.width - 10, height: 1))
                    .offset(y: travel * (1 - fraction))
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                guard enabled else { return }
                let progress = 1 - min(1, max(0, (event.location.y - thumb / 2) / travel))
                set(range.lowerBound + progress * (range.upperBound - range.lowerBound))
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { if enabled { set(zero) } })
        }
        .opacity(enabled ? 1 : 0.5)
        .focusable(enabled)
        .onMoveCommand { direction in
            guard enabled else { return }
            if direction == .down || direction == .left { set(value - step) }
            if direction == .up || direction == .right { set(value + step) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { direction in
            guard enabled else { return }
            switch direction {
            case .increment: set(value + step)
            case .decrement: set(value - step)
            @unknown default: break
            }
        }
    }

    private func set(_ newValue: Double) {
        value = min(range.upperBound, max(range.lowerBound, newValue))
    }
}

/// Кнопка в общем ретро-стиле, открывающая нативное меню под собой.
/// SwiftUI Menu на macOS рисует собственную кнопку и не принимает ButtonStyle.
struct RetroMenuButton: View {
    enum Item {
        case action(String, checked: Bool = false, () -> Void)
        case separator
    }

    let title: String
    let items: () -> [Item]
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button { anchor.popUp(items()) } label: { Text(title) }
            .background(MenuAnchorView(anchor: anchor))
    }
}

@MainActor
final class MenuAnchor {
    weak var view: NSView?

    func popUp(_ items: [RetroMenuButton.Item]) {
        guard let view = view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            switch item {
            case .separator: menu.addItem(.separator())
            case let .action(title, checked, handler): menu.addItem(ClosureMenuItem(title, checked: checked, handler: handler))
            }
        }
        // Верхний левый угол меню — под нижним краем кнопки.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height + 2 : -2), in: view)
    }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
