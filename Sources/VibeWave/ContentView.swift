import SwiftUI
import VibeWaveCore
import UniformTypeIdentifiers

/// Ретро-оболочка не меняет модель очереди, плейлистов и обработчики файлов.
struct ContentView: View {
    @ObservedObject var model: PlayerModel
    @State private var naming = false
    @State private var name = ""
    @State private var renameID: UUID?
    @AppStorage("appearance") private var appearance = PlayerTheme.retro.rawValue
    @AppStorage("retroStyleIntroduced") private var retroIntroduced = false
    @State private var dropTargeted = false
    @State private var openQueueTargeted = false
    private var theme: PlayerTheme { PlayerTheme(rawValue: appearance) ?? .retro }

    var body: some View {
        VStack(spacing: 6) {
            RetroWindowTitleBar(theme: theme).frame(height: 24)
            HStack(spacing: 6) {
                sidebar
                tracks
            }
            transport
        }
        .font(.custom("Arial", size: 12))
        .padding(5)
        .background(theme.panel)
        .retroBevel(theme)
        .contentShape(Rectangle())
        .overlay(Rectangle().stroke(dropTargeted ? theme.accent : .clear, style: StrokeStyle(lineWidth: 2, dash: [4])).padding(3).allowsHitTesting(false))
        .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: model.selectedID, targeted: $dropTargeted))
        .foregroundColor(theme.foreground)
        .tint(theme.accent)
        .buttonStyle(RetroButtonStyle(theme: theme))
        .preferredColorScheme(theme.scheme)
        .onAppear {
            // Один раз показываем новое оформление; последующий выбор темы сохраняется.
            if !retroIntroduced { appearance = PlayerTheme.retro.rawValue; retroIntroduced = true }
        }
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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Плейлисты").fontWeight(.bold)
                Spacer()
                Button { renameID = nil; name = ""; naming = true } label: {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                }.help("Создать плейлист")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if model.playlists.isEmpty {
                        Text("Нет плейлистов").foregroundColor(theme.secondary).padding(8)
                    }
                    ForEach(model.playlists) { playlist in
                        PlaylistButton(model: model, playlist: playlist, theme: theme) {
                            renameID = playlist.id; name = playlist.name; naming = true
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background).retroBevel(theme, sunken: true)
            HStack(spacing: 5) {
                Text("Вне плейлистов").fontWeight(.bold)
                Text("(\(model.openTracks.count))").foregroundColor(theme.secondary)
                Spacer(minLength: 0)
                Button { model.selectedID = nil } label: {
                    Image(systemName: "list.bullet").font(.system(size: 10, weight: .bold))
                }.help("Показать очередь в основной таблице")
                    .accessibilityLabel("Показать музыку вне плейлистов")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if model.openTracks.isEmpty {
                        Text("Нет открытой музыки").foregroundColor(theme.secondary).padding(7)
                    }
                    ForEach(model.openTracks) { track in OpenQueueRow(model: model, track: track, theme: theme) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(3)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background).retroBevel(theme, sunken: true)
            .onDrop(of: TrackDropDelegate.types, delegate: TrackDropDelegate(model: model, playlistID: nil, targeted: $openQueueTargeted))
            VStack(spacing: 6) {
                Button { model.importFiles() } label: {
                    Label(model.importing ? "Добавление…" : "Добавить файлы…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .disabled(model.importing)
                .help(model.selectedID == nil ? "Добавить в открытые файлы" : "Добавить в выбранный плейлист")
                Menu {
                    ForEach(PlayerTheme.allCases) { item in
                        Button {
                            appearance = item.rawValue
                        } label: {
                            if item == theme { Label(item.title, systemImage: "checkmark") }
                            else { Text(item.title) }
                        }
                    }
                } label: {
                    HStack {
                        Text("Тема: \(theme.title)")
                        Spacer(minLength: 3)
                        Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 7)
                    .background(theme.panel).retroBevel(theme)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden)
                .padding(.horizontal, 5).padding(.vertical, 4)
                .background(theme.panel).retroBevel(theme)
                .accessibilityLabel("Тема оформления: \(theme.title)")
            }
        }
        .padding(8).frame(width: 205)
        .background(theme.panel).retroBevel(theme)
    }

    private var tracks: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let playlist = model.selected {
                    Text(playlist.name).fontWeight(.bold).lineLimit(1)
                }
                Spacer()
                Text("Треков: \(model.visibleTracks.count)").foregroundColor(theme.secondary)
            }.padding(.horizontal, 3).padding(.vertical, 3)
            TrackTable(model: model, theme: theme)
        }
        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.panel).retroBevel(theme)
        .contentShape(Rectangle())
    }

    private var transport: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.current?.title ?? "Ничего не играет").lineLimit(1)
                    Text(model.current?.url.pathExtension.uppercased() ?? "Готово")
                        .font(.custom("Arial", size: 10)).foregroundColor(theme.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                .background(theme.background).retroBevel(theme, sunken: true)
                HStack(spacing: 4) {
                    Button { model.previous() } label: {
                        Image(systemName: "backward.end.fill").frame(width: 16, height: 18)
                    }.disabled(model.current == nil).help("Предыдущий трек")
                    Button { model.toggle() } label: {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 16, height: 18)
                    }.keyboardShortcut(.space, modifiers: [])
                        .disabled(model.current == nil && model.visibleTracks.isEmpty)
                        .help(model.playing ? "Пауза" : "Воспроизвести")
                    Button { model.next() } label: {
                        Image(systemName: "forward.end.fill").frame(width: 16, height: 18)
                    }.disabled(model.current == nil).help(model.nextTrack.map { "Следующий: \($0.title)" } ?? "Конец очереди")
                }
                HStack(spacing: 6) {
                    Image(systemName: "speaker.wave.1").foregroundColor(theme.foreground)
                    RetroSlider(value: $model.volume, theme: theme).frame(width: 85)
                        .accessibilityLabel("Громкость")
                }
            }
            HStack {
                Menu {
                    ForEach(PlaybackOrder.allCases, id: \.rawValue) { order in
                        Button { model.setPlaybackOrder(order) } label: {
                            if model.playbackOrder == order { Label(order.title, systemImage: "checkmark") }
                            else { Text(order.title) }
                        }
                    }
                } label: {
                    Text("Порядок: \(model.playbackOrder.title)").font(.custom("Arial", size: 12))
                }
                .menuStyle(.borderlessButton).frame(width: 185)
                .padding(.horizontal, 5).padding(.vertical, 4).background(theme.panel).retroBevel(theme)
                .help("По списку учитывает перестановку треков; случайный режим не повторяет треки в одном проходе")
                Spacer()
            }
            HStack(spacing: 8) {
                Text(timeLabel(model.position)).frame(width: 38).monospacedDigit()
                RetroSlider(value: Binding(get: { model.position }, set: { model.seek($0) }), range: 0...max(1, model.duration), theme: theme)
                    .disabled(model.current == nil).accessibilityLabel("Позиция воспроизведения")
                Text(timeLabel(model.duration)).frame(width: 38).monospacedDigit()
            }.font(.custom("Arial", size: 11))
        }.padding(10).background(theme.panel).retroBevel(theme)
    }

    private func commitName() {
        if let id = renameID { model.renamePlaylist(id, name: name) }
        else { model.createPlaylist(name) }
        naming = false
    }
}
