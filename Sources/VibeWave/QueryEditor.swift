import SwiftUI
import VibeWaveCore

enum QueryEditorRequest: Identifiable {
    case filters
    case smart(SmartPlaylist)

    var id: String {
        switch self {
        case .filters: return "filters"
        case .smart(let list): return list.id.uuidString
        }
    }
}

enum SmartPreset: String, CaseIterable, Identifiable {
    case recentAdded, recentPlayed, frequent, highlyRated, unplayed
    var id: Self { self }

    func makeList(_ strings: Strings) -> SmartPlaylist {
        var list = SmartPlaylist()
        list.name = strings.smartPresetName(rawValue)
        list.query.descending = true
        switch self {
        case .recentAdded:
            list.query.rules = [QueryRule(.added, .withinDays, "30")]
            list.query.sort = .added
        case .recentPlayed:
            list.query.rules = [QueryRule(.lastPlayed, .withinDays, "30")]
            list.query.sort = .lastPlayed
        case .frequent:
            list.query.rules = [QueryRule(.plays, .atLeast, "2")]
            list.query.sort = .plays
        case .highlyRated:
            list.query.rules = [QueryRule(.rating, .atLeast, "4")]
            list.query.sort = .rating
        case .unplayed:
            list.query.rules = [QueryRule(.lastPlayed, .missing)]
            list.query.sort = .added
        }
        return list
    }
}

@MainActor
struct QueryEditorView: View {
    let model: PlayerModel
    let request: QueryEditorRequest
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var language = LanguageSettings.shared
    @State private var name: String
    @State private var query: LibraryQuery
    private var s: Strings { language.strings }
    private var editingList: Bool { if case .smart = request { return true }; return false }

    init(model: PlayerModel, request: QueryEditorRequest) {
        self.model = model
        self.request = request
        switch request {
        case .filters:
            _name = State(initialValue: "")
            _query = State(initialValue: model.searchFilter)
        case .smart(let list):
            _name = State(initialValue: list.name)
            _query = State(initialValue: list.query)
        }
    }

    private enum FilterSort: Hashable { case inherited, manual, field(QueryField) }

    private var filterSort: Binding<FilterSort> {
        Binding(get: {
            if let field = query.sort { return .field(field) }
            return query.preservesInputOrder == true ? .manual : .inherited
        }, set: { selection in
            switch selection {
            case .inherited:
                query.sort = nil
                query.preservesInputOrder = nil
            case .manual:
                query.sort = nil
                query.preservesInputOrder = true
            case .field(let field):
                query.sort = field
                query.preservesInputOrder = nil
            }
        })
    }

    var body: some View {
        RetroDialog(title: editingList ? s.smartPlaylists : s.searchFilters) {
            VStack(alignment: .leading, spacing: 10) {
                if editingList { TextField(s.playlistName, text: $name) }
                RetroChoice(title: s.queryMatch, selection: $query.matchAny,
                            options: [(false, s.queryMatchAll), (true, s.queryMatchAny)])
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach($query.rules) { $rule in
                            HStack {
                                RetroChoice(title: s.queryField, selection: $rule.field,
                                            options: QueryField.allCases.map { ($0, s.queryFieldName($0.rawValue)) },
                                            showsTitle: false)
                                    .frame(width: 132)
                                    .onChange(of: rule.field) { field in
                                        rule.operation = field.operators[0]
                                        rule.value = ""
                                    }
                                RetroChoice(title: s.queryOperator, selection: $rule.operation,
                                            options: rule.field.operators.map { ($0, s.queryOperatorName($0.rawValue)) },
                                            showsTitle: false)
                                    .frame(width: 154)
                                TextField(s.queryValue, text: $rule.value).disabled(!rule.operation.requiresValue)
                                Button {
                                    query.rules.removeAll { $0.id == rule.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .accessibilityLabel(s.queryRemoveRule)
                            }
                        }
                    }.padding(8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 120)
                .background(PlayerTheme.retro.background)
                .retroBevel(.retro, sunken: true)
                Button(s.queryAddRule) { query.rules.append(QueryRule()) }
                HStack {
                    if editingList {
                        QuerySortPicker(value: $query.sort)
                    } else {
                        RetroChoice(title: s.querySort, selection: filterSort,
                                    options: [(FilterSort.inherited, s.queryDefaultSort), (.manual, s.queryManualSort)] +
                                        QueryField.allCases.map { (.field($0), s.queryFieldName($0.rawValue)) })
                    }
                    Toggle(s.queryDescending, isOn: $query.descending).disabled(query.sort == nil)
                }
                if editingList {
                    HStack {
                        Text(s.queryLimit)
                        TextField("0", value: $query.limit, format: .number.grouping(.never))
                            .frame(width: 70)
                    }
                }
                Text(s.queryUnits).font(.caption).foregroundColor(.secondary)
                HStack {
                    Spacer()
                    Button(s.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(s.save) { save() }.keyboardShortcut(.defaultAction)
                        .disabled(!query.isValid || (editingList && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
        }
        .frame(width: 640)
    }

    private func save() {
        switch request {
        case .filters:
            model.searchFilter = query
        case .smart(var list):
            list.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            list.query = query
            model.saveSmartPlaylist(list)
        }
        dismiss()
    }
}

@MainActor
private struct QuerySortPicker: View {
    @Binding var value: QueryField?
    @ObservedObject private var language = LanguageSettings.shared

    var body: some View {
        let s = language.strings
        RetroChoice(title: s.querySort, selection: $value,
                    options: [(nil, s.queryManualSort)] +
                        QueryField.allCases.map { (Optional($0), s.queryFieldName($0.rawValue)) })
    }
}

@MainActor
struct SearchSettingsView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject private var language = LanguageSettings.shared
    @State private var editing: QueryEditorRequest?

    var body: some View {
        let s = language.strings
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                RetroChoice(title: s.queryScope, selection: $model.searchOptions.scope,
                            options: [(SearchScope.section, s.queryCurrentScope), (.library, s.allMusic)])
                    .onChange(of: model.searchOptions.scope) { model.searchScope = $0 }
                QuerySortPicker(value: $model.searchOptions.sort)
                Toggle(s.groupedList, isOn: $model.groupByPlaylists)
                ForEach(QueryField.textSearchFields) { field in
                    Toggle(s.queryFieldName(field.rawValue), isOn: Binding(get: {
                        model.searchOptions.fields.contains(field)
                    }, set: { value in
                        if value { model.searchOptions.fields.insert(field) }
                        else if model.searchOptions.fields.count > 1 { model.searchOptions.fields.remove(field) }
                    }))
                }
                Button(language.language == .ru ? "Сбросить настройки поиска и вида" : "Reset search and view settings") {
                    model.searchOptions = SearchOptions()
                    model.searchScope = model.searchOptions.scope
                    model.groupByPlaylists = false
                }
                Divider()
                HStack {
                    Button(s.createSmartPlaylist) { editing = .smart(SmartPlaylist()) }
                    Menu(s.queryPresets) {
                        ForEach(SmartPreset.allCases) { preset in
                            Button(s.smartPresetName(preset.rawValue)) { editing = .smart(preset.makeList(s)) }
                        }
                    }
                }
                ForEach(model.smartPlaylists) { list in
                    HStack {
                        Text(list.name).lineLimit(1)
                        Spacer()
                        Button(s.queryEdit) { editing = .smart(list) }
                        Button(s.deletePlaylist, role: .destructive) { model.deleteSmartPlaylist(list.id) }
                    }
                }
            }.padding(14)
        }
        .sheet(item: $editing) { QueryEditorView(model: model, request: $0) }
    }
}
