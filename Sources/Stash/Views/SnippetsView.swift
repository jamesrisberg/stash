import AppKit
import StashKit
import SwiftUI

/// What the Snippets window has selected and is editing.
@MainActor
final class SnippetsViewState: ObservableObject {
    @Published var selectedID: String?
    @Published var query = ""
    /// A new snippet not saved yet.
    @Published var newDraft: Snippet?
    @Published var message: String?
}

/// Snippets by collection on the left, the selected one's editor on the right; the header has
/// the expansion switch, the Alfred import and New.
struct SnippetsView: View {
    @ObservedObject var snippets: SnippetsController
    @ObservedObject var model: AppModel
    @ObservedObject var state: SnippetsViewState
    let close: () -> Void
    @State private var newCollection = ""
    @State private var addingCollection = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                list.frame(width: 270)
                Divider().opacity(0.4)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.4)
            footer
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
            Text("Snippets").font(.system(size: 14, weight: .semibold))
            Text("\(snippets.snippets.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.white.opacity(0.1)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Toggle("Expand keywords as I type", isOn: Binding(
                get: { model.settings.snippetExpansion },
                set: { on in
                    do { try snippets.setExpansion(on) } catch { state.message = "Could not save: \(error.localizedDescription)" }
                }))
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 12))
                .help("Turn Alfred's snippet expansion off first, or both expand the same keyword.")
            Button("Import from Alfred") { importFromAlfred() }
                .controlSize(.small)
            Button { startNew() } label: { Image(systemName: "plus") }
                .controlSize(.small)
                .help("New snippet")
            Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Close (⌘W)")
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(WindowDragArea())
    }

    // MARK: List

    private var filtered: [Snippet] { SnippetSearch.rank(snippets.snippets, query: state.query) }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search snippets", text: $state.query).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            Divider().opacity(0.3)
            if snippets.snippets.isEmpty && snippets.collections.isEmpty {
                empty("No snippets yet", "Press + to add one, or import yours from Alfred.", symbol: "text.badge.plus")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(sections, id: \.0) { collection, items in
                            sectionHeader(collection)
                            if items.isEmpty {
                                Text("No snippets").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                            }
                            ForEach(items) { row($0) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    /// Collections in order, each with its matching snippets. While searching, collections
    /// with no match are left out.
    private var sections: [(String, [Snippet])] {
        let grouped = Dictionary(grouping: filtered.sorted(by: SnippetSearch.ordered), by: \.collection)
        let searching = !state.query.trimmingCharacters(in: .whitespaces).isEmpty
        return snippets.collections.compactMap { name in
            let items = grouped[name] ?? []
            return searching && items.isEmpty ? nil : (name, items)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ snippet: Snippet) -> some View {
        let selected = snippet.id == state.selectedID && state.newDraft == nil
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name.isEmpty ? "Untitled" : snippet.name).font(.system(size: 13)).lineLimit(1)
                Text(SnippetSearch.preview(snippet.text)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if !snippet.keyword.isEmpty {
                Text(snippet.keyword)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
                    .foregroundStyle(snippet.autoExpand ? .primary : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.32) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            state.newDraft = nil
            state.selectedID = snippet.id
        }
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let draft = state.newDraft {
            SnippetEditor(snippet: draft, isNew: true, collections: snippets.collections, others: snippets.snippets,
                          save: save, delete: { state.newDraft = nil })
                .id("new-" + draft.id)
        } else if let id = state.selectedID, let snippet = snippets.store.snippet(id: id) {
            SnippetEditor(snippet: snippet, isNew: false, collections: snippets.collections,
                          others: snippets.snippets.filter { $0.id != id }, save: save, delete: { delete(snippet) })
                .id(snippet.id)
        } else {
            empty("Pick a snippet", "Or press + to add one.", symbol: "text.cursor")
        }
    }

    private func empty(_ title: String, _ detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if let message = state.message {
                Label(message, systemImage: "info.circle").lineLimit(1)
            } else if !model.settings.snippetExpansion {
                Label("Keyword expansion is off. Find snippets in MacHUD's search bar.", systemImage: "keyboard")
            } else if snippets.expansionActive {
                Label("Expanding keywords as you type, except in password fields and ignored apps.", systemImage: "keyboard.badge.ellipsis")
            } else {
                Label("Keyword expansion needs Accessibility (menu bar icon > Grant Accessibility…).", systemImage: "exclamationmark.triangle")
            }
            Spacer(minLength: 8)
            if addingCollection {
                TextField("Collection name", text: $newCollection).textFieldStyle(.roundedBorder).frame(width: 150)
                    .onSubmit(addCollection)
                Button("Add", action: addCollection).controlSize(.small)
                Button("Cancel") { addingCollection = false; newCollection = "" }.controlSize(.small)
            } else {
                Button("New Collection") { addingCollection = true }.controlSize(.small)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 34)
    }

    // MARK: Actions

    private func startNew() {
        let current = state.selectedID.flatMap { snippets.store.snippet(id: $0) }?.collection
        state.newDraft = Snippet(name: "", keyword: "", text: "",
                                 collection: current ?? snippets.collections.first ?? SnippetStore.defaultCollection)
    }

    private func save(_ snippet: Snippet) {
        do {
            try snippets.save(snippet)
            state.newDraft = nil
            state.selectedID = snippet.id
            state.message = nil
        } catch {
            state.message = "Could not save: \(error.localizedDescription)"
        }
    }

    private func delete(_ snippet: Snippet) {
        do {
            try snippets.delete(snippet.id)
            state.selectedID = nil
        } catch {
            state.message = "Could not delete: \(error.localizedDescription)"
        }
    }

    private func addCollection() {
        do { try snippets.addCollection(newCollection) } catch { state.message = "\(error)" }
        addingCollection = false
        newCollection = ""
    }

    private func importFromAlfred() {
        state.message = snippets.importFromAlfredMessage()
    }
}

/// Edits one snippet: name, keyword, collection, auto-expand and text, saved with Save (⌘S).
struct SnippetEditor: View {
    @State private var draft: Snippet
    let original: Snippet
    let isNew: Bool
    let collections: [String]
    let others: [Snippet]
    let save: (Snippet) -> Void
    let delete: () -> Void

    init(snippet: Snippet, isNew: Bool, collections: [String], others: [Snippet],
         save: @escaping (Snippet) -> Void, delete: @escaping () -> Void) {
        _draft = State(initialValue: snippet)
        original = snippet
        self.isNew = isNew
        self.collections = collections
        self.others = others
        self.save = save
        self.delete = delete
    }

    private var clash: Snippet? {
        draft.keyword.isEmpty ? nil : others.first { $0.keyword == draft.keyword }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                field("Name") { TextField("Name", text: $draft.name).textFieldStyle(.roundedBorder) }
                field("Keyword") {
                    TextField("keyword", text: $draft.keyword).textFieldStyle(.roundedBorder)
                        .font(.system(size: 12.5, design: .monospaced))
                }
                .frame(width: 140)
            }
            HStack(spacing: 10) {
                field("Collection") {
                    Picker("", selection: $draft.collection) {
                        ForEach(Array(Set(collections + [draft.collection])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                Toggle("Expand automatically", isOn: $draft.autoExpand)
                    .toggleStyle(.checkbox).font(.system(size: 12))
                    .padding(.top, 14)
            }
            if let clash {
                Label("\u{201C}\(clash.name)\u{201D} has this keyword too; the longer keyword wins when one ends the other.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
            }
            field("Text") {
                TextEditor(text: $draft.text)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.25)))
            }
            HStack(spacing: 8) {
                Text("{date}  {time}  {clipboard} are filled in when it is inserted")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                Spacer()
                Button(isNew ? "Discard" : "Delete", role: .destructive, action: delete).controlSize(.small)
                Button("Save") { save(draft) }
                    .controlSize(.small)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isNew && draft == original || draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(14)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
            content()
        }
    }
}
