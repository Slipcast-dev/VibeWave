import SwiftUI
import VibeWaveCore

/// Строка плейлиста: «N. Название» слева, время справа. Перетаскивается вся строка
/// (перед другим треком или в конец); контекстное меню — действия с источником.
/// sourceID — откуда трек (для действий), dropTargetID — куда падают перетаскивания.
@MainActor
struct TrackRow: View {
    @ObservedObject var model: PlayerModel
    let track: Track
    let number: Int
    let sourceID: UUID?
    var dropTargetID: UUID?
    var libraryReorder = false
    let theme: PlayerTheme
    let play: () -> Void
    @State private var targeted = false
    @ObservedObject private var languages = LanguageSettings.shared

    var body: some View {
        let isCurrent = model.current?.id == track.id
        // Не Button: на macOS кнопка забирает нажатие мыши, и перетаскивание не начинается.
        // Щелчок запускает трек, протяжка мышью — переносит строку.
        HStack(spacing: 6) {
            Group {
                if isCurrent { Image(systemName: model.playing ? "speaker.wave.2.fill" : "pause.fill").font(.system(size: 9)) }
                else { Text("\(number).") }
            }.frame(minWidth: 22, alignment: .trailing)
            Text(track.title).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(timeLabel(track.duration)).monospacedDigit()
        }
        .font(.custom("Arial", size: 12))
        .padding(.horizontal, 5).padding(.vertical, 3)
        .foregroundColor(isCurrent ? theme.selectionText : theme.listText)
        .background(isCurrent ? theme.selection : Color.clear)
        .contentShape(Rectangle())
        .overlay(alignment: .top) {
            if targeted { Rectangle().fill(theme.accent).frame(height: 2).allowsHitTesting(false) }
        }
        .onTapGesture(perform: play)
        .help(languages.strings.trackHelp(track.title))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: languages.strings.play, play)
        .onDrag { trackProvider(track, playlistID: sourceID) }
        .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: dropTargetID, before: track.id,
                                                                          libraryReorder: libraryReorder, targeted: $targeted))
        .contextMenu { TrackContextMenu(model: model, track: track, sourceID: sourceID, libraryOrder: libraryReorder) }
    }
}

/// Один набор действий для всех списков; «Выше/Ниже» работают в том порядке, который виден.
@MainActor
struct TrackContextMenu: View {
    @ObservedObject var model: PlayerModel
    let track: Track
    let sourceID: UUID?
    var libraryOrder = false
    @ObservedObject private var languages = LanguageSettings.shared
    private var s: Strings { languages.strings }
    private var ids: [UUID] { libraryOrder ? model.libraryEntries.map(\.id) : (model.tracks(in: sourceID) ?? []).map(\.id) }
    private var index: Int { ids.firstIndex(of: track.id) ?? 0 }
    private var sourceName: String {
        model.playlists.first { $0.id == sourceID }?.name ?? model.folders.first { $0.id == sourceID }?.name ?? s.outsidePlaylists
    }
    var body: some View {
        Text(s.source(sourceName))
        Divider()
        Button(s.moveUp) { move(-1) }.disabled(index == 0)
        Button(s.moveDown) { move(1) }.disabled(index >= ids.count - 1)
        let targets = model.playlists.filter { $0.id != sourceID }
        if !targets.isEmpty {
            Menu(model.isPlaylist(sourceID) ? s.moveToPlaylist : s.addToPlaylist) {
                ForEach(targets) { playlist in
                    Button(playlist.name) {
                        model.moveTrack(TrackDragPayload(playlistID: sourceID, trackID: track.id), to: playlist.id, before: nil)
                    }
                }
            }
        }
        Divider()
        Button(removeTitle, role: .destructive) { model.removeTrack(track.id, from: sourceID) }
    }
    private var removeTitle: String {
        if model.isPlaylist(sourceID) { return s.removeFromPlaylist }
        if model.isFolder(sourceID) { return s.hideFromFolder }
        return s.removeFromList
    }
    private func move(_ offset: Int) {
        if libraryOrder { model.moveInLibraryBy(track.id, offset: offset) }
        else { model.moveTrackBy(track.id, in: sourceID, offset: offset) }
    }
}

/// Пункт единого сайдбара: «Вся музыка», плейлист или папка.
/// Обработчик drop установлен на самой кнопке, чтобы сохранялись обычные клики.
@MainActor
struct SidebarRow<Menu: View>: View {
    @ObservedObject var model: PlayerModel
    let id: UUID?
    let icon: String
    let title: String
    let count: Int
    let theme: PlayerTheme
    var acceptsDrop = true
    @ViewBuilder let menu: () -> Menu
    @State private var targeted = false
    private var isSelected: Bool { id == nil ? model.isLibrarySelected : model.selectedID == id }
    var body: some View {
        Button { model.selectedID = id } label: {
            HStack(spacing: 7) {
                Image(systemName: icon).frame(width: 14)
                Text(title).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(count)").font(.custom("Arial", size: 10))
                    .foregroundColor(isSelected ? theme.selectionText : theme.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 6)
            .foregroundColor(isSelected ? theme.selectionText : theme.listText)
            .background(isSelected ? theme.selection : theme.background)
            .contentShape(Rectangle())
            .overlay(Rectangle().stroke(targeted ? theme.accent : .clear, lineWidth: 2).allowsHitTesting(false))
        }
        .buttonStyle(.plain).help(title)
        .onDrop(of: acceptsDrop ? TrackDropDelegate.types : [], delegate: TrackDropDelegate(model: model, playlistID: id, targeted: $targeted))
        .contextMenu(menuItems: menu)
    }
}
