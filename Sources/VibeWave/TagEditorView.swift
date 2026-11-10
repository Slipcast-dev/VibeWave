import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VibeWaveCore

/// В пакетном режиме меняются только поля с флажком. Снятие флажка
/// отменяет правку, а явно сохранённое пустое поле удаляет тег.
@MainActor
struct TagEditorView: View {
    let model: PlayerModel
    let tracks: [Track]
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var languages = LanguageSettings.shared
    @State private var selected: Set<UUID>
    @State private var loaded: [UUID: [AudioTagField: String]] = [:]
    @State private var failed: Set<UUID> = []
    @State private var edits = AudioTagEdit()
    @State private var preview: NSImage?
    @State private var reading = true
    @State private var readingArtwork = false
    @State private var job: ImportJob?
    @State private var cancelled = false
    @State private var progress = 0
    @State private var total = 0
    @State private var message: String?
    @State private var confirmingSave = false
    @ObservedObject private var preferences = SettingsPreferences.shared
    private var s: Strings { languages.strings }

    init(model: PlayerModel, tracks: [Track]) {
        self.model = model
        self.tracks = tracks
        _selected = State(initialValue: Set(tracks.map(\.id)))
    }

    private func isWritable(_ track: Track) -> Bool { AudioFormat(url: track.url)?.writesTags == true }

    private var selection: [Track] {
        tracks.filter { selected.contains($0.id) && !failed.contains($0.id) && (tracks.count == 1 || isWritable($0)) }
    }

    private var canWrite: Bool { selection.contains(where: isWritable) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tracks.count == 1 ? s.trackInfo : s.batchTags).font(.headline)
            if tracks.count == 1, let track = tracks.first {
                Text(track.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(tracks) { track in
                            Toggle(track.title, isOn: Binding(get: { selected.contains(track.id) }, set: { value in
                                if value { selected.insert(track.id) } else { selected.remove(track.id) }
                            }))
                            .lineLimit(1)
                            .disabled(failed.contains(track.id) || !isWritable(track))
                        }
                    }
                }
                .frame(height: 104)
            }

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AudioTagField.allCases) { field in fieldRow(field) }
                }
                VStack(spacing: 6) {
                    if let preview = preview {
                        Image(nsImage: preview).resizable().scaledToFit()
                            .frame(width: 104, height: 104).accessibilityLabel(s.trackArtwork)
                    } else {
                        Image(systemName: "photo").font(.system(size: 32)).foregroundColor(.secondary)
                            .frame(width: 104, height: 104).accessibilityLabel(s.trackArtwork)
                    }
                    if canWrite {
                        Button(s.chooseArtwork) { chooseArtwork() }
                        Button(s.removeArtwork) { preview = nil; edits.artwork = .remove }
                    }
                }
                .frame(minWidth: 125)
            }
            .disabled(reading || job != nil || selection.isEmpty)

            if canWrite { Text(s.tagEditHelp).font(.caption).foregroundColor(.secondary) }
            if tracks.contains(where: { AudioFormat(url: $0.url)?.readsTags == true && !isWritable($0) }) {
                Text(s.tagsViewOnly).font(.caption).foregroundColor(.secondary)
            }
            if !failed.isEmpty { Text(s.tagsUnreadableCount(failed.count)).font(.caption) }
            if let message = message {
                ScrollView { Text(message).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 65)
            }
            HStack {
                if reading || readingArtwork { ProgressView().controlSize(.small) }
                if job != nil { Text(s.progressCount(s.save, progress, total)).font(.caption) }
                Spacer()
                Button(job == nil ? s.cancel : s.stopTagWrite) {
                    if let job = job { job.cancel(); cancelled = true } else { dismiss() }
                }
                .disabled(cancelled)
                .keyboardShortcut(.cancelAction)
                Button(s.save) { if preferences.confirmTagEdits { confirmingSave = true } else { save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(reading || readingArtwork || job != nil || edits.isEmpty || !canWrite)
            }
        }
        .padding(18)
        .frame(width: 580)
        .interactiveDismissDisabled(job != nil)
        .task { await load() }
        .alert(languages.language == .ru ? "Записать изменения в файлы?" : "Write changes to the files?",
               isPresented: $confirmingSave) {
            Button(s.cancel, role: .cancel) {}
            Button(s.save) { save() }
        }
    }

    private func fieldRow(_ field: AudioTagField) -> some View {
        let values = Set(selection.map { loaded[$0.id]?[field] ?? "" })
        let mixed = values.count > 1
        let baseline = values.count == 1 ? values.first ?? "" : ""
        return HStack {
            Toggle(s.tagFieldName(field), isOn: Binding(get: { edits.fields[field] != nil }, set: { enabled in
                edits.fields[field] = enabled ? baseline : nil
            }))
            .frame(width: 132, alignment: .leading)
            .disabled(!canWrite)
            TextField(mixed && edits.fields[field] == nil ? s.mixedTags : s.tagFieldName(field),
                      text: Binding(get: { edits.fields[field] ?? baseline }, set: { edits.fields[field] = $0 }))
                .disabled(edits.fields[field] == nil)
        }
    }

    private func load() async {
        let tracks = tracks
        let includeArtwork = preferences.showArtwork && tracks.count == 1
        let task = Task.detached(priority: .userInitiated) {
            var fields: [UUID: [AudioTagField: String]] = [:]
            var failed = Set<UUID>()
            var thumbnail: CGImage?
            for track in tracks {
                if Task.isCancelled { break }
                do {
                    let metadata = try TrackTagAccess.withURL(track) { try AudioMetadataFile.read($0, includeArtwork: includeArtwork) }
                    fields[track.id] = metadata.fields
                    if let art = metadata.artwork { thumbnail = TrackTagAccess.thumbnail(art.data) }
                } catch {
                    failed.insert(track.id)
                }
            }
            return (fields, failed, thumbnail)
        }
        let (fields, failures, thumbnail) = await withTaskCancellationHandler(operation: { await task.value },
                                                                              onCancel: { task.cancel() })
        guard !Task.isCancelled else { return }
        loaded = fields
        failed = failures
        if let thumbnail = thumbnail { preview = NSImage(cgImage: thumbnail, size: .zero) }
        reading = false
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readingArtwork = true
        DispatchQueue.global(qos: .userInitiated).async {
            let artwork = try? TrackTagAccess.importArtwork(url)
            let thumbnail = artwork.flatMap { TrackTagAccess.thumbnail($0.data) }
            DispatchQueue.main.async {
                readingArtwork = false
                guard let artwork = artwork, let thumbnail = thumbnail else { message = s.artworkInvalid; return }
                message = nil
                preview = NSImage(cgImage: thumbnail, size: .zero)
                edits.artwork = .replace(artwork)
            }
        }
    }

    private func save() {
        let files = selection.filter(isWritable)
        guard !files.isEmpty else { return }
        let work = ImportJob()
        job = work
        message = nil
        progress = 0
        total = files.count
        model.writeTags(edits, tracks: files, job: work, progress: { progress = $0 }) { failures, saved in
            job = nil
            if failures.isEmpty && !cancelled {
                dismiss()
            } else {
                message = ([s.tagsSavedCount(saved)] + Array(failures.prefix(5))).joined(separator: "\n")
                cancelled = false
            }
        }
    }
}
