import Foundation
import MetricKit
import os

/// Локальная диагностика сбоев. MetricKit при следующем запуске передаёт отчёты
/// о падениях, зависаниях главного потока, превышении CPU и записи на диск.
/// Отчёты только сохраняются в `~/Library/Logs/VibeWave/Diagnostics` и никуда не отправляются;
/// пользователь может приложить их к сообщению об ошибке, предварительно проверив пути.
final class DiagnosticsRecorder: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsRecorder()
    /// Хранятся последние отчёты: старые удаляются, чтобы папка не росла.
    static let keptReports = 20

    let directory: URL
    private let logger = Logger(subsystem: "local.vibewave.player", category: "diagnostics")

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/VibeWave/Diagnostics", isDirectory: true)) {
        self.directory = directory
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads { store(payload.jsonRepresentation(), date: payload.timeStampEnd) }
    }

    func store(_ report: Data, date: Date) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let stamp = ISO8601DateFormatter().string(from: date).replacingOccurrences(of: ":", with: "-")
            let file = directory.appendingPathComponent("diagnostic-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try report.write(to: file, options: .atomic)
            logger.notice("Saved diagnostic report \(file.lastPathComponent, privacy: .public)")
            try prune()
        } catch {
            logger.error("Could not save diagnostic report: \(error.localizedDescription)")
        }
    }

    private func prune() throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.dropFirst(Self.keptReports) { try? FileManager.default.removeItem(at: file) }
    }
}
