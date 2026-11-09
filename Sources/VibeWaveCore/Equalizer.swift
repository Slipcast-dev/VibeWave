import Foundation

/// Готовые настройки эквалайзера. Названия на языке интерфейса — в `Strings.eqPresetName`.
public enum EqualizerPreset: String, CaseIterable, Sendable {
    case flat, rock, pop, jazz, classical, dance, bassBoost, trebleBoost, vocal

    /// Усиление по полосам `EqualizerSettings.frequencies`, дБ.
    public var gains: [Float] {
        switch self {
        case .flat: return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case .rock: return [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]
        case .pop: return [-1, 1, 3, 4, 4, 2, 0, -1, -1, -1]
        case .jazz: return [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]
        case .classical: return [4, 3, 2, 1, 0, 0, 0, 1, 2, 3]
        case .dance: return [6, 5, 3, 0, 0, -2, -2, 0, 3, 4]
        case .bassBoost: return [7, 6, 5, 3, 1, 0, 0, 0, 0, 0]
        case .trebleBoost: return [0, 0, 0, 0, 0, 1, 3, 5, 6, 7]
        case .vocal: return [-2, -2, -1, 1, 4, 4, 3, 1, 0, -1]
        }
    }

    /// Предусиление: пресеты с сильным подъёмом немного снижают общий уровень, чтобы не было перегрузки.
    public var preamp: Float {
        switch self {
        case .rock: return -2
        case .dance, .classical: return -3
        case .bassBoost, .trebleBoost: return -4
        case .flat, .pop, .jazz, .vocal: return 0
        }
    }
}

/// Настройки 10-полосного эквалайзера. Значения всегда в допустимых пределах:
/// инициализатор и декодирование приводят их к диапазону.
public struct EqualizerSettings: Codable, Equatable, Sendable {
    /// Центральные частоты полос, Гц.
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// Подписи полос под ползунками.
    public static let bandLabels = ["32", "64", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]
    /// Допустимое усиление полосы и предусиления, дБ.
    public static let gainRange: ClosedRange<Float> = -12...12

    public var enabled: Bool
    public var preamp: Float {
        didSet { preamp = Self.clamp(preamp) }
    }
    public var gains: [Float] {
        didSet { gains = Self.normalize(gains) }
    }

    public init(enabled: Bool = false, preamp: Float = 0, gains: [Float] = EqualizerPreset.flat.gains) {
        self.enabled = enabled
        self.preamp = Self.clamp(preamp)
        self.gains = Self.normalize(gains)
    }

    public init(preset: EqualizerPreset, enabled: Bool = true) {
        self.init(enabled: enabled, preamp: preset.preamp, gains: preset.gains)
    }

    /// Пресет, с которым точно совпадают текущие значения; nil — свои настройки.
    public var preset: EqualizerPreset? {
        EqualizerPreset.allCases.first { $0.gains == gains && $0.preamp == preamp }
    }

    private enum CodingKeys: String, CodingKey { case enabled, preamp, gains }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  preamp: try container.decodeIfPresent(Float.self, forKey: .preamp) ?? 0,
                  gains: try container.decodeIfPresent([Float].self, forKey: .gains) ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(preamp, forKey: .preamp)
        try container.encode(gains, forKey: .gains)
    }

    private static func clamp(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(gainRange.upperBound, max(gainRange.lowerBound, value))
    }

    /// Ровно одно значение на полосу: лишние отбрасываются, недостающие равны 0 дБ.
    private static func normalize(_ values: [Float]) -> [Float] {
        let count = frequencies.count
        let fixed = values.prefix(count).map(clamp)
        return fixed + Array(repeating: 0, count: count - fixed.count)
    }
}
