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
    @State private var showingNoteTypeDialog = false
    @State private var showingNoteContextMenu = false
    @State private var showingFolderContextMenu = false
    @State private var contextMenuNoteId: Int?
    @State private var contextMenuFolderId: Int?
    
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
                                    } onLongPress: { position in
                                        showNoteContextMenu(noteId: note.id, position: position)
                                    }
                                }
                            } label: {
                                Label(folder.name, systemImage: "folder")
                                    .contentShape(Rectangle())
                                    .onLongPressGesture { location in
                                        showFolderContextMenu(folderId: folder.id, position: location)
                                    }
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
                        } onLongPress: { position in
                            showNoteContextMenu(noteId: note.id, position: position)
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
                    Button(action: { showingNoteTypeDialog = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .confirmationDialog("Create New Note", isPresented: $showingNoteTypeDialog, titleVisibility: .visible) {
                Button("Text Only") {
                    createNewNote(isTextOnly: true)
                }
                Button("Infinite Drawing") {
                    createNewNote(isTextOnly: false)
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear {
                loadNotes()
            }
            .onChange(of: searchText) { _, _ in loadNotes() }
            .onChange(of: sortBy) { _, _ in loadNotes() }
            .onChange(of: selectedTags) { _, _ in loadNotes() }
            .confirmationDialog("Note Actions", isPresented: $showingNoteContextMenu, titleVisibility: .visible) {
                if let noteId = contextMenuNoteId, let note = notes.first(where: { $0.id == noteId }) {
                    Button("Rename") {
                        editingNoteId = note.id
                        editingNoteTitle = note.title
                    }
                    Button("Delete", role: .destructive) {
                        deleteNote(note.id)
                    }
                }
            }
            .confirmationDialog("Folder Actions", isPresented: $showingFolderContextMenu, titleVisibility: .visible) {
                if let folderId = contextMenuFolderId {
                    Button("Delete Folder", role: .destructive) {
                        DatabaseHelper.shared.deleteFolder(id: folderId)
                        loadNotes()
                    }
                }
            }
        } detail: {
            if let noteId = selectedNoteId {
                if let note = notes.first(where: { $0.id == noteId }), note.isTextOnly {
                    TextEditorView(noteId: noteId)
                } else {
                    CanvasView(noteId: noteId)
                }
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
        
        // Select last edited note on startup if no note is selected
        if selectedNoteId == nil && !notes.isEmpty {
            let sortedNotes = notes.sorted { $0.modifiedAt > $1.modifiedAt }
            if let lastNote = sortedNotes.first {
                selectedNoteId = lastNote.id
            }
        }
        
        // Check for notes with text content but not marked as text-only
        for note in notes {
            if !note.isTextOnly, let textContent = DatabaseHelper.shared.getTextContent(noteId: note.id), !textContent.isEmpty {
                // Update note to be text-only
                DatabaseHelper.shared.updateNoteType(id: note.id, isTextOnly: true)
                // Reload to get updated note
                let updatedNotes = DatabaseHelper.shared.getAllNotes(
                    searchQuery: searchQuery,
                    sortBy: sortBy,
                    filterTags: Array(selectedTags)
                )
                notes = updatedNotes
                break
            }
        }
    }
    
    private func createNewNote(isTextOnly: Bool) {
        let noteId = DatabaseHelper.shared.createNote(title: "New Note", isTextOnly: isTextOnly)
        selectedNoteId = noteId
        loadNotes()
    }
    
    private func showNoteContextMenu(noteId: Int, position: CGPoint) {
        contextMenuNoteId = noteId
        showingNoteContextMenu = true
    }
    
    private func showFolderContextMenu(folderId: Int, position: CGPoint) {
        contextMenuFolderId = folderId
        showingFolderContextMenu = true
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
    let onLongPress: ((CGPoint) -> Void)?
    
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
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                onTap()
            }
        }
        .onLongPressGesture { location in
            if !isEditing, let onLongPress = onLongPress {
                onLongPress(location)
            }
        }
    }
}

