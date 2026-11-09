import Foundation
import VibeWaveCore

/// Плейлисты, папки и перестановка треков. Все изменения сохраняются сразу,
/// кроме временной очереди вне плейлистов.
extension PlayerModel {
    func createPlaylist(_ name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let playlist = Playlist(name: value)
        playlists.append(playlist)
        selectedID = playlist.id
        save()
    }

    func renamePlaylist(_ id: UUID, name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = value
        save()
    }

    func deletePlaylist(_ id: UUID) {
        playlists.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        refreshPlaybackQueue()
        save()
    }

    func removeFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        if let current = current, playbackTracks?.contains(where: { $0.id == current.id }) != true { stop() }
        else { refreshPlaybackQueue() }
        save()
    }

    /// Явный источник нужен для постоянного списка очереди при просмотре плейлиста.
    func removeTrack(_ id: UUID, from sourceID: UUID?) {
        guard var tracks = tracks(in: sourceID) else { return }
        tracks.removeAll { $0.id == id }
        replaceTracks(tracks, in: sourceID)
        if current?.id == id, playbackTracks?.contains(where: { $0.id == id }) != true { stop() }
        else { refreshPlaybackQueue() }
        if sourceID != nil { save() }
    }

    /// Перестановка в общем списке «Вся музыка» без группировки.
    func moveInLibrary(_ id: UUID, before destination: UUID?) {
        guard let order = ManualOrder.move(id, before: destination, in: libraryEntries.map(\.id)) else { return }
        libraryOrder = order
        refreshPlaybackQueue()
        save()
    }

    func moveInLibraryBy(_ id: UUID, offset: Int) {
        let ids = libraryEntries.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset), offset != 0 else { return }
        let target = index + offset
        moveInLibrary(id, before: offset < 0 ? ids[target] : (target + 1 < ids.count ? ids[target + 1] : nil))
    }

    func moveTrackBy(_ id: UUID, in sourceID: UUID?, offset: Int) {
        guard let tracks = tracks(in: sourceID), let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard tracks.indices.contains(target), target != index else { return }
        let destination = offset < 0 ? tracks[target].id : (target + 1 < tracks.count ? tracks[target + 1].id : nil)
        moveTrack(TrackDragPayload(playlistID: sourceID, trackID: id), to: sourceID, before: destination)
    }

    /// Внутри одного раздела меняется порядок. Между плейлистами трек переносится.
    /// Из очереди и папок трек копируется; в папку извне ничего не добавляется.
    func moveTrack(_ payload: TrackDragPayload, to targetID: UUID?, before destination: UUID?) {
        guard payload.playlistID == targetID || !isFolder(targetID),
              var source = tracks(in: payload.playlistID),
              var target = tracks(in: targetID),
              let track = source.first(where: { $0.id == payload.trackID }),
              destination == nil || target.contains(where: { $0.id == destination }) else { return }
        if payload.playlistID == targetID {
            guard track.id != destination else { return }
            source.removeAll { $0.id == track.id }
            let index = destination.flatMap { id in source.firstIndex { $0.id == id } } ?? source.endIndex
            source.insert(track, at: index)
            replaceTracks(source, in: targetID)
        } else {
            guard !target.contains(where: { $0.url.standardizedFileURL == track.url.standardizedFileURL }) else { return }
            // Сохранённые плейлисты не теряют записи при копировании в очередь.
            let movingBetweenPlaylists = isPlaylist(payload.playlistID) && isPlaylist(targetID)
            if movingBetweenPlaylists {
                source.removeAll { $0.id == track.id }
                replaceTracks(source, in: payload.playlistID)
            }
            let index = destination.flatMap { id in target.firstIndex { $0.id == id } } ?? target.endIndex
            target.insert(track, at: index)
            replaceTracks(target, in: targetID)
            if movingBetweenPlaylists && playbackSource == .container(payload.playlistID) && current?.id == track.id {
                playbackSource = .container(targetID)
            }
        }
        refreshPlaybackQueue()
        if payload.playlistID != nil || targetID != nil { save() }
    }
}
