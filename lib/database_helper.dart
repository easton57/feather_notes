import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'main.dart';

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._init();
  static Database? _database;
  static bool _initialized = false;

  DatabaseHelper._init() {
    _initializeDatabaseFactory();
  }

  void _initializeDatabaseFactory() {
    if (!_initialized) {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        // Initialize FFI for desktop platforms
        // Note: This is already done in main(), but keeping here as backup
        // The warning about changing default factory is expected and harmless
        if (databaseFactory != databaseFactoryFfi) {
          databaseFactory = databaseFactoryFfi;
        }
      }
      _initialized = true;
    }
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('feather_notes.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    String path;
    
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      // For desktop platforms, use application documents directory
      final directory = await getApplicationDocumentsDirectory();
      path = join(directory.path, filePath);
    } else {
      // For mobile platforms, use the default database path
      final dbPath = await getDatabasesPath();
      path = join(dbPath, filePath);
    }

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    // Notes table
    await db.execute('''
      CREATE TABLE notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL
      )
    ''');

    // Strokes table
    await db.execute('''
      CREATE TABLE strokes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        stroke_index INTEGER NOT NULL,
        data TEXT NOT NULL,
        FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
      )
    ''');

    // Text elements table
    await db.execute('''
      CREATE TABLE text_elements (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        note_id INTEGER NOT NULL,
        text_index INTEGER NOT NULL,
        position_x REAL NOT NULL,
        position_y REAL NOT NULL,
        text TEXT NOT NULL,
        FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
      )
    ''');

    // Canvas state table
    await db.execute('''
      CREATE TABLE canvas_state (
        note_id INTEGER PRIMARY KEY,
        matrix_data TEXT NOT NULL,
        scale REAL NOT NULL,
        FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
      )
    ''');

    // Create indices for better performance
    await db.execute('CREATE INDEX idx_strokes_note_id ON strokes(note_id)');
    await db.execute('CREATE INDEX idx_text_elements_note_id ON text_elements(note_id)');
  }

  // Note operations
  Future<int> createNote(String title) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    
    final id = await db.insert('notes', {
      'title': title,
      'created_at': now,
      'modified_at': now,
    });

    // Initialize canvas state
    await db.insert('canvas_state', {
      'note_id': id,
      'matrix_data': _matrixToJson(Matrix4.identity()),
      'scale': 1.0,
    });

    return id;
  }

  Future<List<Map<String, dynamic>>> getAllNotes() async {
    final db = await database;
    // Order by ID (creation order) instead of modified_at to prevent reordering
    // when canvas data is saved
    return await db.query(
      'notes',
      orderBy: 'id ASC',
    );
  }

  Future<Map<String, dynamic>?> getNote(int id) async {
    final db = await database;
    final notes = await db.query(
      'notes',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return notes.isNotEmpty ? notes.first : null;
  }

  Future<int> updateNoteTitle(int id, String title) async {
    final db = await database;
    return await db.update(
      'notes',
      {
        'title': title,
        'modified_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteNote(int id) async {
    final db = await database;
    return await db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  // Canvas data operations
  Future<void> saveCanvasData(int noteId, NoteCanvasData data) async {
    final db = await database;
    final batch = db.batch();

    // Don't update modified_at when saving canvas data to prevent note reordering
    // Only update modified_at when the title changes

    // Delete existing strokes and text elements
    batch.delete('strokes', where: 'note_id = ?', whereArgs: [noteId]);
    batch.delete('text_elements', where: 'note_id = ?', whereArgs: [noteId]);

    // Insert strokes
    for (var i = 0; i < data.strokes.length; i++) {
      batch.insert('strokes', {
        'note_id': noteId,
        'stroke_index': i,
        'data': _strokeToJson(data.strokes[i]),
      });
    }

    // Insert text elements
    for (var i = 0; i < data.textElements.length; i++) {
      final textEl = data.textElements[i];
      batch.insert('text_elements', {
        'note_id': noteId,
        'text_index': i,
        'position_x': textEl.position.dx,
        'position_y': textEl.position.dy,
        'text': textEl.text,
      });
    }

    // Update canvas state
    batch.insert(
      'canvas_state',
      {
        'note_id': noteId,
        'matrix_data': _matrixToJson(data.matrix),
        'scale': data.scale,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    await batch.commit(noResult: true);
  }

  Future<NoteCanvasData> loadCanvasData(int noteId) async {
    final db = await database;

    // Load strokes
    final strokeRows = await db.query(
      'strokes',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'stroke_index ASC',
    );
    final strokes = strokeRows.map((row) => _strokeFromJson(row['data'] as String)).toList();

    // Load text elements
    final textRows = await db.query(
      'text_elements',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'text_index ASC',
    );
    final textElements = textRows.map((row) => TextElement(
      Offset(row['position_x'] as double, row['position_y'] as double),
      row['text'] as String,
    )).toList();

    // Load canvas state
    final stateRows = await db.query(
      'canvas_state',
      where: 'note_id = ?',
      whereArgs: [noteId],
      limit: 1,
    );

    Matrix4 matrix = Matrix4.identity();
    double scale = 1.0;

    if (stateRows.isNotEmpty) {
      matrix = _matrixFromJson(stateRows.first['matrix_data'] as String);
      scale = stateRows.first['scale'] as double;
    }

    return NoteCanvasData(
      strokes: strokes,
      textElements: textElements,
      matrix: matrix,
      scale: scale,
    );
  }

  // Serialization helpers
  String _strokeToJson(Stroke stroke) {
    final points = stroke.points.map((p) => {
      'x': p.position.dx,
      'y': p.position.dy,
      'pressure': p.pressure,
    }).toList();
    return jsonEncode({
      'points': points,
      'color': stroke.color.value,
    });
  }

  Stroke _strokeFromJson(String json) {
    final Map<String, dynamic> data = jsonDecode(json);
    final List<dynamic> pointsData = data['points'] as List<dynamic>? ?? [];
    final points = pointsData.map((p) => Point(
      Offset(p['x'] as double, p['y'] as double),
      p['pressure'] as double,
    )).toList();
    final colorValue = data['color'] as int?;
    final color = colorValue != null ? Color(colorValue) : Colors.black;
    return Stroke(points, color: color);
  }

  String _matrixToJson(Matrix4 matrix) {
    final values = matrix.storage;
    return jsonEncode(values);
  }

  Matrix4 _matrixFromJson(String json) {
    final List<dynamic> values = jsonDecode(json);
    return Matrix4.fromList(values.map((v) => v as double).toList());
  }

  // Export/Import functions
  Future<Map<String, dynamic>> exportNote(int noteId) async {
    final note = await getNote(noteId);
    if (note == null) throw Exception('Note not found');

    final canvasData = await loadCanvasData(noteId);

    return {
      'version': '1.0',
      'note': {
        'id': note['id'],
        'title': note['title'],
        'created_at': note['created_at'],
        'modified_at': note['modified_at'],
      },
      'canvas': {
        'strokes': canvasData.strokes.map((s) => _strokeToJson(s)).toList(),
        'text_elements': canvasData.textElements.map((te) => {
          'position': {'x': te.position.dx, 'y': te.position.dy},
          'text': te.text,
        }).toList(),
        'matrix': _matrixToJson(canvasData.matrix),
        'scale': canvasData.scale,
      },
    };
  }

  Future<Map<String, dynamic>> exportAllNotes() async {
    final notes = await getAllNotes();
    final exportedNotes = <Map<String, dynamic>>[];

    for (final note in notes) {
      final noteId = note['id'] as int;
      exportedNotes.add(await exportNote(noteId));
    }

    return {
      'version': '1.0',
      'export_date': DateTime.now().millisecondsSinceEpoch,
      'notes': exportedNotes,
    };
  }

  Future<int> importNote(Map<String, dynamic> noteData) async {
    final note = noteData['note'] as Map<String, dynamic>;
    final canvas = noteData['canvas'] as Map<String, dynamic>;

    // Create note
    final noteId = await createNote(note['title'] as String);

    // Reconstruct canvas data
    final strokes = (canvas['strokes'] as List<dynamic>)
        .map((s) => _strokeFromJson(s as String))
        .toList();

    final textElements = (canvas['text_elements'] as List<dynamic>)
        .map((te) {
          final pos = te['position'] as Map<String, dynamic>;
          return TextElement(
            Offset(pos['x'] as double, pos['y'] as double),
            te['text'] as String,
          );
        })
        .toList();

    final matrix = _matrixFromJson(canvas['matrix'] as String);
    final scale = canvas['scale'] as double? ?? 1.0;

    final canvasData = NoteCanvasData(
      strokes: strokes,
      textElements: textElements,
      matrix: matrix,
      scale: scale,
    );

    await saveCanvasData(noteId, canvasData);

    return noteId;
  }

  Future<void> importAllNotes(Map<String, dynamic> exportData) async {
    final notes = exportData['notes'] as List<dynamic>;
    for (final noteData in notes) {
      await importNote(noteData as Map<String, dynamic>);
    }
  }

  // Get database file path for manual export
  Future<String> getDatabasePath() async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final directory = await getApplicationDocumentsDirectory();
      return join(directory.path, 'feather_notes.db');
    } else {
      final dbPath = await getDatabasesPath();
      return join(dbPath, 'feather_notes.db');
    }
  }

  // Close database
  Future<void> close() async {
    final db = await database;
    await db.close();
  }
}

