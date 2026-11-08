import SwiftUI
import VibeWaveCore
import UniformTypeIdentifiers

/// Окно плеера в стиле Windows 95: панель плеера сверху, плейлист снизу,
/// библиотека (плейлисты и папки) открывается кнопкой «Библиотека».
struct ContentView: View {
    @ObservedObject var model: PlayerModel
    @State private var naming = false
    @State private var name = ""
    @State private var renameID: UUID?
    @State private var dropTargeted = false
    @AppStorage("classic.showLibrary") private var showLibrary = false
    private let theme = PlayerTheme.retro

    var body: some View {
        VStack(spacing: 4) {
            RetroWindowTitleBar(theme: theme).frame(height: 20)
            ClassicPlayerPanel(model: model, theme: theme)
            HStack(spacing: 4) {
                if showLibrary { sidebar }
                playlist
            }
        }
        .font(.custom("Arial", size: 12))
        .padding(3)
        .background(WindowSizer(wide: showLibrary))
        .background(theme.panel)
        .retroBevel(theme)
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(dropTargeted ? theme.accent : .clear, style: StrokeStyle(lineWidth: 2, dash: [4])).padding(3).allowsHitTesting(false))
        .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: model.selected?.id, targeted: $dropTargeted))
        .foregroundColor(theme.foreground)
        .tint(theme.accent)
        .buttonStyle(RetroButtonStyle(theme: theme))
        .preferredColorScheme(.light)
        .sheet(isPresented: $naming) {
            VStack(alignment: .leading, spacing: 16) {
                Text(renameID == nil ? "Новый плейлист" : "Название плейлиста").fontWeight(.bold)
                TextField("Название", text: $name)
                    .textFieldStyle(.plain).padding(7).background(theme.background)
                    .retroBevel(theme, sunken: true)
                    .onSubmit { commitName() }
                HStack {
                    Spacer()
                    Button("Отмена") { naming = false }.keyboardShortcut(.cancelAction)
                    Button("Сохранить") { commitName() }.keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .font(.custom("Arial", size: 12)).padding(20).frame(width: 330)
            .background(theme.panel).foregroundColor(theme.foreground)
            .buttonStyle(RetroButtonStyle(theme: theme)).retroBevel(theme)
        }
        .alert("VibeWave", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("Понятно") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    // MARK: Библиотека

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(model: model, id: nil, icon: "music.note.house", title: "Вся музыка",
                           count: model.libraryEntries.count, theme: theme) { EmptyView() }
                sectionTitle("Плейлисты", help: "Создать плейлист") { renameID = nil; name = ""; naming = true }
                if model.playlists.isEmpty {
                    Text("Нет плейлистов").foregroundColor(theme.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                }
                ForEach(model.playlists) { playlist in
                    SidebarRow(model: model, id: playlist.id, icon: "music.note.list", title: playlist.name,
                               count: playlist.tracks.count, theme: theme) {
                        Button("Переименовать") { renameID = playlist.id; name = playlist.name; naming = true }
                        Button("Удалить плейлист", role: .destructive) { model.deletePlaylist(playlist.id) }
                    }
                }
                sectionTitle("Папки", help: "Добавить папку с музыкой") { model.chooseFolder() }
                if model.folders.isEmpty {
                    Text("Нет папок").foregroundColor(theme.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                }
                ForEach(model.folders) { folder in
                    SidebarRow(model: model, id: folder.id, icon: "folder", title: folder.name,
                               count: folder.tracks.count, theme: theme, acceptsDrop: false) {
                        Button("Обновить содержимое") { model.rescanFolder(folder.id) }
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                        Divider()
                        Button("Убрать из библиотеки", role: .destructive) { model.removeFolder(folder.id) }
                    }
                    .help(folder.url.path)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(3)
        }
        .frame(maxHeight: .infinity)
        .background(theme.background).retroBevel(theme, sunken: true)
        .padding(5).frame(width: 180)
        .background(theme.panel).retroBevel(theme)
    }

    private func sectionTitle(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.bold)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(RetroButtonStyle(theme: theme, compact: true))
            .help(help).accessibilityLabel(help).disabled(model.importing && title == "Папки")
        }
        .padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 3)
    }

    // MARK: Плейлист

    private var playlist: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Плейлист:").fontWeight(.bold)
                Text(model.selectedTitle).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 2)
            TrackTable(model: model, theme: theme)
            HStack(spacing: 3) {
                Button { model.importFiles() } label: { Text("+ Файл") }
                    .disabled(model.importing).help("Добавить файлы MP3/FLAC")
                Button { model.chooseFolder() } label: { Text("+ Папка") }
                    .disabled(model.importing).help("Добавить папку с музыкой")
                Button { showLibrary.toggle() } label: { Text("Библиотека") }
                    .buttonStyle(RetroButtonStyle(theme: theme, compact: true, isOn: showLibrary))
                    .help("Показать или скрыть плейлисты и папки")
                viewMenu
                Spacer(minLength: 4)
                Text("\(model.visibleTracks.count) · \(timeLabel(model.visibleTracks.reduce(0) { $0 + $1.duration }))")
                    .font(.custom("Arial", size: 11)).lineLimit(1)
                    .padding(.horizontal, 6).frame(height: 19)
                    .background(theme.background).retroBevel(theme, sunken: true)
                    .help("Треков и общее время")
            }
            .buttonStyle(RetroButtonStyle(theme: theme, compact: true))
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel).retroBevel(theme)
    }

    private var viewMenu: some View {
        Menu {
            Button { model.groupByPlaylists = false } label: {
                if !model.groupByPlaylists { Label("Общий список", systemImage: "checkmark") } else { Text("Общий список") }
            }
            Button { model.groupByPlaylists = true } label: {
                if model.groupByPlaylists { Label("По плейлистам", systemImage: "checkmark") } else { Text("По плейлистам") }
            }
            Divider()
            Button("Вся музыка") { model.selectedID = nil }
            if !model.playlists.isEmpty || !model.folders.isEmpty { Divider() }
            ForEach(model.playlists) { playlist in Button(playlist.name) { model.selectedID = playlist.id } }
            ForEach(model.folders) { folder in Button("📁 " + folder.name) { model.selectedID = folder.id } }
            Divider()
            Button("Новый плейлист…") { renameID = nil; name = ""; naming = true }
        } label: {
            Text("Вид ▾").font(.custom("Arial", size: 11))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 7).frame(height: 21)
        .background(theme.panel).retroBevel(theme)
        .help("Вид списка и раздел")
    }

    private func commitName() {
        if let id = renameID { model.renamePlaylist(id, name: name) }
        else { model.createPlaylist(name) }
        naming = false
    }
}

/// Узкое вертикальное окно; с открытой библиотекой — шире.
/// Ширина подстраивается при открытии/закрытии библиотеки, дальше размер за пользователем.
struct WindowSizer: NSViewRepresentable {
    let wide: Bool
    final class Coordinator { var last: Bool? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.contentMinSize = NSSize(width: wide ? 560 : 390, height: 460)
            var frame = window.frame
            // Первое появление: слишком широкое окно (после прежней раскладки) сужаем.
            let firstOversized = context.coordinator.last == nil && frame.width > (wide ? 760 : 560)
            let toggled = context.coordinator.last.map { $0 != wide } ?? false
            context.coordinator.last = wide
            guard firstOversized || toggled else { return }
            frame.size.width = wide ? 620 : 440
            frame.size.height = max(frame.height, 640)
            if let visible = window.screen?.visibleFrame {
                frame.size.height = min(frame.height, visible.height)
                frame.origin.y = max(visible.minY, min(frame.origin.y, visible.maxY - frame.height))
            }
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
