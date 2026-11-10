import Foundation
import VibeWaveCore

extension PlayerModel {
    var selectedSmart: SmartPlaylist? { smartPlaylists.first { $0.id == selectedID } }
    var hasSearch: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || searchFilter.isActive }
    var showsQueryResults: Bool { hasSearch || selectedSmart != nil }
    var displayedTracks: [Track] { showsQueryResults ? (queryReady ? queryResults.map(\.track) : []) : visibleTracks }

    func saveSmartPlaylist(_ list: SmartPlaylist) {
        guard list.query.isValid, !list.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = smartPlaylists.firstIndex(where: { $0.id == list.id }) { smartPlaylists[index] = list }
        else { smartPlaylists.append(list) }
        selectedID = list.id
        save()
    }

    func deleteSmartPlaylist(_ id: UUID) {
        smartPlaylists.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        save()
    }

    /// После редактирования файла или пересканирования папки перечитываем её метаданные.
    func invalidateQueryTags(for urls: [URL]) {
        for url in urls { queryTags.removeValue(forKey: url.standardizedFileURL) }
        scheduleQueries()
    }

    /// Один отложенный пересчёт после серии изменений. Отменённая работа
    /// не обновляет выдачу, а чтение файлов и сортировка идут вне главного потока.
    func scheduleQueries() {
        queryTask?.cancel()
        queryReady = false
        guard showsQueryResults || !smartPlaylists.isEmpty else { return }
        queryTask = Task<Void, Never> { @MainActor [weak self] in
            do { try await Task<Never, Never>.sleep(nanoseconds: 160_000_000) } catch { return }
            guard let self = self, !Task.isCancelled else { return }
            let activity = self.listeningActivity
            let lists = self.smartPlaylists
            let needsCatalog = self.isLibrarySelected || self.searchScope == .library || !lists.isEmpty
            let catalog: [LibraryEntry] = needsCatalog ? self.libraryEntries : []
            let section: [LibraryEntry] = self.isLibrarySelected ? catalog
                : self.visibleTracks.map { LibraryEntry(track: $0, sourceID: self.selectedID) }
            let activeList = self.selectedSmart?.id
            let search = self.hasSearch
            let options = self.searchOptions
            let scope = self.searchScope
            let text = self.searchText
            let cached = self.queryTags
            var filter = self.searchFilter
            if filter.sort == nil, filter.preservesInputOrder != true,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                filter.sort = options.sort
            }
            let query = filter
            let work = Task.detached(priority: .userInitiated) {
                () -> ([URL: [AudioTagField: String]], [UUID: Int], [QueryRecord]) in
                var tags: [URL: [AudioTagField: String]] = [:]
                func record(_ entry: LibraryEntry) -> QueryRecord {
                    let track = entry.track
                    let url = track.url.standardizedFileURL
                    let fields: [AudioTagField: String]
                    if let value = tags[url] ?? cached[url] {
                        fields = value
                    } else {
                        fields = (try? TrackTagAccess.withURL(track) {
                            try AudioMetadataFile.read($0, includeArtwork: false).fields
                        }) ?? [:]
                    }
                    tags[url] = fields
                    return QueryRecord(track: track, sourceID: entry.sourceID, tags: fields,
                                       rating: activity.rating(for: url), history: activity.summaries[url.path])
                }
                var records: [QueryRecord] = []
                for entry in catalog {
                    if Task.isCancelled { break }
                    records.append(record(entry))
                }
                let now = Date()
                var byList: [UUID: [QueryRecord]] = [:]
                for list in lists where !Task.isCancelled {
                    byList[list.id] = list.query.apply(to: records, now: now)
                }
                let base = activeList.flatMap { byList[$0] }
                let results: [QueryRecord]
                if search {
                    let candidates = scope == .library ? records : base ?? section.map(record)
                    results = query.apply(to: candidates, text: text, fields: options.fields, now: now)
                } else {
                    results = base ?? []
                }
                return (tags, byList.mapValues { $0.count }, results)
            }
            let (tags, counts, results) = await withTaskCancellationHandler(operation: { await work.value },
                                                                          onCancel: { work.cancel() })
            guard !Task.isCancelled else { return }
            self.queryTags = tags
            self.smartCounts = counts
            self.queryResults = results
            self.queryReady = true
        }
    }
}
