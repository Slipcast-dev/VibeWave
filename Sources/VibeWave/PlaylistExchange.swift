import AppKit
import UniformTypeIdentifiers
import VibeWaveCore

extension PlaylistFileFormat {
    var contentType: UTType { UTType(filenameExtension: rawValue, conformingTo: .data) ?? .data }
}

extension PlaylistFile.Failure {
    func message(_ strings: Strings) -> String {
        switch self {
        case .invalidFormat: return strings.invalidPlaylistFile
        case .invalidEncoding: return strings.invalidPlaylistEncoding
        case .streamingManifest: return strings.unsupportedPlaylistStream
        case .tooLarge: return strings.playlistFileTooLarge
        case .unsupportedPath: return strings.unsupportedPlaylistPath
        case .lossyEncoding: return strings.lossyPlaylistEncoding
        }
    }
}

struct PlaylistImportResult: Sendable {
    var playlists: [Playlist] = []
    var failures: [String] = []

    /// Каждый исходный файл становится самостоятельным списком. При отмене
    /// ни один результат не попадёт в библиотеку.
    mutating func read(_ url: URL, options: PlaylistFileOptions, strings: Strings,
                       job: ImportJob, progress: MediaScanner.Progress) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        do {
            guard MusicFiles.isRegularFile(url) else { throw CocoaError(.fileReadUnsupportedScheme) }
            let entries = try PlaylistFile.read(url, legacyEncoding: options.legacyImportEncoding)
            var candidates: [URL] = []
            var titles: [URL: String] = [:]
            var seen = Set<URL>()
            for entry in entries {
                if job.isCancelled { throw CancellationError() }
                guard let file = PlaylistFile.localURL(for: entry, in: url) else {
                    failures.append("\(name): \(strings.unsupportedPlaylistPath) \(entry.path)")
                    continue
                }
                guard seen.insert(file.resolvingSymlinksInPath()).inserted else { continue }
                guard Track.accepts(file) else {
                    failures.append("\(name): \(strings.errorNoSupportedFiles) \(file.lastPathComponent)")
                    continue
                }
                guard MusicFiles.isRegularFile(file) else {
                    if options.reportMissingFiles {
                        failures.append("\(name): \(strings.missingPlaylistFile) \(file.lastPathComponent)")
                    }
                    continue
                }
                candidates.append(file)
                if let title = entry.title, !title.trimmingCharacters(in: .whitespaces).isEmpty { titles[file] = title }
            }
            let batch = try MediaScanner.readTracks(candidates, job: job, progress: progress)
            failures += batch.failures
            if entries.isEmpty || !batch.tracks.isEmpty {
                let tracks = batch.tracks.map { track -> Track in
                    var copy = track
                    if let title = titles[track.url] { copy.title = title }
                    return copy
                }
                playlists.append(Playlist(name: name, tracks: tracks))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let message = (error as? PlaylistFile.Failure)?.message(strings) ?? error.localizedDescription
            failures.append("\(url.lastPathComponent): \(message)")
        }
    }
}

extension PlayerModel {
    func choosePlaylistFiles() {
        guard !importing else { return }
        let panel = NSOpenPanel()
        panel.title = strings.importPlaylistFile
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = PlaylistFileFormat.allCases.map(\.contentType)
        if panel.runModal() == .OK { receiveFiles(panel.urls) }
    }

    func choosePlaylistExport() {
        guard let playlist = selected else { return }
        let dialog = PlaylistExportDialog(options: playlistFileOptions, strings: strings)
        guard let (destination, options) = dialog.choose(name: playlist.name) else { return }
        exportPlaylist(playlist, to: destination, options: options)
    }

    func exportPlaylist(_ playlist: Playlist, to destination: URL, options: PlaylistFileOptions) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try PlaylistFile.encode(playlist.tracks, destination: destination, options: options)
                try data.write(to: destination, options: .atomic)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    let reason = (error as? PlaylistFile.Failure)?.message(self.strings) ?? error.localizedDescription
                    self.error = "\(self.strings.exportPlaylistFile)\n\(reason)"
                }
            }
        }
    }
}

/// Формат меняет допустимое расширение до подтверждения сохранения.
/// Параметры конкретного экспорта не меняют глобальные настройки.
@MainActor
private final class PlaylistExportDialog: NSObject {
    private let panel = NSSavePanel()
    private let formatPicker = NSPopUpButton()
    private let relative: NSButton
    private var options: PlaylistFileOptions
    private let strings: Strings

    init(options: PlaylistFileOptions, strings: Strings) {
        self.options = options
        self.strings = strings
        relative = NSButton(checkboxWithTitle: strings.playlistRelativePaths, target: nil, action: nil)
        super.init()
    }

    func choose(name: String) -> (URL, PlaylistFileOptions)? {
        panel.title = strings.exportPlaylistFile
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = name.replacingOccurrences(of: "/", with: "-") + "." + options.format.rawValue
        panel.isExtensionHidden = false
        formatPicker.addItems(withTitles: PlaylistFileFormat.allCases.map(\.label))
        formatPicker.selectItem(withTitle: options.format.label)
        formatPicker.target = self
        formatPicker.action = #selector(changeFormat)
        relative.state = options.relativePaths ? .on : .off
        let formatRow = NSStackView(views: [NSTextField(labelWithString: strings.playlistExportFormat), formatPicker])
        formatRow.spacing = 8
        let accessory = NSStackView(views: [formatRow, relative])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory
        changeFormat()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        options.relativePaths = relative.state == .on
        return (url, options)
    }

    @objc private func changeFormat() {
        options.format = PlaylistFileFormat.allCases[formatPicker.indexOfSelectedItem]
        panel.allowedContentTypes = [options.format.contentType]
        let currentName = panel.nameFieldStringValue as NSString
        if currentName.pathExtension.lowercased() != options.format.rawValue {
            let base = PlaylistFileFormat(rawValue: currentName.pathExtension.lowercased()) == nil
                ? String(currentName) : currentName.deletingPathExtension
            panel.nameFieldStringValue = base + "." + options.format.rawValue
        }
    }
}
