import AppKit
import SwiftUI
import VibeWaveCore

/// Общие размеры для заголовков и строк исключают расхождение столбцов.
struct TrackColumnWidths {
    var number: CGFloat
    var title: CGFloat
    var format: CGFloat
    var duration: CGFloat
    static let divider: CGFloat = 7
    var total: CGFloat { number + title + format + duration + Self.divider * 4 }
}

struct TrackTable: View {
    @ObservedObject var model: PlayerModel
    let theme: PlayerTheme
    @State private var endTargeted = false
    @AppStorage("columns.number") private var number = 56.0
    @AppStorage("columns.title") private var title = 360.0
    @AppStorage("columns.format") private var format = 100.0
    @AppStorage("columns.duration") private var duration = 92.0

    private var columns: TrackColumnWidths {
        TrackColumnWidths(number: bounded(number, 52...120), title: bounded(title, 160...1200),
                          format: bounded(format, 76...280), duration: bounded(duration, 76...280))
    }
    private func bounded(_ value: Double, _ range: ClosedRange<Double>) -> CGFloat {
        CGFloat(value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : range.lowerBound)
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    header
                    if model.visibleTracks.isEmpty {
                        VStack(spacing: 10) {
                            Spacer()
                            Image(systemName: "music.note").font(.system(size: 24)).foregroundColor(theme.secondary)
                            Text(model.selectedID == nil ? "Откройте музыку" : "Добавьте музыку в плейлист").fontWeight(.bold)
                            Text("Перетащите сюда файлы MP3 и FLAC").foregroundColor(theme.secondary)
                            Spacer()
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.visibleTracks.enumerated()), id: \.element.id) { index, track in
                                    TrackRow(model: model, track: track, tracks: model.visibleTracks,
                                             playlistID: model.selectedID, index: index, theme: theme, columns: columns)
                                }
                                Color.clear.frame(height: 32).contentShape(Rectangle())
                                    .background(endTargeted ? theme.selection.opacity(0.18) : .clear)
                                    .overlay(alignment: .top) {
                                        if endTargeted { Rectangle().fill(theme.accent).frame(height: 2).allowsHitTesting(false) }
                                    }
                                    .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: model.selectedID, targeted: $endTargeted))
                            }
                        }
                    }
                }
                .frame(width: max(geometry.size.width, columns.total), height: geometry.size.height)
            }
        }
        .background(theme.background).retroBevel(theme, sunken: true)
    }
    private var header: some View {
        HStack(spacing: 0) {
            cell("№", width: columns.number)
            ColumnResizer(value: $number, limits: 52...120, initial: 56, label: "Номер", theme: theme)
            cell("Название", width: columns.title)
            ColumnResizer(value: $title, limits: 160...1200, initial: 360, label: "Название", theme: theme)
            cell("Формат", width: columns.format)
            ColumnResizer(value: $format, limits: 76...280, initial: 100, label: "Формат", theme: theme)
            cell("Время", width: columns.duration)
            ColumnResizer(value: $duration, limits: 76...280, initial: 92, label: "Время", theme: theme)
            Spacer(minLength: 0)
        }
        .background(theme.panel).retroBevel(theme)
    }
    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(text).font(.custom("Arial", size: 13).weight(.bold))
            .padding(.horizontal, 7).frame(width: width, alignment: .leading)
            .padding(.vertical, 8).foregroundColor(theme.foreground)
    }
}

/// Изменение ширины не запускает перетаскивание трека; двойной щелчок сбрасывает размер.
private struct ColumnResizer: View {
    @Binding var value: Double
    let limits: ClosedRange<Double>
    let initial: Double
    let label: String
    let theme: PlayerTheme
    @State private var origin: Double?
    @State private var hovered = false
    var body: some View {
        Rectangle().fill(hovered ? theme.accent.opacity(0.25) : theme.panel)
            .overlay(Rectangle().fill(theme.shadow).frame(width: 1))
            .frame(width: TrackColumnWidths.divider, height: 33)
            .contentShape(Rectangle())
            .onHover { inside in
                hovered = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear { if hovered { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1).onChanged { event in
                if origin == nil { origin = value.isFinite ? value : initial }
                value = min(limits.upperBound, max(limits.lowerBound, (origin ?? initial) + Double(event.translation.width)))
            }.onEnded { _ in origin = nil })
            .onTapGesture(count: 2) { value = initial }
            .help("Ширина: \(label). Перетащите границу; двойной щелчок — сброс.")
            .accessibilityLabel("Ширина столбца \(label)")
            .accessibilityValue("\(Int(value.isFinite ? value : initial))")
            .accessibilityAdjustableAction { direction in
                let delta: Double
                switch direction {
                case .increment: delta = 10
                case .decrement: delta = -10
                @unknown default: return
                }
                value = min(limits.upperBound, max(limits.lowerBound, (value.isFinite ? value : initial) + delta))
            }
    }
}
