import Foundation
import UniformTypeIdentifiers

/// Реестр контейнеров локального аудио. Расширение выбирает кандидата,
/// а пригодность конкретного потока определяет системный декодер.
public enum AudioFormat: String, CaseIterable, Identifiable, Sendable {
    case mp3, flac, wave, wave64, aiff, adts, mpeg4, caf, au

    public var id: Self { self }

    public var name: String {
        switch self {
        case .mp3: return "MP3"
        case .flac: return "FLAC"
        case .wave: return "WAV"
        case .wave64: return "Wave64"
        case .aiff: return "AIFF / AIFF-C"
        case .adts: return "AAC / ADTS"
        case .mpeg4: return "MPEG-4 Audio"
        case .caf: return "CAF"
        case .au: return "AU / SND"
        }
    }

    public var fileExtensions: [String] {
        switch self {
        case .mp3: return ["mp3"]
        case .flac: return ["flac"]
        case .wave: return ["wav", "wave"]
        case .wave64: return ["w64"]
        case .aiff: return ["aif", "aiff", "aifc"]
        case .adts: return ["aac", "adts"]
        case .mpeg4: return ["m4a", "m4b", "m4r"]
        case .caf: return ["caf"]
        case .au: return ["au", "snd"]
        }
    }

    public var readsTags: Bool { writesTags || self == .mpeg4 }
    public var writesTags: Bool { self == .mp3 || self == .flac }

    public var contentTypes: [UTType] {
        fileExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    private static let byExtension = Dictionary(uniqueKeysWithValues: allCases.flatMap { format in
        format.fileExtensions.map { ($0, format) }
    })

    public init?(url: URL) {
        guard url.isFileURL, let format = Self.byExtension[url.pathExtension.lowercased()] else { return nil }
        self = format
    }
}
