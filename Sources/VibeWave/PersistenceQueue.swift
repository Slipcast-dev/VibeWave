import Foundation
import os

/// Запись файлов состояния вне главного потока.
///
/// Все записи идут по одной последовательной очереди, поэтому файл никогда не пишется
/// параллельно. Для одного адреса ещё не начатая запись заменяется новой: серия быстрых
/// изменений (перетаскивание, пакетная правка) даёт одну запись последнего состояния.
/// `flush()` дожидается всех поставленных записей — перед чтением файлов и при выходе.
final class PersistenceQueue: Sendable {
    static let shared = PersistenceQueue()

    private struct Job: Sendable {
        let work: @Sendable () throws -> Void
        let onError: @Sendable (Error) -> Void
    }

    private let queue = DispatchQueue(label: "VibeWave.persistence", qos: .utility)
    private let pending = OSAllocatedUnfairLock(initialState: [URL: Job]())

    func write(_ url: URL, onError: @escaping @Sendable (Error) -> Void,
               _ work: @escaping @Sendable () throws -> Void) {
        let alreadyQueued = pending.withLock { jobs in
            defer { jobs[url] = Job(work: work, onError: onError) }
            return jobs[url] != nil
        }
        guard !alreadyQueued else { return }
        queue.async { [pending] in
            guard let job = pending.withLock({ $0.removeValue(forKey: url) }) else { return }
            do { try job.work() } catch { job.onError(error) }
        }
    }

    func flush() { queue.sync {} }
}
