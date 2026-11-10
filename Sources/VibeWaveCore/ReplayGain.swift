import Foundation

/// Четыре независимых поля ReplayGain. Усиление задаётся в дБ,
/// пик — линейным отношением к полной шкале, где 1.0 соответствует 0 dBFS.
public struct ReplayGainValues: Codable, Equatable, Sendable {
    public var trackGain: Double?
    public var albumGain: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?

    public init(trackGain: Double? = nil, albumGain: Double? = nil,
                trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.trackGain = trackGain
        self.albumGain = albumGain
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }

    public var isEmpty: Bool { trackGain == nil && albumGain == nil && trackPeak == nil && albumPeak == nil }

    /// Защита от некорректных значений из файлов и локального кэша.
    public var isValid: Bool {
        [trackGain, albumGain].allSatisfy { $0.map(Self.validGain) ?? true } &&
            [trackPeak, albumPeak].allSatisfy { $0.map(Self.validPeak) ?? true }
    }

    private static func validGain(_ value: Double) -> Bool {
        value.isFinite && (-120...120).contains(value)
    }

    private static func validPeak(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    enum Tag: String, CaseIterable {
        case trackGain = "REPLAYGAIN_TRACK_GAIN"
        case albumGain = "REPLAYGAIN_ALBUM_GAIN"
        case trackPeak = "REPLAYGAIN_TRACK_PEAK"
        case albumPeak = "REPLAYGAIN_ALBUM_PEAK"

        var isGain: Bool { self == .trackGain || self == .albumGain }
    }

    subscript(tag: Tag) -> Double? {
        get {
            switch tag {
            case .trackGain: return trackGain
            case .albumGain: return albumGain
            case .trackPeak: return trackPeak
            case .albumPeak: return albumPeak
            }
        }
        set {
            switch tag {
            case .trackGain: trackGain = newValue
            case .albumGain: albumGain = newValue
            case .trackPeak: trackPeak = newValue
            case .albumPeak: albumPeak = newValue
            }
        }
    }

    /// Учитываем первую корректную запись, даже если дубликат выше повреждён.
    mutating func readTag(_ name: String, value: String) {
        guard let tag = Tag(rawValue: name.uppercased()), self[tag] == nil else { return }
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.isGain && text.lowercased().hasSuffix("db") {
            text = text.dropLast(2).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let number = Double(text),
              tag.isGain ? Self.validGain(number) : Self.validPeak(number) else { return }
        self[tag] = number
    }

    func tagValue(_ tag: Tag) -> String? {
        guard let value = self[tag] else { return nil }
        // Swift форматирует Double независимо от языка интерфейса и сохраняет
        // точное значение при цикле записи и повторного чтения.
        return String(value) + (tag.isGain ? " dB" : "")
    }
}
