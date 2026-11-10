import Foundation

/// Режим повтора определяет поведение на границе трека или очереди.
public enum RepeatMode: String, CaseIterable {
    case off, queue, track
}

/// Случайный порядок хранится отдельно от ручного порядка плейлиста.
/// Возврат назад воспроизводит пройденные переходы и сохраняет ещё не сыгранные треки.
public struct ShuffleOrder: Codable {
    private var past: [UUID] = []
    private var forward: [UUID] = []
    private var pending: ArraySlice<UUID> = []
    private var members: Set<UUID> = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case past, forward, pending, members }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        past = try container.decode([UUID].self, forKey: .past)
        forward = try container.decode([UUID].self, forKey: .forward)
        pending = try container.decode([UUID].self, forKey: .pending)[...]
        members = try container.decode(Set<UUID>.self, forKey: .members)
    }

    /// ArraySlice нужен для дешёвого извлечения начала очереди в памяти.
    /// В файл попадают только ещё не проигранные элементы среза.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(past, forKey: .past)
        try container.encode(forward, forKey: .forward)
        try container.encode(Array(pending), forKey: .pending)
        try container.encode(members, forKey: .members)
    }

    public var next: UUID? { forward.last ?? pending.first }

    /// Ручной выбор трека или включение перемешивания начинает новый цикл с текущей записи.
    public mutating func reset(_ ids: [UUID], startingAt current: UUID) {
        past.removeAll()
        forward.removeAll()
        members = Set(ids)
        pending = Array(members.subtracting([current])).shuffled()[...]
    }

    /// Удалённые записи выбывают из всех списков. Новые добавляются к оставшейся части цикла.
    /// Перестановка в плейлисте не сбрасывает уже выбранный случайный порядок.
    public mutating func update(_ ids: [UUID], current: UUID) {
        let updated = Set(ids)
        let removed = members.subtracting(updated)
        if !removed.isEmpty {
            past.removeAll(where: removed.contains)
            forward.removeAll(where: removed.contains)
            pending.removeAll(where: removed.contains)
        }
        pending.append(contentsOf: updated.subtracting(members).subtracting([current]).shuffled())
        members = updated
    }

    /// На границе цикла избегаем двух одинаковых треков подряд, если есть выбор.
    public mutating func advance(from current: UUID, repeatingQueue: Bool) -> UUID? {
        if next == nil, repeatingQueue {
            var cycle = Array(members).shuffled()
            if cycle.count > 1, cycle.first == current { cycle.swapAt(0, 1) }
            pending = cycle[...]
        }
        guard let next = forward.popLast() ?? pending.popFirst() else { return nil }
        if next != current, members.contains(current) { past.append(current) }
        return next
    }

    public mutating func retreat(from current: UUID) -> UUID? {
        guard let previous = past.popLast() else { return nil }
        if members.contains(current) { forward.append(current) }
        return previous
    }
}
