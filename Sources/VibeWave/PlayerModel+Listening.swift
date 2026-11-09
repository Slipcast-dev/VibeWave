import Foundation
import VibeWaveCore

extension PlayerModel {
    func rate(_ track: Track, stars: Int) {
        var updated = listeningActivity
        updated.rate(track.url, stars: stars)
        saveListeningActivity(updated)
    }

    func clearListeningHistory() {
        var updated = listeningActivity
        updated.clearHistory()
        saveListeningActivity(updated)
    }

    func pruneListeningHistory() {
        var updated = listeningActivity
        updated.prune(at: Date(), retainingDays: listeningOptions.retentionDays)
        saveListeningActivity(updated)
    }

    func resumeListening(at position: Double) {
        guard listeningOptions.enabled else { return }
        listeningSession.resume(at: position, time: ProcessInfo.processInfo.systemUptime)
    }

    func sampleListening(at position: Double) {
        guard listeningOptions.enabled, let track = current else { return }
        guard listeningSession.sample(position: position, time: ProcessInfo.processInfo.systemUptime,
                                      duration: duration, threshold: Double(listeningOptions.thresholdSeconds)) else { return }
        var updated = listeningActivity
        updated.record(track, at: Date(), retainingDays: listeningOptions.retentionDays)
        saveListeningActivity(updated)
    }
}
