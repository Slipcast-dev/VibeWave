import SwiftUI
import VibeWaveCore

/// Строка поддерживает перенос перед другим треком и контекстное удаление.
struct TrackRow: View {
    @ObservedObject var model: PlayerModel
    let track: Track
    let tracks: [Track]
    let playlistID: UUID?
    let index: Int
    let theme: PlayerTheme
    let columns: TrackColumnWidths
    @State private var targeted = false

    var body: some View {
        Button { model.play(track, in: tracks, playlistID: playlistID) } label: {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .bold))
                        .frame(width: 18, height: 20).contentShape(Rectangle())
                        .help("Потяните мышью: поставить перед другим треком или в конец")
                        .onDrag { trackProvider(track, playlistID: playlistID) }
                    Group {
                        if model.current?.id == track.id {
                            Image(systemName: model.playing ? "speaker.wave.2.fill" : "pause.fill")
                        } else { Text("\(index + 1)") }
                    }.font(.custom("Arial", size: 12)).frame(maxWidth: .infinity)
                }.padding(.horizontal, 5).frame(width: columns.number)
                divider
                Text(track.title).font(.custom("Arial", size: 13)).lineLimit(1)
                    .padding(.horizontal, 7).frame(width: columns.title, alignment: .leading).help(track.title)
                divider
                Text(track.url.pathExtension.uppercased()).font(.custom("Arial", size: 13).weight(.semibold))
                    .padding(.horizontal, 7).frame(width: columns.format, alignment: .leading)
                divider
                Text(timeLabel(track.duration)).font(.custom("Arial", size: 13).weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 7).frame(width: columns.duration, alignment: .trailing)
                divider
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .foregroundColor(model.current?.id == track.id ? theme.selectionText : theme.foreground)
            .background(model.current?.id == track.id ? theme.selection : theme.background)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if targeted { Rectangle().fill(theme.accent).frame(height: 2).allowsHitTesting(false) }
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: playlistID, before: track.id, targeted: $targeted))
        .contextMenu { TrackContextMenu(model: model, track: track, tracks: tracks, playlistID: playlistID) }
    }
    private var divider: some View {
        Color.clear.frame(width: TrackColumnWidths.divider)
    }
}

/// Один набор действий для основной таблицы и постоянного списка вне плейлистов.
struct TrackContextMenu: View {
    @ObservedObject var model: PlayerModel
    let track: Track
    let tracks: [Track]
    let playlistID: UUID?
    private var index: Int { tracks.firstIndex(where: { $0.id == track.id }) ?? 0 }
    var body: some View {
        Button("Выше") { model.moveTrackBy(track.id, in: playlistID, offset: -1) }.disabled(index == 0)
        Button("Ниже") { model.moveTrackBy(track.id, in: playlistID, offset: 1) }.disabled(index >= tracks.count - 1)
        if playlistID == nil, !model.playlists.isEmpty {
            Menu("Добавить в плейлист") {
                ForEach(model.playlists) { playlist in
                    Button(playlist.name) {
                        model.moveTrack(TrackDragPayload(playlistID: nil, trackID: track.id), to: playlist.id, before: nil)
                    }
                }
            }
        }
        Divider()
        Button(playlistID == nil ? "Убрать из открытых файлов" : "Убрать из плейлиста", role: .destructive) {
            model.removeTrack(track.id, from: playlistID)
        }
    }

}

/// Обработчик drop установлен на самой кнопке, чтобы сохранялись обычные клики.
struct PlaylistButton: View {
    @ObservedObject var model: PlayerModel
    let playlist: Playlist
    let theme: PlayerTheme
    let rename: () -> Void
    @State private var targeted = false
    var body: some View {
        Button { model.selectedID = playlist.id } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                Text(playlist.name).lineLimit(1)
                Spacer()
            }
            .padding(7)
            .foregroundColor(model.selectedID == playlist.id ? theme.selectionText : theme.foreground)
            .background(model.selectedID == playlist.id ? theme.selection : theme.background)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(targeted ? theme.accent : .clear, lineWidth: 2).allowsHitTesting(false))
        }
        .buttonStyle(.plain)
        .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: playlist.id, targeted: $targeted))
        .contextMenu {
            Button("Переименовать", action: rename)
            Button("Удалить плейлист", role: .destructive) { model.deletePlaylist(playlist.id) }
        }
    }
}


/// Очередь видна независимо от выбранного плейлиста; действия имеют явный источник nil.
struct OpenQueueRow: View {
    @ObservedObject var model: PlayerModel
    let track: Track
    let theme: PlayerTheme
    @State private var targeted = false
    var body: some View {
        Button { model.play(track, in: model.openTracks, playlistID: nil) } label: {
            HStack(spacing: 6) {
                Image(systemName: model.current?.id == track.id ? "speaker.wave.2.fill" : "music.note")
                    .font(.system(size: 11)).frame(width: 14)
                Text(track.title).font(.custom("Arial", size: 12)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 5).padding(.vertical, 6)
            .foregroundColor(model.current?.id == track.id ? theme.selectionText : theme.foreground)
            .background(model.current?.id == track.id ? theme.selection : theme.background)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if targeted { Rectangle().fill(theme.accent).frame(height: 2).allowsHitTesting(false) }
            }
        }
        .buttonStyle(.plain).help(track.title)
        .onDrag { trackProvider(track, playlistID: nil) }
        .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: nil, before: track.id, targeted: $targeted))
        .contextMenu { TrackContextMenu(model: model, track: track, tracks: model.openTracks, playlistID: nil) }
    }
}
