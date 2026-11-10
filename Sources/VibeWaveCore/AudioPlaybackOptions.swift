import Foundation

public enum ReplayGainMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case off, track, album
    public var id: Self { self }
}

public struct AudioPlaybackOptions: Codable, Equatable, Sendable {
    public var replayGain: ReplayGainMode = .off
    public var preamp = 0.0
    public var missingGain = 0.0
    public var preventClipping = true
    public var gapless = false
    public var crossfade = 0.0
    public var preserveAlbums = true

    public init() {}

    public var usesTransitions: Bool { gapless || crossfade > 0 }

    public mutating func validate() {
        preamp = preamp.isFinite ? min(12, max(-12, preamp)) : 0
        missingGain = missingGain.isFinite ? min(12, max(-24, missingGain)) : 0
        crossfade = crossfade.isFinite ? min(12, max(0, crossfade)) : 0
    }

    /// Ограничение по sample peak оставляет запас на подъём полос EQ.
    /// Оценка не является ограничителем межсэмпловых пиков.
    public func gain(_ values: ReplayGainValues, equalizer: EqualizerSettings) -> Double {
        guard replayGain != .off else { return 0 }
        let album = replayGain == .album && values.albumGain != nil
        let correction = (album ? values.albumGain : values.trackGain) ?? missingGain
        var db = correction + preamp
        if preventClipping {
            let peak = (album ? values.albumPeak : values.trackPeak) ?? values.trackPeak ?? 1
            let headroom = equalizer.enabled
                ? Double(max(0, equalizer.preamp + equalizer.gains.reduce(0) { $0 + max(0, $1) })) : 0
            if peak.isFinite && peak > 0 { db = min(db, -20 * log10(peak) - headroom) }
        }
        return min(24, max(-96, db))
    }
}
