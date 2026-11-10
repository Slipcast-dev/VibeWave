import AVFoundation
import Foundation

/// Измерение BS.1770 для одного файла. Для альбомного расчёта сохраняются
/// энергии перекрывающихся окон, поэтому декодировать файлы повторно не нужно.
public struct LoudnessMeasurement: Sendable {
    public let loudness: Double?
    public let peak: Double
    public var gain: Double? { loudness.map { LoudnessAnalyzer.targetLoudness - $0 } }

    fileprivate let blockEnergies: [Double]
}

/// Потоковый анализ моно и стерео. Применяет K-взвешивание и два порога BS.1770.
/// Для ReplayGain используется цель −18 LUFS и пик дискретных отсчётов PCM.
public enum LoudnessAnalyzer {
    public enum Failure: Error {
        case unreadableFile, unsupportedPCMFormat, invalidSample, incompleteRead
    }

    fileprivate static let targetLoudness = -18.0
    private static let loudnessOffset = -0.691
    private static let absoluteGate = pow(10.0, (-70.0 - loudnessOffset) / 10.0)

    public static func analyze(_ url: URL, isCancelled: () -> Bool = { false }) throws -> LoudnessMeasurement {
        if isCancelled() { throw CancellationError() }
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, MusicFiles.isRegularFile(url) else { throw Failure.unreadableFile }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let rate = format.sampleRate
        guard (1...2).contains(format.channelCount), (8_000...384_000).contains(rate) else {
            throw Failure.unsupportedPCMFormat
        }
        let hopFrames = Int((rate / 10).rounded())
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hopFrames)),
              let channels = buffer.floatChannelData else { throw Failure.unsupportedPCMFormat }

        let shelf = Biquad.highShelf(sampleRate: rate)
        let highPass = Biquad.highPass(sampleRate: rate)
        var shelfStates = Array(repeating: Biquad.State(), count: Int(format.channelCount))
        var highPassStates = shelfStates
        var hopEnergy = 0.0
        var framesInHop = 0
        var recentHops = [Double](repeating: 0, count: 4)
        var hopCount = 0
        var blockEnergies: [Double] = []
        var peak = 0.0
        var remainingFrames = file.length
        while remainingFrames > 0 {
            if isCancelled() { throw CancellationError() }
            // AVAudioFile на macOS 13 выбрасывает ошибку при чтении после EOF.
            let requested = min(remainingFrames, AVAudioFramePosition(hopFrames - framesInHop))
            try file.read(into: buffer, frameCount: AVAudioFrameCount(requested))
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { throw Failure.incompleteRead }
            remainingFrames -= AVAudioFramePosition(frameCount)
            for channel in shelfStates.indices {
                let samples = channels[channel]
                var shelfState = shelfStates[channel]
                var highPassState = highPassStates[channel]
                for frame in 0..<frameCount {
                    let sample = Double(samples[frame])
                    guard sample.isFinite else { throw Failure.invalidSample }
                    peak = max(peak, abs(sample))
                    let weighted = highPassState.apply(highPass, to: shelfState.apply(shelf, to: sample))
                    hopEnergy += weighted * weighted
                }
                shelfStates[channel] = shelfState
                highPassStates[channel] = highPassState
            }
            framesInHop += frameCount
            if framesInHop == hopFrames {
                // 400 мс с перекрытием 75%. Неполное последнее окно не измеряем.
                recentHops[hopCount % recentHops.count] = hopEnergy
                hopCount += 1
                if hopCount >= recentHops.count {
                    blockEnergies.append(recentHops.reduce(0, +) / Double(hopFrames * recentHops.count))
                }
                hopEnergy = 0
                framesInHop = 0
            }
        }
        let loudness = try integratedLoudness([blockEnergies], isCancelled: isCancelled)
        return LoudnessMeasurement(loudness: loudness, peak: peak, blockEnergies: blockEnergies)
    }

    /// Альбомный порог считается по общему набору окон. Паузы между файлами
    /// не добавляются, для каждого файла сохраняются собственные усиление и пик.
    public static func replayGain(for tracks: [LoudnessMeasurement],
                                  isCancelled: () -> Bool = { false }) throws -> [ReplayGainValues] {
        let albumLoudness = try integratedLoudness(tracks.map(\.blockEnergies), isCancelled: isCancelled)
        let albumGain = albumLoudness.map { targetLoudness - $0 }
        let albumPeak = tracks.map(\.peak).max()
        return try tracks.map { track in
            if isCancelled() { throw CancellationError() }
            return ReplayGainValues(trackGain: track.gain, albumGain: albumGain,
                                    trackPeak: track.peak, albumPeak: albumPeak)
        }
    }

    private static func integratedLoudness(_ groups: [[Double]],
                                           isCancelled: () -> Bool) throws -> Double? {
        func averageEnergy(above gate: Double) throws -> Double? {
            if isCancelled() { throw CancellationError() }
            var count = 0
            var total = 0.0
            for blocks in groups {
                for (index, energy) in blocks.enumerated() {
                    if index % 1024 == 0, isCancelled() { throw CancellationError() }
                    guard energy > gate else { continue }
                    count += 1
                    total += energy
                }
            }
            return count == 0 ? nil : total / Double(count)
        }
        // Порог −70 LUFS, затем относительный порог на 10 LU ниже средней громкости.
        guard let absoluteAverage = try averageEnergy(above: absoluteGate),
              let relativeAverage = try averageEnergy(above: max(absoluteGate, absoluteAverage * 0.1))
        else { return nil }
        return loudnessOffset + 10 * log10(relativeAverage)
    }

    private struct Biquad {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double

        struct State {
            var first = 0.0
            var second = 0.0

            mutating func apply(_ filter: Biquad, to input: Double) -> Double {
                let output = filter.b0 * input + first
                first = filter.b1 * input - filter.a1 * output + second
                second = filter.b2 * input - filter.a2 * output
                return output
            }
        }

        // Параметры секций K-фильтра из реализации libebur128.
        // Билинейное преобразование воспроизводит эталонные коэффициенты ITU при 48 кГц.
        static func highShelf(sampleRate: Double) -> Self {
            let k = tan(.pi * 1681.974450955533 / sampleRate)
            let kSquared = k * k
            let kOverQ = k / 0.7071752369554196
            let high = pow(10.0, 3.999843853973347 / 20)
            let middle = pow(high, 0.4996667741545416)
            let a0 = 1 + kOverQ + kSquared
            return Self(b0: (high + middle * kOverQ + kSquared) / a0,
                        b1: 2 * (kSquared - high) / a0,
                        b2: (high - middle * kOverQ + kSquared) / a0,
                        a1: 2 * (kSquared - 1) / a0, a2: (1 - kOverQ + kSquared) / a0)
        }

        static func highPass(sampleRate: Double) -> Self {
            let k = tan(.pi * 38.13547087602444 / sampleRate)
            let kSquared = k * k
            let kOverQ = k / 0.5003270373238773
            let a0 = 1 + kOverQ + kSquared
            return Self(b0: 1, b1: -2, b2: 1,
                        a1: 2 * (kSquared - 1) / a0, a2: (1 - kOverQ + kSquared) / a0)
        }
    }
}
