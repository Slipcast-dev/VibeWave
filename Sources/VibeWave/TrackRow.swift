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
    @State private var targeted = false

    var body: some View {
        Button { model.play(track, in: tracks, playlistID: playlistID) } label: {
            HStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal").font(.system(size: 8)).frame(width: 8)
                        .help("Перетащите для изменения порядка")
                    Group {
                        if model.current?.id == track.id {
                            Image(systemName: model.playing ? "speaker.wave.2.fill" : "pause.fill")
                        } else { Text("\(index + 1)") }
                    }.font(.custom("Arial", size: 10)).frame(width: 20)
                }
                Text(track.title).font(.custom("Arial", size: 12)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(track.url.pathExtension.uppercased()).font(.custom("Arial", size: 10))
                    .frame(width: 48)
                Text(timeLabel(track.duration)).font(.custom("Arial", size: 10)).monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 6).padding(.vertical, 7)
            .foregroundColor(model.current?.id == track.id ? theme.selectionText : theme.foreground)
            .background(model.current?.id == track.id ? theme.selection : theme.background)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                if targeted { Rectangle().fill(theme.accent).frame(height: 2).allowsHitTesting(false) }
            }
        }
        .buttonStyle(.plain)
        .onDrag { trackProvider(track, playlistID: playlistID) }
        .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: playlistID, before: track.id, targeted: $targeted))
        .contextMenu {
            if playlistID == nil, !model.playlists.isEmpty {
                Menu("Добавить в плейлист") {
                    ForEach(model.playlists) { playlist in
                        Button(playlist.name) {
                            model.moveTrack(TrackDragPayload(playlistID: nil, trackID: track.id), to: playlist.id, before: nil)
                        }
                    }
                }
            }
            Button(playlistID == nil ? "Убрать из открытых файлов" : "Убрать из плейлиста", role: .destructive) { model.removeTrack(track.id) }
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
