import SwiftUI
import VibeWaveCore
import UniformTypeIdentifiers

/// Окно плеера в стиле Windows 95: панель плеера сверху, плейлист снизу,
/// библиотека (плейлисты и папки) открывается кнопкой «Библиотека».
@MainActor
struct ContentView: View {
    @ObservedObject var model: PlayerModel
    @State private var naming = false
    @State private var queryEditor: QueryEditorRequest?
    @State private var name = ""
    @State private var renameID: UUID?
    @State private var dropTargeted = false
    @AppStorage("classic.showLibrary") private var showLibrary = false
    @ObservedObject private var languages = LanguageSettings.shared
    private let theme = PlayerTheme.retro
    private var s: Strings { languages.strings }

    var body: some View {
        VStack(spacing: 4) {
            RetroWindowTitleBar(theme: theme, strings: s).frame(height: 20)
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
                Text(renameID == nil ? s.newPlaylist : s.playlistName).fontWeight(.bold)
                TextField(s.namePlaceholder, text: $name)
                    .textFieldStyle(.plain).padding(7).background(theme.background)
                    .retroBevel(theme, sunken: true)
                    .onSubmit { commitName() }
                HStack {
                    Spacer()
                    Button(s.cancel) { naming = false }.keyboardShortcut(.cancelAction)
                    Button(s.save) { commitName() }.keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .font(.custom("Arial", size: 12)).padding(20).frame(width: 330)
            .background(theme.panel).foregroundColor(theme.foreground)
            .buttonStyle(RetroButtonStyle(theme: theme)).retroBevel(theme)
        }
        .sheet(item: $queryEditor) { QueryEditorView(model: model, request: $0) }
        .sheet(item: $model.tagEditorRequest) { request in
            TagEditorView(model: model, tracks: request.tracks)
        }
        .alert("VibeWave", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(s.ok) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    // MARK: Библиотека

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                SidebarRow(model: model, id: nil, icon: "music.note.house", title: s.allMusic,
                           count: model.libraryEntries.count, theme: theme) { EmptyView() }
                sectionTitle(s.playlists, help: s.createPlaylist) { renameID = nil; name = ""; naming = true }
                if model.playlists.isEmpty {
                    Text(s.noPlaylists).foregroundColor(theme.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                }
                ForEach(model.playlists) { playlist in
                    SidebarRow(model: model, id: playlist.id, icon: "music.note.list", title: playlist.name,
                               count: playlist.tracks.count, theme: theme) {
                        Button(s.batchTags) { model.editTags(for: playlist.tracks) }.disabled(playlist.tracks.isEmpty)
                        Button(s.rename) { renameID = playlist.id; name = playlist.name; naming = true }
                        Button(s.deletePlaylist, role: .destructive) { model.deletePlaylist(playlist.id) }
                    }
                }
                sectionTitle(s.smartPlaylists, help: s.createSmartPlaylist) { queryEditor = .smart(SmartPlaylist()) }
                ForEach(model.smartPlaylists) { list in
                    SidebarRow(model: model, id: list.id, icon: "sparkles", title: list.name,
                               count: model.smartCounts[list.id, default: 0], theme: theme, acceptsDrop: false) {
                        Button(s.queryEdit) { queryEditor = .smart(list) }
                        Button(s.deletePlaylist, role: .destructive) { model.deleteSmartPlaylist(list.id) }
                    }
                }
                sectionTitle(s.folders, help: s.addMusicFolder, blockedByImport: true) { model.chooseFolder() }
                if model.folders.isEmpty {
                    Text(s.noFolders).foregroundColor(theme.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                }
                ForEach(model.folders) { folder in
                    SidebarRow(model: model, id: folder.id, icon: "folder", title: folder.name,
                               count: folder.tracks.count, theme: theme, acceptsDrop: false) {
                        Button(s.refreshFolder) { model.rescanFolder(folder.id) }
                        Button(s.showInFinder) { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                        Divider()
                        Button(s.removeFromLibrary, role: .destructive) { model.removeFolder(folder.id) }
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

    private func sectionTitle(_ title: String, help: String, blockedByImport: Bool = false,
                              action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).fontWeight(.bold)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(RetroButtonStyle(theme: theme, compact: true))
            .help(help).accessibilityLabel(help).disabled(model.importing && blockedByImport)
        }
        .padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 3)
    }

    // MARK: Плейлист

    private var playlist: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(s.playlistLabel).fontWeight(.bold)
                Text(model.selectedTitle).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 2)
            searchBar
            TrackTable(model: model, theme: theme)
            HStack(spacing: 3) {
                Button { model.importFiles() } label: { Text(s.addFileButton) }
                    .disabled(model.importing).help(s.addFilesHelp)
                Button { model.chooseFolder() } label: { Text(s.addFolderButton) }
                    .disabled(model.importing).help(s.addMusicFolder)
                Button { showLibrary.toggle() } label: { Text(s.libraryButton) }
                    .buttonStyle(RetroButtonStyle(theme: theme, isOn: showLibrary, toolbar: true))
                    .help(s.libraryHelp)
                viewMenu
                languageMenu
                Spacer(minLength: 4)
                if let progress = model.importProgress {
                    // Во время импорта вместо счётчика — ход работы и отмена.
                    let label = progress.label(s)
                    Text(label)
                        .font(.custom("Arial", size: 12)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 6).frame(height: 24)
                        .background(theme.background).retroBevel(theme, sunken: true)
                        .help(label)
                        .accessibilityLabel(label)
                    Button { model.cancelImport() } label: { Text(s.cancel) }
                        .help(s.cancelImportHelp)
                } else {
                    Text("\(model.displayedTracks.count) · \(timeLabel(model.displayedTracks.reduce(0) { $0 + $1.duration }))")
                        .font(.custom("Arial", size: 12)).lineLimit(1)
                        .padding(.horizontal, 6).frame(height: 24)
                        .background(theme.background).retroBevel(theme, sunken: true)
                        .help(s.counterHelp)
                }
            }
            .buttonStyle(RetroButtonStyle(theme: theme, toolbar: true))
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.panel).retroBevel(theme)
    }

    private var searchBar: some View {
        HStack(spacing: 4) {
            TextField(s.searchTracks, text: $model.searchText)
                .textFieldStyle(.plain)
                .padding(4)
                .background(theme.background).retroBevel(theme, sunken: true)
            Picker(s.queryScope, selection: $model.searchScope) {
                Text(s.queryCurrentScope).tag(SearchScope.section)
                Text(s.allMusic).tag(SearchScope.library)
            }
            .labelsHidden()
            .fixedSize()
            Button(s.searchFilters) { queryEditor = .filters }
                .buttonStyle(RetroButtonStyle(theme: theme, compact: true, isOn: model.searchFilter.isActive))
            if model.hasSearch {
                Button {
                    model.searchText = ""
                    model.searchFilter = LibraryQuery()
                } label: { Image(systemName: "xmark") }
                    .buttonStyle(RetroButtonStyle(theme: theme, compact: true))
                    .accessibilityLabel(s.clearSearch)
            }
        }
    }

    private var viewMenu: some View {
        RetroMenuButton(title: s.viewMenu) {
            var items: [RetroMenuButton.Item] = [
                .action(s.flatList, checked: !model.groupByPlaylists) { model.groupByPlaylists = false },
                .action(s.groupedList, checked: model.groupByPlaylists) { model.groupByPlaylists = true },
                .separator,
                .action(s.allMusic, checked: model.isLibrarySelected) { model.selectedID = nil }
            ]
            if !model.playlists.isEmpty || !model.folders.isEmpty { items.append(.separator) }
            items += model.playlists.map { playlist in
                .action(playlist.name, checked: model.selectedID == playlist.id) { model.selectedID = playlist.id }
            }
            items += model.folders.map { folder in
                .action("📁 " + folder.name, checked: model.selectedID == folder.id) { model.selectedID = folder.id }
            }
            items += model.smartPlaylists.map { list in
                .action("✦ " + list.name, checked: model.selectedID == list.id) { model.selectedID = list.id }
            }
            items += [.separator, .action(s.createSmartPlaylist) { queryEditor = .smart(SmartPlaylist()) }]
            items += [.action(s.newPlaylistMenu) { renameID = nil; name = ""; naming = true }]
            return items
        }
        .help(s.viewHelp)
    }

    /// Язык интерфейса: как в системе, русский или английский. Подпись — текущий язык.
    private var languageMenu: some View {
        RetroMenuButton(title: languages.language.code + " ▾") {
            let system = RetroMenuButton.Item.action(s.languageSystem(languages.systemLanguage.nativeName),
                                                     checked: languages.preference == .system) { languages.preference = .system }
            return [system, .separator] + AppLanguage.allCases.map { language in
                .action(language.nativeName, checked: languages.preference.rawValue == language.rawValue) {
                    languages.preference = LanguagePreference(rawValue: language.rawValue) ?? .system
                }
            }
        }
        .help(s.languageHelp)
        .accessibilityLabel("\(s.languageHelp): \(languages.language.nativeName)")
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
            window.contentMinSize = NSSize(width: wide ? 600 : 440, height: 460)
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
