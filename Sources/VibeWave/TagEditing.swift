import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import VibeWaveCore

struct TagEditorRequest: Identifiable {
    let id = UUID()
    let tracks: [Track]
}

enum TrackTagAccess {
    static func withURL<T>(_ track: Track, _ body: (URL) throws -> T) throws -> T {
        let url: URL
        if let bookmark = track.bookmark {
            var stale = false
            url = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        } else {
            url = track.url
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard MusicFiles.isRegularFile(url) else { throw CocoaError(.fileReadNoSuchFile) }
        return try body(url)
    }

    static func message(_ error: Error, strings: Strings) -> String {
        switch error as? AudioMetadataFile.Failure {
        case .unsupportedLayout: return strings.tagsUnsupported
        case .damaged: return strings.tagsDamaged
        case .tooLarge: return strings.tagsTooLarge
        case .changedDuringWrite: return strings.tagsChanged
        case .readOnly: return strings.tagsReadOnly
        case .invalidField(let field): return strings.invalidTagField(strings.tagFieldName(field))
        case nil: return error.localizedDescription
        }
    }

    /// Сначала проверяем размер и тип изображения. ImageIO извлекает размеры
    /// и делает маленькое превью без декодирования полноразмерной картинки в интерфейсе.
    static func importArtwork(_ url: URL) throws -> AudioArtwork {
        guard MusicFiles.isRegularFile(url) else { throw CocoaError(.fileReadNoSuchFile) }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        guard let data = try input.read(upToCount: AudioArtwork.maximumSize + 1),
              data.count <= AudioArtwork.maximumSize,
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(image),
              let type = UTType(identifier as String), type == .jpeg || type == .png,
              let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 25_000_000,
              thumbnail(data) != nil else { throw AudioMetadataFile.Failure.tooLarge }
        return AudioArtwork(data: data, mime: type == .jpeg ? "image/jpeg" : "image/png",
                            width: UInt32(width), height: UInt32(height))
    }

    static func thumbnail(_ data: Data) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 160
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...8192).contains(width), (1...8192).contains(height), width * height <= 25_000_000 else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private struct UpdatedTrackTags: Sendable {
    let track: Track
    let url: URL
    let bookmark: Data?
    let title: String?
}

extension PlayerModel {
    func editTags(for tracks: [Track]) {
        var paths = Set<URL>()
        let unique = tracks.filter { paths.insert($0.url.standardizedFileURL).inserted }
        guard !unique.isEmpty, !writingTags else { return }
        tagEditorRequest = TagEditorRequest(tracks: unique)
    }

    /// Все операции в пакете идут по одной. Отмена действует между файлами,
    /// поэтому успешные записи остаются сохранёнными даже при частичной ошибке.
    func writeTags(_ edit: AudioTagEdit, tracks: [Track], job: ImportJob,
                   progress: @escaping (Int) -> Void, completion: @escaping ([String], Int) -> Void) {
        guard !writingTags, !edit.isEmpty, !tracks.isEmpty else { completion([], 0); return }
        writingTags = true
        let strings = strings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var updates: [UpdatedTrackTags] = []
            var failures: [String] = []
            for (index, track) in tracks.enumerated() {
                if job.isCancelled { break }
                do {
                    let updated = try TrackTagAccess.withURL(track) { url in
                        _ = try AVAudioFile(forReading: url)
                        let result = try AudioMetadataFile.write(edit, to: url)
                        let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                            relativeTo: nil)
                        let title = edit.fields[.title].map { _ in
                            result.fields[.title] ?? url.deletingPathExtension().lastPathComponent
                        }
                        return UpdatedTrackTags(track: track, url: url, bookmark: bookmark, title: title)
                    }
                    updates.append(updated)
                } catch {
                    failures.append("\(track.title): \(TrackTagAccess.message(error, strings: strings))")
                }
                if job.shouldReport(final: index + 1 == tracks.count) {
                    DispatchQueue.main.async { progress(index + 1) }
                }
            }
            let written = updates
            let errors = failures
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.writingTags = false
                self.applyTagUpdates(written)
                completion(errors, written.count)
            }
        }
    }

    private func applyTagUpdates(_ updates: [UpdatedTrackTags]) {
        guard !updates.isEmpty else { return }
        var byPath: [URL: UpdatedTrackTags] = [:]
        for update in updates {
            byPath[update.track.url.standardizedFileURL] = update
            byPath[update.url.standardizedFileURL] = update
        }
        func refresh(_ track: Track) -> Track {
            guard let update = byPath[track.url.standardizedFileURL] else { return track }
            var changed = track
            changed.url = update.url
            changed.bookmark = update.bookmark
            if let title = update.title { changed.title = title }
            return changed
        }
        for index in playlists.indices { playlists[index].tracks = playlists[index].tracks.map(refresh) }
        for index in folders.indices { folders[index].tracks = folders[index].tracks.map(refresh) }
        openTracks = openTracks.map(refresh)
        if let current = current { self.current = refresh(current) }
        invalidateQueryTags(for: updates.flatMap { [$0.track.url, $0.url] })
        refreshPlaybackQueue()
        save()
    }
}
