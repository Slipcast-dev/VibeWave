import SwiftUI
import UniformTypeIdentifiers
import VibeWaveCore

extension UTType {
    static let vibeWaveTrack = UTType(exportedAs: "local.vibewave.track", conformingTo: .data)
}

/// Один обработчик для файлов Finder и записей внутри приложения.
/// Данные item provider загружаются асинхронно, модель меняется на главном потоке.
@MainActor
struct TrackDropDelegate: DropDelegate {
    let model: PlayerModel
    let playlistID: UUID?
    var before: UUID? = nil
    /// Перестановка в общем списке «Вся музыка» вместо переноса между источниками.
    var libraryReorder = false
    @Binding var targeted: Bool

    static let types = [UTType.vibeWaveTrack, .fileURL]

    func validateDrop(info: DropInfo) -> Bool {
        !model.importing && info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.itemProviders(for: Self.types).contains(where: DropReceiver.isInternal) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        return DropReceiver.receive(info.itemProviders(for: Self.types), model: model, playlistID: playlistID,
                                    before: before, libraryReorder: libraryReorder)
    }
}

/// Классификация опирается на реально объявленный тип provider, а не на
/// широкое сопоставление DropInfo, которое может вернуть файлы для custom UTI.
/// Этот же вход используется регрессионными тестами с настоящими providers.
@MainActor
enum DropReceiver {
    static func isInternal(_ provider: NSItemProvider) -> Bool {
        provider.registeredTypeIdentifiers.contains(UTType.vibeWaveTrack.identifier)
    }

    @discardableResult
    static func receive(_ providers: [NSItemProvider], model: PlayerModel, playlistID: UUID?, before: UUID? = nil,
                        libraryReorder: Bool = false) -> Bool {
        guard !model.importing else { return false }
        if let item = providers.first(where: isInternal) {
            item.loadDataRepresentation(forTypeIdentifier: UTType.vibeWaveTrack.identifier) { data, _ in
                guard let data = data, let payload = try? JSONDecoder().decode(TrackDragPayload.self, from: data) else {
                    DispatchQueue.main.async { model.error = "Не удалось прочитать перетаскиваемый трек." }
                    return
                }
                DispatchQueue.main.async {
                    if libraryReorder { model.moveInLibrary(payload.trackID, before: before) }
                    else { model.moveTrack(payload, to: playlistID, before: before) }
                }
            }
            return true
        }
        let items = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) && !isInternal($0) }
        guard !items.isEmpty else { return false }
        // Сохраняем порядок файлов, даже если providers завершаются в другом порядке.
        let batch = DroppedFileBatch(count: items.count)
        for (index, item) in items.enumerated() {
            batch.group.enter()
            item.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                var url: URL?
                if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else if let value = value as? URL { url = value }
                else if let value = value as? String { url = URL(string: value) }
                batch.set(url, at: index)
                batch.group.leave()
            }
        }
        batch.group.notify(queue: .global(qos: .userInitiated)) {
            let urls = batch.urls
            DispatchQueue.main.async { model.receiveFiles(urls, into: playlistID, before: before) }
        }
        return true
    }
}

/// Доступ к результатам параллельных callbacks защищён блокировкой.
private final class DroppedFileBatch: @unchecked Sendable {
    let group = DispatchGroup()
    private let lock = NSLock()
    private var results: [URL?]
    init(count: Int) { results = Array(repeating: nil, count: count) }
    func set(_ url: URL?, at index: Int) {
        lock.lock()
        defer { lock.unlock() }
        results[index] = url
    }
    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return results.compactMap { $0 }
    }
}

func trackProvider(_ track: Track, playlistID: UUID?) -> NSItemProvider {
    let data = try? JSONEncoder().encode(TrackDragPayload(playlistID: playlistID, trackID: track.id))
    let provider = NSItemProvider()
    provider.registerDataRepresentation(forTypeIdentifier: UTType.vibeWaveTrack.identifier, visibility: .ownProcess) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}
