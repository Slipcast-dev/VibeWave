import Foundation
import VibeWaveCore

/// Снимок текущего сеанса. Положение хранится в секундах, без признака
/// воспроизведения, поэтому восстановление всегда оставляет плеер на паузе.
struct PlaybackSession: Codable {
    var version = 1
    let current: Track
    let position: TimeInterval
    let queue: [Track]
    let openTracks: [Track]
    let source: PlaybackSource
    let librarySection: String?
    let shuffleOrder: ShuffleOrder?
}

struct PlaybackSessionStore {
    let url: URL

    func load() throws -> PlaybackSession? {
        do {
            let snapshot = try JSONDecoder().decode(PlaybackSession.self, from: Data(contentsOf: url))
            return snapshot.version == 1 ? snapshot : nil
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func save(_ session: PlaybackSession) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
    }

    func clear() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let failure as CocoaError where failure.code == .fileNoSuchFile { }
    }
}
