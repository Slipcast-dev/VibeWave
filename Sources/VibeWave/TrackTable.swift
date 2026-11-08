import SwiftUI
import VibeWaveCore

/// Список плейлиста: выбранный плейлист/папка или раздел «Вся музыка»
/// (общий список с ручным порядком либо разделы по плейлистам).
struct TrackTable: View {
    @ObservedObject var model: PlayerModel
    let theme: PlayerTheme
    @State private var endTargeted = false

    private var library: Bool { model.isLibrarySelected }
    private var flatLibrary: Bool { library && !model.groupByPlaylists }
    private var isEmpty: Bool {
        model.visibleTracks.isEmpty && !(library && model.groupByPlaylists && !model.librarySections.allSatisfy(\.tracks.isEmpty))
    }

    var body: some View {
        Group {
            if isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        rows
                        endDropZone
                    }.padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background).retroBevel(theme, sunken: true)
    }

    @ViewBuilder private var rows: some View {
        if !library {
            let tracks = model.visibleTracks
            let source = model.selectedID
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(model: model, track: track, number: index + 1, sourceID: source, dropTargetID: source,
                         theme: theme) { model.play(track, in: tracks, playlistID: source) }
            }
        } else if model.groupByPlaylists {
            ForEach(model.librarySections) { section in
                SectionHeader(model: model, section: section, theme: theme)
                ForEach(Array(section.tracks.enumerated()), id: \.element.id) { index, track in
                    TrackRow(model: model, track: track, number: index + 1, sourceID: section.sourceID,
                             dropTargetID: section.sourceID, theme: theme) { model.playLibrary(track, section: section.id) }
                }
            }
        } else {
            ForEach(Array(model.libraryEntries.enumerated()), id: \.element.id) { index, entry in
                TrackRow(model: model, track: entry.track, number: index + 1, sourceID: entry.sourceID,
                         dropTargetID: nil, libraryReorder: true, theme: theme) { model.playLibrary(entry.track) }
            }
        }
    }

    private var endDropZone: some View {
        Color.clear.frame(height: 32).contentShape(Rectangle())
            .background(endTargeted ? theme.selection.opacity(0.18) : .clear)
            .overlay(alignment: .top) {
                if endTargeted { Rectangle().fill(theme.accent).frame(height: 2).allowsHitTesting(false) }
            }
            .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: library ? nil : model.selectedID,
                                                                              libraryReorder: flatLibrary, targeted: $endTargeted))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note").font(.system(size: 24)).foregroundColor(theme.secondary)
            Text(model.selected != nil ? "Добавьте музыку в плейлист" : model.selectedFolder != nil ? "В папке нет MP3 и FLAC" : "Добавьте музыку")
                .fontWeight(.bold)
            Text("Перетащите сюда файлы MP3 и FLAC или папку с музыкой").foregroundColor(theme.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }.padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Заголовок раздела в режиме «По плейлистам»; в него можно бросить трек (кроме папок).
private struct SectionHeader: View {
    @ObservedObject var model: PlayerModel
    let section: LibrarySection
    let theme: PlayerTheme
    @State private var targeted = false
    private var icon: String {
        switch section.kind {
        case .playlist: return "music.note.list"
        case .folder: return "folder"
        case .loose: return "tray"
        }
    }
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(section.title).fontWeight(.bold).lineLimit(1)
            Text("(\(section.tracks.count))").foregroundColor(theme.secondary)
            Spacer(minLength: 0)
        }
        .font(.custom("Arial", size: 12))
        .foregroundColor(theme.foreground)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.panel).retroBevel(theme)
        .overlay(Rectangle().stroke(targeted ? theme.accent : .clear, lineWidth: 2).allowsHitTesting(false))
        .onDrop(of: section.kind == .folder ? [] : TrackDropDelegate.types,
                delegate: TrackDropDelegate(model: model, playlistID: section.sourceID, targeted: $targeted))
    }
}
