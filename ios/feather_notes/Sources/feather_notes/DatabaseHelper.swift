import Foundation
import SQLite3

class DatabaseHelper {
    nonisolated(unsafe) static let shared = DatabaseHelper()
    private var db: OpaquePointer?
    private let dbName = "feather_notes.db"
    private let queue = DispatchQueue(label: "com.feathernotes.database", attributes: .concurrent)
    
    private init() {
        openDatabase()
    }
    
    private func openDatabase() {
        let fileURL = try! FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent(dbName)
        
        if sqlite3_open(fileURL.path, &db) != SQLITE_OK {
            print("Unable to open database")
        } else {
            createTables()
        }
    }
    
    private func createTables() {
        // Folders table
        let createFoldersTable = """
        CREATE TABLE IF NOT EXISTS folders (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            sort_order INTEGER DEFAULT 0
        )
        """
        executeSQL(createFoldersTable)
        
        // Notes table
        let createNotesTable = """
        CREATE TABLE IF NOT EXISTS notes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            modified_at INTEGER NOT NULL,
            folder_id INTEGER,
            FOREIGN KEY (folder_id) REFERENCES folders (id) ON DELETE SET NULL
        )
        """
        executeSQL(createNotesTable)
        
        // Note tags table
        let createNoteTagsTable = """
        CREATE TABLE IF NOT EXISTS note_tags (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            note_id INTEGER NOT NULL,
            tag TEXT NOT NULL,
            FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE,
            UNIQUE(note_id, tag)
        )
        """
        executeSQL(createNoteTagsTable)
        
        // Strokes table
        let createStrokesTable = """
        CREATE TABLE IF NOT EXISTS strokes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            note_id INTEGER NOT NULL,
            stroke_index INTEGER NOT NULL,
            data TEXT NOT NULL,
            FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
        )
        """
        executeSQL(createStrokesTable)
        
        // Text elements table
        let createTextElementsTable = """
        CREATE TABLE IF NOT EXISTS text_elements (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            note_id INTEGER NOT NULL,
            text_index INTEGER NOT NULL,
            position_x REAL NOT NULL,
            position_y REAL NOT NULL,
            text TEXT NOT NULL,
            font_size REAL DEFAULT 16.0,
            FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
        )
        """
        executeSQL(createTextElementsTable)
        
        // Canvas state table
        let createCanvasStateTable = """
        CREATE TABLE IF NOT EXISTS canvas_state (
            note_id INTEGER PRIMARY KEY,
            matrix_data TEXT NOT NULL,
            scale REAL NOT NULL,
            FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
        )
        """
        executeSQL(createCanvasStateTable)
        
        // Create indices
        executeSQL("CREATE INDEX IF NOT EXISTS idx_notes_folder_id ON notes(folder_id)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_strokes_note_id ON strokes(note_id)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_text_elements_note_id ON text_elements(note_id)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_note_tags_note_id ON note_tags(note_id)")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_note_tags_tag ON note_tags(tag)")
    }
    
    private func executeSQL(_ sql: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) != SQLITE_DONE {
                let errMsg = String(cString: sqlite3_errmsg(db))
                print("Error executing SQL: \(errMsg)")
            }
        } else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            print("Error preparing SQL: \(errMsg)")
        }
        sqlite3_finalize(statement)
    }
    
    // MARK: - Note Operations
    func createNote(title: String, folderId: Int? = nil) -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = "INSERT INTO notes (title, created_at, modified_at, folder_id) VALUES (?, ?, ?, ?)"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, now)
            sqlite3_bind_int64(statement, 3, now)
            if let folderId = folderId {
                sqlite3_bind_int64(statement, 4, Int64(folderId))
            } else {
                sqlite3_bind_null(statement, 4)
            }
            
            if sqlite3_step(statement) == SQLITE_DONE {
                let noteId = Int(sqlite3_last_insert_rowid(db))
                // Initialize canvas state
                initializeCanvasState(noteId: noteId)
                sqlite3_finalize(statement)
                return noteId
            }
        }
        sqlite3_finalize(statement)
        return -1
    }
    
    private func initializeCanvasState(noteId: Int) {
        let matrixData = matrixToJSON(Matrix4.identity)
        let sql = "INSERT INTO canvas_state (note_id, matrix_data, scale) VALUES (?, ?, ?)"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, Int64(noteId))
            sqlite3_bind_text(statement, 2, (matrixData as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 3, 1.0)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
    
    func getAllNotes(searchQuery: String? = nil, sortBy: String = "id", filterTags: [String] = [], folderId: Int? = nil) -> [Note] {
        var sql = "SELECT id, title, created_at, modified_at, folder_id FROM notes WHERE 1=1"
        var statement: OpaquePointer?
        var notes: [Note] = []
        
        // Build WHERE clause
        if let searchQuery = searchQuery, !searchQuery.isEmpty {
            sql += " AND title LIKE ?"
        }
        
        if !filterTags.isEmpty {
            let placeholders = filterTags.map { _ in "?" }.joined(separator: ",")
            sql += " AND id IN (SELECT DISTINCT note_id FROM note_tags WHERE tag IN (\(placeholders)))"
        }
        
        if folderId != nil {
            sql += " AND folder_id = ?"
        }
        
        // Build ORDER BY clause
        switch sortBy {
        case "title":
            sql += " ORDER BY title ASC"
        case "date_created":
            sql += " ORDER BY created_at ASC"
        case "date_modified":
            sql += " ORDER BY modified_at DESC"
        default:
            sql += " ORDER BY id ASC"
        }
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            var bindIndex: Int32 = 1
            
            if let searchQuery = searchQuery, !searchQuery.isEmpty {
                let searchPattern = "%\(searchQuery)%"
                sqlite3_bind_text(statement, bindIndex, (searchPattern as NSString).utf8String, -1, nil)
                bindIndex += 1
            }
            
            for tag in filterTags {
                sqlite3_bind_text(statement, bindIndex, (tag as NSString).utf8String, -1, nil)
                bindIndex += 1
            }
            
            if let folderId = folderId {
                sqlite3_bind_int64(statement, bindIndex, Int64(folderId))
            }
            
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let title = String(cString: sqlite3_column_text(statement, 1))
                let createdAt = sqlite3_column_int64(statement, 2)
                let modifiedAt = sqlite3_column_int64(statement, 3)
                let folderId = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 4))
                let tags = getNoteTags(noteId: id)
                
                notes.append(Note(id: id, title: title, createdAt: createdAt, modifiedAt: modifiedAt, folderId: folderId, tags: tags))
            }
        }
        sqlite3_finalize(statement)
        return notes
    }
    
    func getNote(id: Int) -> Note? {
        let sql = "SELECT id, title, created_at, modified_at, folder_id FROM notes WHERE id = ?"
        var statement: OpaquePointer?
        var note: Note?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, Int64(id))
            
            if sqlite3_step(statement) == SQLITE_ROW {
                let noteId = Int(sqlite3_column_int64(statement, 0))
                let title = String(cString: sqlite3_column_text(statement, 1))
                let createdAt = sqlite3_column_int64(statement, 2)
                let modifiedAt = sqlite3_column_int64(statement, 3)
                let folderId = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(statement, 4))
                let tags = getNoteTags(noteId: noteId)
                
                note = Note(id: noteId, title: title, createdAt: createdAt, modifiedAt: modifiedAt, folderId: folderId, tags: tags)
            }
        }
        sqlite3_finalize(statement)
        return note
    }
    
    func updateNoteTitle(id: Int, title: String) {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = "UPDATE notes SET title = ?, modified_at = ? WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, now)
            sqlite3_bind_int64(statement, 3, Int64(id))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
    
    func deleteNote(id: Int) {
        let sql = "DELETE FROM notes WHERE id = ?"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, Int64(id))
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
    
    // MARK: - Tag Operations
    func getNoteTags(noteId: Int) -> [String] {
        let sql = "SELECT tag FROM note_tags WHERE note_id = ?"
        var statement: OpaquePointer?
        var tags: [String] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, Int64(noteId))
            
            while sqlite3_step(statement) == SQLITE_ROW {
                if let tag = sqlite3_column_text(statement, 0) {
                    tags.append(String(cString: tag))
                }
            }
        }
        sqlite3_finalize(statement)
        return tags
    }
    
    func setNoteTags(noteId: Int, tags: [String]) {
        // Delete existing tags
        let deleteSQL = "DELETE FROM note_tags WHERE note_id = ?"
        var deleteStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStatement, 1, Int64(noteId))
            sqlite3_step(deleteStatement)
        }
        sqlite3_finalize(deleteStatement)
        
        // Insert new tags
        let insertSQL = "INSERT INTO note_tags (note_id, tag) VALUES (?, ?)"
        var insertStatement: OpaquePointer?
        
        for tag in tags where !tag.trimmingCharacters(in: .whitespaces).isEmpty {
            if sqlite3_prepare_v2(db, insertSQL, -1, &insertStatement, nil) == SQLITE_OK {
                sqlite3_bind_int64(insertStatement, 1, Int64(noteId))
                sqlite3_bind_text(insertStatement, 2, (tag.trimmingCharacters(in: .whitespaces) as NSString).utf8String, -1, nil)
                sqlite3_step(insertStatement)
                sqlite3_reset(insertStatement)
            }
        }
        sqlite3_finalize(insertStatement)
    }
    
    func getAllTags() -> [String] {
        let sql = "SELECT DISTINCT tag FROM note_tags ORDER BY tag"
        var statement: OpaquePointer?
        var tags: [String] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let tag = sqlite3_column_text(statement, 0) {
                    tags.append(String(cString: tag))
                }
            }
        }
        sqlite3_finalize(statement)
        return tags
    }
    
    // MARK: - Canvas Data Operations
    func saveCanvasData(noteId: Int, data: NoteCanvasData) {
        // Delete existing strokes and text elements
        let deleteStrokesSQL = "DELETE FROM strokes WHERE note_id = ?"
        var deleteStrokesStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteStrokesSQL, -1, &deleteStrokesStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStrokesStatement, 1, Int64(noteId))
            sqlite3_step(deleteStrokesStatement)
        }
        sqlite3_finalize(deleteStrokesStatement)
        
        let deleteTextSQL = "DELETE FROM text_elements WHERE note_id = ?"
        var deleteTextStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteTextSQL, -1, &deleteTextStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteTextStatement, 1, Int64(noteId))
            sqlite3_step(deleteTextStatement)
        }
        sqlite3_finalize(deleteTextStatement)
        
        // Insert strokes
        let insertStrokeSQL = "INSERT INTO strokes (note_id, stroke_index, data) VALUES (?, ?, ?)"
        var insertStrokeStatement: OpaquePointer?
        
        for (index, stroke) in data.strokes.enumerated() {
            if sqlite3_prepare_v2(db, insertStrokeSQL, -1, &insertStrokeStatement, nil) == SQLITE_OK {
                sqlite3_bind_int64(insertStrokeStatement, 1, Int64(noteId))
                sqlite3_bind_int64(insertStrokeStatement, 2, Int64(index))
                let strokeJSON = strokeToJSON(stroke)
                sqlite3_bind_text(insertStrokeStatement, 3, (strokeJSON as NSString).utf8String, -1, nil)
                sqlite3_step(insertStrokeStatement)
                sqlite3_reset(insertStrokeStatement)
            }
        }
        sqlite3_finalize(insertStrokeStatement)
        
        // Insert text elements
        let insertTextSQL = "INSERT INTO text_elements (note_id, text_index, position_x, position_y, text, font_size) VALUES (?, ?, ?, ?, ?, ?)"
        var insertTextStatement: OpaquePointer?
        
        for (index, textElement) in data.textElements.enumerated() {
            if sqlite3_prepare_v2(db, insertTextSQL, -1, &insertTextStatement, nil) == SQLITE_OK {
                sqlite3_bind_int64(insertTextStatement, 1, Int64(noteId))
                sqlite3_bind_int64(insertTextStatement, 2, Int64(index))
                sqlite3_bind_double(insertTextStatement, 3, textElement.position.x)
                sqlite3_bind_double(insertTextStatement, 4, textElement.position.y)
                sqlite3_bind_text(insertTextStatement, 5, (textElement.text as NSString).utf8String, -1, nil)
                sqlite3_bind_double(insertTextStatement, 6, textElement.fontSize)
                sqlite3_step(insertTextStatement)
                sqlite3_reset(insertTextStatement)
            }
        }
        sqlite3_finalize(insertTextStatement)
        
        // Update canvas state
        let matrixData = matrixToJSON(data.matrix)
        let updateStateSQL = "INSERT OR REPLACE INTO canvas_state (note_id, matrix_data, scale) VALUES (?, ?, ?)"
        var updateStateStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, updateStateSQL, -1, &updateStateStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(updateStateStatement, 1, Int64(noteId))
            sqlite3_bind_text(updateStateStatement, 2, (matrixData as NSString).utf8String, -1, nil)
            sqlite3_bind_double(updateStateStatement, 3, data.scale)
            sqlite3_step(updateStateStatement)
        }
        sqlite3_finalize(updateStateStatement)
    }
    
    func loadCanvasData(noteId: Int) -> NoteCanvasData {
        var strokes: [Stroke] = []
        var textElements: [TextElement] = []
        var matrix = Matrix4.identity
        var scale: Double = 1.0
        
        // Load strokes
        let loadStrokesSQL = "SELECT data FROM strokes WHERE note_id = ? ORDER BY stroke_index ASC"
        var loadStrokesStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, loadStrokesSQL, -1, &loadStrokesStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(loadStrokesStatement, 1, Int64(noteId))
            
            while sqlite3_step(loadStrokesStatement) == SQLITE_ROW {
                if let dataText = sqlite3_column_text(loadStrokesStatement, 0) {
                    let jsonString = String(cString: dataText)
                    if let stroke = strokeFromJSON(jsonString) {
                        strokes.append(stroke)
                    }
                }
            }
        }
        sqlite3_finalize(loadStrokesStatement)
        
        // Load text elements
        let loadTextSQL = "SELECT position_x, position_y, text, font_size FROM text_elements WHERE note_id = ? ORDER BY text_index ASC"
        var loadTextStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, loadTextSQL, -1, &loadTextStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(loadTextStatement, 1, Int64(noteId))
            
            while sqlite3_step(loadTextStatement) == SQLITE_ROW {
                let x = sqlite3_column_double(loadTextStatement, 0)
                let y = sqlite3_column_double(loadTextStatement, 1)
                let text = String(cString: sqlite3_column_text(loadTextStatement, 2))
                let fontSize = sqlite3_column_double(loadTextStatement, 3)
                
                let position = DrawingPoint(x: x, y: y)
                textElements.append(TextElement(position: position, text: text, fontSize: fontSize))
            }
        }
        sqlite3_finalize(loadTextStatement)
        
        // Load canvas state
        let loadStateSQL = "SELECT matrix_data, scale FROM canvas_state WHERE note_id = ?"
        var loadStateStatement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, loadStateSQL, -1, &loadStateStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(loadStateStatement, 1, Int64(noteId))
            
            if sqlite3_step(loadStateStatement) == SQLITE_ROW {
                if let matrixDataText = sqlite3_column_text(loadStateStatement, 0) {
                    let matrixJSON = String(cString: matrixDataText)
                    matrix = matrixFromJSON(matrixJSON)
                }
                scale = sqlite3_column_double(loadStateStatement, 1)
            }
        }
        sqlite3_finalize(loadStateStatement)
        
        return NoteCanvasData(strokes: strokes, textElements: textElements, matrix: matrix, scale: scale)
    }
    
    // MARK: - Folder Operations
    func createFolder(name: String) -> Int {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let sql = "INSERT INTO folders (name, created_at, sort_order) VALUES (?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM folders))"
        var statement: OpaquePointer?
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(statement, 2, now)
            
            if sqlite3_step(statement) == SQLITE_DONE {
                let folderId = Int(sqlite3_last_insert_rowid(db))
                sqlite3_finalize(statement)
                return folderId
            }
        }
        sqlite3_finalize(statement)
        return -1
    }
    
    func getAllFolders() -> [Folder] {
        let sql = "SELECT id, name, created_at, sort_order FROM folders ORDER BY sort_order ASC, created_at ASC"
        var statement: OpaquePointer?
        var folders: [Folder] = []
        
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                let id = Int(sqlite3_column_int64(statement, 0))
                let name = String(cString: sqlite3_column_text(statement, 1))
                let createdAt = sqlite3_column_int64(statement, 2)
                let sortOrder = Int(sqlite3_column_int64(statement, 3))
                
                folders.append(Folder(id: id, name: name, createdAt: createdAt, sortOrder: sortOrder))
            }
        }
        sqlite3_finalize(statement)
        return folders
    }
    
    func deleteFolder(id: Int) {
        // Move notes to null folder
        let updateSQL = "UPDATE notes SET folder_id = NULL WHERE folder_id = ?"
        var updateStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, updateSQL, -1, &updateStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(updateStatement, 1, Int64(id))
            sqlite3_step(updateStatement)
        }
        sqlite3_finalize(updateStatement)
        
        // Delete folder
        let deleteSQL = "DELETE FROM folders WHERE id = ?"
        var deleteStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStatement, nil) == SQLITE_OK {
            sqlite3_bind_int64(deleteStatement, 1, Int64(id))
            sqlite3_step(deleteStatement)
        }
        sqlite3_finalize(deleteStatement)
    }
    
    func wipeDatabase() {
        let tables = ["note_tags", "strokes", "text_elements", "canvas_state", "notes", "folders"]
        
        for table in tables {
            let sql = "DELETE FROM \(table)"
            executeSQL(sql)
        }
    }
    
    // MARK: - JSON Serialization
    private func strokeToJSON(_ stroke: Stroke) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(stroke),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }
    
    private func strokeFromJSON(_ jsonString: String) -> Stroke? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Stroke.self, from: data)
    }
    
    private func matrixToJSON(_ matrix: Matrix4) -> String {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(matrix),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
        return "{}"
    }
    
    private func matrixFromJSON(_ jsonString: String) -> Matrix4 {
        guard let data = jsonString.data(using: .utf8) else { return .identity }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Matrix4.self, from: data)) ?? .identity
    }
    
    deinit {
        sqlite3_close(db)
    }
}

