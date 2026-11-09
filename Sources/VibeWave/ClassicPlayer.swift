import AppKit
import SwiftUI
import VibeWaveCore

/// Панель плеера в стиле Windows 95: табло со временем и индикатором уровня,
/// поле с бегущей строкой, сведения о файле, громкость, баланс, позиция
/// и кнопки управления. Работает поверх PlayerModel.
@MainActor
struct ClassicPlayerPanel: View {
    @ObservedObject var model: PlayerModel
    let theme: PlayerTheme
    @AppStorage("classic.remainingTime") private var showRemaining = false
    @State private var showEqualizer = false
    @ObservedObject private var languages = LanguageSettings.shared
    private var s: Strings { languages.strings }

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                display
                VStack(alignment: .leading, spacing: 5) {
                    Marquee(text: marqueeText).frame(height: 18)
                        .background(theme.background).retroBevel(theme, sunken: true)
                    info
                    HStack(spacing: 6) {
                        Image(systemName: "speaker.wave.1").font(.system(size: 10))
                        RetroSlider(value: $model.volume, theme: theme)
                            .frame(minWidth: 70).help(s.volume).accessibilityLabel(s.volume)
                        Text(s.balanceShort).font(.custom("Arial", size: 10).weight(.bold)).help(s.balance)
                        RetroSlider(value: $model.balance, range: -1...1, theme: theme)
                            .frame(width: 56).help(s.balanceHelp).accessibilityLabel(s.balance)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { model.balance = 0 })
                    }
                }
            }
            RetroSlider(value: Binding(get: { model.position }, set: { model.seek($0) }),
                        range: 0...max(1, model.duration), theme: theme)
                .disabled(model.current == nil).accessibilityLabel(s.position)
            controls
        }
        .padding(7)
        .background(theme.panel).retroBevel(theme)
    }

    // MARK: ЖК-экран

    private var display: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 6) {
                VStack(spacing: 5) {
                    Image(systemName: statusIcon).font(.system(size: 9, weight: .black))
                        .foregroundColor(model.current == nil ? theme.shadow : theme.accent)
                    Text(model.currentChannels >= 2 ? "ST" : model.currentChannels == 1 ? "MO" : "  ")
                        .font(.custom("Arial", size: 8).weight(.bold)).foregroundColor(theme.secondary)
                        .lineLimit(1).fixedSize()
                }.frame(width: 16)
                Button { showRemaining.toggle() } label: {
                    Text(timeText)
                        .font(.custom("Arial", size: 28).weight(.bold)).monospacedDigit()
                        .foregroundColor(model.current == nil ? theme.shadow : theme.foreground)
                        .lineLimit(1).fixedSize()
                }
                .buttonStyle(.plain).help(s.timeHelp)
            }
            SpectrumView(model: model, theme: theme).frame(height: 20)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(width: 168, height: 78, alignment: .leading)
        .background(theme.background).retroBevel(theme, sunken: true)
    }

    private var statusIcon: String {
        if model.current == nil { return "stop.fill" }
        return model.playing ? "play.fill" : "pause.fill"
    }

    private var timeText: String {
        guard model.current != nil else { return "00:00" }
        let seconds = showRemaining ? max(0, model.duration - model.position) : model.position
        let value = Int(seconds.isFinite ? seconds : 0)
        return String(format: "%@%02d:%02d", showRemaining ? "-" : "", value / 60, value % 60)
    }

    private var marqueeText: String {
        guard let track = model.current else { return s.idleMarquee }
        let number = model.displayedTracks.firstIndex(where: { $0.id == track.id }).map { "\($0 + 1). " } ?? ""
        return "\(number)\(track.title) (\(timeLabel(track.duration)))"
    }

    private var info: some View {
        HStack(spacing: 5) {
            field(model.currentBitrate > 0 ? "\(model.currentBitrate)" : "", width: 36)
            Text("kbps")
            field(model.currentSampleRate > 0 ? "\(Int((model.currentSampleRate / 1000).rounded()))" : "", width: 26)
            Text("kHz")
            Spacer(minLength: 2)
            Text(s.mono).foregroundColor(model.currentChannels == 1 ? theme.foreground : theme.shadow)
            Text(s.stereo).foregroundColor(model.currentChannels >= 2 ? theme.foreground : theme.shadow)
        }
        // Подписи не переносятся и не обрезаются в узком окне.
        .lineLimit(1)
        .fixedSize()
        .font(.custom("Arial", size: 10).weight(.bold))
        .foregroundColor(theme.foreground)
    }

    private func field(_ text: String, width: CGFloat) -> some View {
        Text(text).font(.custom("Arial", size: 10)).foregroundColor(theme.foreground)
            .frame(width: width, height: 15).background(theme.background).retroBevel(theme, sunken: true)
    }

    // MARK: Кнопки

    private var nextTrackHelp: String {
        if let next = model.nextTrack { return s.nextTrack(next.title) }
        if model.shuffleEnabled && model.repeatMode == .queue && !model.queue.isEmpty { return s.nextShuffledCycle }
        return s.endOfQueue
    }

    private var controls: some View {
        HStack(spacing: 2) {
            Button { model.previous() } label: { Image(systemName: "backward.end.fill") }
                .disabled(model.current == nil).help(s.previousTrack)
            Button {
                if model.current == nil || !model.playing { model.toggle() }
            } label: { Image(systemName: "play.fill") }
                .help(s.play)
                .disabled(model.current == nil && model.displayedTracks.isEmpty)
            Button { if model.playing { model.toggle() } } label: { Image(systemName: "pause.fill") }
                .disabled(!model.playing).help(s.pause)
            Button { model.stop() } label: { Image(systemName: "stop.fill") }
                .disabled(model.current == nil).help(s.stop)
            Button { model.next() } label: { Image(systemName: "forward.end.fill") }
                .disabled(model.current == nil).help(nextTrackHelp)
            Spacer(minLength: 0)
            Button { model.shuffleEnabled.toggle() } label: {
                Image(systemName: "shuffle")
            }
            .buttonStyle(RetroButtonStyle(theme: theme, compact: true, width: 30, isOn: model.shuffleEnabled))
            .help(s.shuffle)
            .accessibilityLabel(s.shuffle)
            .accessibilityValue(model.shuffleEnabled ? s.on : s.off)
            Button {
                switch model.repeatMode {
                case .off: model.repeatMode = .queue
                case .queue: model.repeatMode = .track
                case .track: model.repeatMode = .off
                }
            } label: {
                Image(systemName: model.repeatMode == .track ? "repeat.1" : "repeat")
            }
            .buttonStyle(RetroButtonStyle(theme: theme, compact: true, width: 30, isOn: model.repeatMode != .off))
            .help("\(s.repeatLabel) — \(s.repeatModeName(model.repeatMode))")
            .accessibilityLabel(s.repeatLabel)
            .accessibilityValue(s.repeatModeName(model.repeatMode))
            // Эквалайзер у правого края; надпись синяя, когда он включён.
            Button { showEqualizer.toggle() } label: {
                Text("EQ").font(.custom("Arial", size: 11).weight(.bold))
                    .foregroundColor(model.equalizer.enabled ? theme.accent : theme.foreground)
            }
            .buttonStyle(RetroButtonStyle(theme: theme, compact: true, width: 30, isOn: showEqualizer))
            .help(s.eqHelp)
            .accessibilityLabel(s.eqHelp)
            .accessibilityValue(model.equalizer.enabled ? s.eqOn : "")
            .popover(isPresented: $showEqualizer, arrowEdge: .bottom) {
                EqualizerPanel(model: model, theme: theme)
            }
        }
        .font(.system(size: 10, weight: .bold))
        .buttonStyle(RetroButtonStyle(theme: theme, compact: true, width: 30))
    }
}

// MARK: - Элементы панели

/// Бегущая строка: прокручивается, только если текст не помещается.
private struct Marquee: View {
    let text: String
    private static let font = NSFont(name: "Arial", size: 12) ?? .systemFont(ofSize: 12)
    private var textWidth: CGFloat { (text as NSString).size(withAttributes: [.font: Self.font]).width }
    var body: some View {
        GeometryReader { geometry in
            let fits = textWidth + 12 <= geometry.size.width
            TimelineView(.animation(minimumInterval: 1 / 30, paused: fits)) { context in
                let gap: CGFloat = 40
                let cycle = textWidth + gap
                let shift = fits ? 0 : CGFloat(context.date.timeIntervalSinceReferenceDate * 28).truncatingRemainder(dividingBy: cycle)
                HStack(spacing: gap) {
                    label
                    if !fits { label }
                }
                .offset(x: 6 - shift)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            }
            .clipped()
        }
        .accessibilityElement().accessibilityLabel(text)
    }
    private var label: some View {
        Text(text).font(Font(Self.font)).foregroundColor(.black).lineLimit(1).fixedSize()
    }
}

/// Индикатор: высота столбиков следует реальной громкости левого/правого канала,
/// форма меняется во времени. Столбики собраны из тёмно-синих блоков,
/// как полоса прогресса Windows 95. Без воспроизведения столбики гаснут.
@MainActor
private struct SpectrumView: View {
    @ObservedObject var model: PlayerModel
    let theme: PlayerTheme
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20, paused: !model.playing)) { context in
            let (left, right) = model.meterLevels()
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = 19
                let step = size.width / CGFloat(count)
                for index in 0..<count {
                    let level = index < count / 2 ? left : right
                    let wave = 0.55 + 0.45 * sin(Double(index) * 1.9 + time * (5 + Double(index % 4)))
                    let tilt = 1 - Double(index) / Double(count) * 0.45
                    let blocks = Int((Double(size.height - 1) / 3 * min(1, level * wave * tilt * 1.15)).rounded())
                    for block in 0..<blocks {
                        let rect = CGRect(x: CGFloat(index) * step, y: size.height - 1 - CGFloat(block + 1) * 3,
                                          width: step - 2, height: 2)
                        canvas.fill(Path(rect), with: .color(theme.accent))
                    }
                }
                var baseline = Path()
                baseline.addRect(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1))
                canvas.fill(baseline, with: .color(theme.shadow))
            }
        }
        .accessibilityHidden(true)
    }
}
