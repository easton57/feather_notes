import SwiftUI

struct NotesListView: View {
    @State private var notes: [Note] = []
    @State private var folders: [Folder] = []
    @State private var selectedNoteId: Int?
    @State private var searchText: String = ""
    @State private var sortBy: String = "id"
    @State private var selectedTags: Set<String> = []
    @State private var availableTags: [String] = []
    @State private var expandedFolders: Set<Int> = []
    @State private var showingSettings = false
    @State private var editingNoteId: Int?
    @State private var editingNoteTitle: String = ""
    
    var body: some View {
        NavigationSplitView {
            List {
                // Search bar
                Section {
                    TextField("Search notes", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                }
                
                // Sort options
                Section {
                    Picker("Sort by", selection: $sortBy) {
                        Text("Creation Order").tag("id")
                        Text("Title (A-Z)").tag("title")
                        Text("Date Created").tag("date_created")
                        Text("Recently Modified").tag("date_modified")
                    }
                }
                
                // Tag filters
                if !availableTags.isEmpty {
                    Section("Filter by Tags") {
                        ForEach(availableTags, id: \.self) { tag in
                            Button(action: {
                                if selectedTags.contains(tag) {
                                    selectedTags.remove(tag)
                                } else {
                                    selectedTags.insert(tag)
                                }
                            }) {
                                HStack {
                                    Text(tag)
                                    Spacer()
                                    if selectedTags.contains(tag) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Folders
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders) { folder in
                            DisclosureGroup(isExpanded: Binding(
                                get: { expandedFolders.contains(folder.id) },
                                set: { isExpanded in
                                    if isExpanded {
                                        expandedFolders.insert(folder.id)
                                    } else {
                                        expandedFolders.remove(folder.id)
                                    }
                                }
                            )) {
                                ForEach(notesInFolder(folder.id)) { note in
                                    NoteRow(note: note, isEditing: editingNoteId == note.id, editedTitle: $editingNoteTitle) {
                                        selectedNoteId = note.id
                                    } onEdit: {
                                        editingNoteId = note.id
                                        editingNoteTitle = note.title
                                    } onDelete: {
                                        deleteNote(note.id)
                                    } onSave: {
                                        if editingNoteId == note.id {
                                            DatabaseHelper.shared.updateNoteTitle(id: note.id, title: editingNoteTitle)
                                            editingNoteId = nil
                                            loadNotes()
                                        }
                                    }
                                }
                            } label: {
                                Label(folder.name, systemImage: "folder")
                            }
                        }
                    }
                }
                
                // Notes without folder
                Section("Notes") {
                    ForEach(notesWithoutFolder) { note in
                        NoteRow(note: note, isEditing: editingNoteId == note.id, editedTitle: $editingNoteTitle) {
                            selectedNoteId = note.id
                        } onEdit: {
                            editingNoteId = note.id
                            editingNoteTitle = note.title
                        } onDelete: {
                            deleteNote(note.id)
                        } onSave: {
                            if editingNoteId == note.id {
                                DatabaseHelper.shared.updateNoteTitle(id: note.id, title: editingNoteTitle)
                                editingNoteId = nil
                                loadNotes()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Feather Notes")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createNewNote) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .onAppear {
                loadNotes()
            }
            .onChange(of: searchText) { _, _ in loadNotes() }
            .onChange(of: sortBy) { _, _ in loadNotes() }
            .onChange(of: selectedTags) { _, _ in loadNotes() }
        } detail: {
            if let noteId = selectedNoteId {
                CanvasView(noteId: noteId)
            } else {
                Text("Select a note")
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var notesWithoutFolder: [Note] {
        notes.filter { $0.folderId == nil }
    }
    
    private func notesInFolder(_ folderId: Int) -> [Note] {
        notes.filter { $0.folderId == folderId }
    }
    
    private func loadNotes() {
        let searchQuery = searchText.isEmpty ? nil : searchText
        notes = DatabaseHelper.shared.getAllNotes(
            searchQuery: searchQuery,
            sortBy: sortBy,
            filterTags: Array(selectedTags)
        )
        folders = DatabaseHelper.shared.getAllFolders()
        availableTags = DatabaseHelper.shared.getAllTags()
    }
    
    private func createNewNote() {
        let noteId = DatabaseHelper.shared.createNote(title: "New Note")
        selectedNoteId = noteId
        loadNotes()
    }
    
    private func deleteNote(_ id: Int) {
        DatabaseHelper.shared.deleteNote(id: id)
        if selectedNoteId == id {
            selectedNoteId = nil
        }
        loadNotes()
    }
}

struct NoteRow: View {
    let note: Note
    let isEditing: Bool
    @Binding var editedTitle: String
    let onTap: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onSave: () -> Void
    
    var body: some View {
        HStack {
            if isEditing {
                TextField("Note title", text: $editedTitle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        onSave()
                    }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.title)
                        .font(.headline)
                    if !note.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(note.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.blue.opacity(0.2))
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                Spacer()
                Menu {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                onTap()
            }
        }
    }
}

