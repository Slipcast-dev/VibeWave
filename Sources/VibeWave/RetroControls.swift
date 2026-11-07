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
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.custom("Arial", size: 12))
            .foregroundColor(enabled ? theme.foreground : theme.secondary.opacity(0.6))
            .offset(x: configuration.isPressed ? 1 : 0, y: configuration.isPressed ? 1 : 0)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(theme.panel)
            .retroBevel(theme, sunken: configuration.isPressed)
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
        .accessibilityValue("\(Int(fraction * 100)) процентов")
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
