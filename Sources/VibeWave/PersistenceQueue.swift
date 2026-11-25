import Foundation
import os

/// Запись файлов состояния вне главного потока.
///
/// Все записи идут по одной последовательной очереди, поэтому файл никогда не пишется
/// параллельно. Запись откладывается на `delay`: серия быстрых изменений (перетаскивание,
/// пакетная правка, импорт) даёт одну запись последнего состояния, а не перекодирование
/// всей медиатеки на каждое изменение. `flush()` сразу выполняет отложенные записи
/// и дожидается их — перед чтением файлов и при выходе.
final class PersistenceQueue: Sendable {
    static let shared = PersistenceQueue()

    private struct Job: Sendable {
        let work: @Sendable () throws -> Void
        let onError: @Sendable (Error) -> Void
    }

    private let queue = DispatchQueue(label: "VibeWave.persistence", qos: .utility)
    private let pending = OSAllocatedUnfairLock(initialState: [URL: Job]())
    private let delay: TimeInterval

    init(delay: TimeInterval = 0.5) { self.delay = delay }

    func write(_ url: URL, onError: @escaping @Sendable (Error) -> Void,
               _ work: @escaping @Sendable () throws -> Void) {
        let alreadyQueued = pending.withLock { jobs in
            defer { jobs[url] = Job(work: work, onError: onError) }
            return jobs[url] != nil
        }
        guard !alreadyQueued else { return }
        queue.asyncAfter(deadline: .now() + delay) { [pending] in
            guard let job = pending.withLock({ $0.removeValue(forKey: url) }) else { return }
            Self.run(job)
        }
    }

    func flush() {
        queue.sync {
            let jobs = pending.withLock { jobs -> [Job] in
                defer { jobs.removeAll() }
                return Array(jobs.values)
            }
            jobs.forEach(Self.run)
        }
    }

    private static func run(_ job: Job) {
        do { try job.work() } catch { job.onError(error) }
    }
}
