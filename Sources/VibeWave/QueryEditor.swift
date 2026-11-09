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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(editingList ? s.smartPlaylists : s.searchFilters).font(.headline)
            if editingList { TextField(s.playlistName, text: $name) }
            Picker(s.queryMatch, selection: $query.matchAny) {
                Text(s.queryMatchAll).tag(false)
                Text(s.queryMatchAny).tag(true)
            }
            ScrollView {
                VStack(spacing: 7) {
                    ForEach($query.rules) { $rule in
                        HStack {
                            Picker(s.queryField, selection: $rule.field) {
                                ForEach(QueryField.allCases) { field in
                                    Text(s.queryFieldName(field.rawValue)).tag(field)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 132)
                            .onChange(of: rule.field) { field in
                                rule.operation = field.operators[0]
                                rule.value = ""
                            }
                            Picker(s.queryOperator, selection: $rule.operation) {
                                ForEach(rule.field.operators) { operation in
                                    Text(s.queryOperatorName(operation.rawValue)).tag(operation)
                                }
                            }
                            .labelsHidden()
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
                }
            }
            .frame(minHeight: 70, maxHeight: 160)
            Button(s.queryAddRule) { query.rules.append(QueryRule()) }
            HStack {
                QuerySortPicker(value: $query.sort)
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
        .padding(16)
        .frame(width: 600)
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
        Picker(s.querySort, selection: $value) {
            Text(s.queryManualSort).tag(Optional<QueryField>.none)
            ForEach(QueryField.allCases) { field in
                Text(s.queryFieldName(field.rawValue)).tag(Optional(field))
            }
        }
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
                Picker(s.queryScope, selection: $model.searchOptions.scope) {
                    Text(s.queryCurrentScope).tag(SearchScope.section)
                    Text(s.allMusic).tag(SearchScope.library)
                }
                .onChange(of: model.searchOptions.scope) { model.searchScope = $0 }
                QuerySortPicker(value: $model.searchOptions.sort)
                ForEach(QueryField.textSearchFields) { field in
                    Toggle(s.queryFieldName(field.rawValue), isOn: Binding(get: {
                        model.searchOptions.fields.contains(field)
                    }, set: { value in
                        if value { model.searchOptions.fields.insert(field) }
                        else if model.searchOptions.fields.count > 1 { model.searchOptions.fields.remove(field) }
                    }))
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
