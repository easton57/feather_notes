import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../database_helper.dart';

/// Represents a queued sync operation
enum SyncOperationType {
  upload,
  download,
  delete,
}

/// A sync operation queued for offline execution
class QueuedSyncOperation {
  final int id;
  final SyncOperationType type;
  final int noteId;
  final String? remotePath;
  final Map<String, dynamic>? noteData;
  final DateTime createdAt;
  final int retryCount;

  QueuedSyncOperation({
    required this.id,
    required this.type,
    required this.noteId,
    this.remotePath,
    this.noteData,
    required this.createdAt,
    this.retryCount = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type.name,
      'note_id': noteId,
      'remote_path': remotePath,
      'note_data': noteData != null ? jsonEncode(noteData) : null,
      'created_at': createdAt.millisecondsSinceEpoch,
      'retry_count': retryCount,
    };
  }

  factory QueuedSyncOperation.fromMap(Map<String, dynamic> map) {
    return QueuedSyncOperation(
      id: map['id'] as int,
      type: SyncOperationType.values.firstWhere(
        (e) => e.name == map['type'] as String,
      ),
      noteId: map['note_id'] as int,
      remotePath: map['remote_path'] as String?,
      noteData: map['note_data'] != null
          ? jsonDecode(map['note_data'] as String) as Map<String, dynamic>
          : null,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      retryCount: map['retry_count'] as int? ?? 0,
    );
  }
}

/// Manages the offline sync queue
class SyncQueue {
  static final SyncQueue _instance = SyncQueue._internal();
  factory SyncQueue() => _instance;
  SyncQueue._internal();

  Database? _db;

  /// Initialize the sync queue (creates table if needed)
  Future<void> initialize() async {
    _db = await DatabaseHelper.instance.database;
    await _createTable();
  }

  /// Create the sync_queue table
  Future<void> _createTable() async {
    if (_db == null) {
      await initialize();
    }

    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        type TEXT NOT NULL,
        note_id INTEGER NOT NULL,
        remote_path TEXT,
        note_data TEXT,
        created_at INTEGER NOT NULL,
        retry_count INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Create index for faster queries
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_sync_queue_note_id 
      ON sync_queue(note_id)
    ''');
  }

  /// Add an operation to the queue
  Future<int> enqueue(QueuedSyncOperation operation) async {
    if (_db == null) {
      await initialize();
    }

    // Check if operation already exists for this note
    final existing = await _db!.query(
      'sync_queue',
      where: 'note_id = ? AND type = ?',
      whereArgs: [operation.noteId, operation.type.name],
    );

    if (existing.isNotEmpty) {
      // Update existing operation
      return await _db!.update(
        'sync_queue',
        operation.toMap(),
        where: 'id = ?',
        whereArgs: [existing.first['id']],
      );
    }

    return await _db!.insert('sync_queue', operation.toMap());
  }

  /// Get all queued operations
  Future<List<QueuedSyncOperation>> getAll() async {
    if (_db == null) {
      await initialize();
    }

    final maps = await _db!.query(
      'sync_queue',
      orderBy: 'created_at ASC',
    );

    return maps.map((map) => QueuedSyncOperation.fromMap(map)).toList();
  }

  /// Get operations for a specific note
  Future<List<QueuedSyncOperation>> getForNote(int noteId) async {
    if (_db == null) {
      await initialize();
    }

    final maps = await _db!.query(
      'sync_queue',
      where: 'note_id = ?',
      whereArgs: [noteId],
      orderBy: 'created_at ASC',
    );

    return maps.map((map) => QueuedSyncOperation.fromMap(map)).toList();
  }

  /// Remove an operation from the queue
  Future<void> dequeue(int operationId) async {
    if (_db == null) {
      await initialize();
    }

    await _db!.delete(
      'sync_queue',
      where: 'id = ?',
      whereArgs: [operationId],
    );
  }

  /// Remove all operations for a note
  Future<void> clearForNote(int noteId) async {
    if (_db == null) {
      await initialize();
    }

    await _db!.delete(
      'sync_queue',
      where: 'note_id = ?',
      whereArgs: [noteId],
    );
  }

  /// Clear all queued operations
  Future<void> clear() async {
    if (_db == null) {
      await initialize();
    }

    await _db!.delete('sync_queue');
  }

  /// Increment retry count for an operation
  Future<void> incrementRetry(int operationId) async {
    if (_db == null) {
      await initialize();
    }

    final operation = await _db!.query(
      'sync_queue',
      where: 'id = ?',
      whereArgs: [operationId],
    );

    if (operation.isNotEmpty) {
      final retryCount = (operation.first['retry_count'] as int? ?? 0) + 1;
      await _db!.update(
        'sync_queue',
        {'retry_count': retryCount},
        where: 'id = ?',
        whereArgs: [operationId],
      );
    }
  }

  /// Get count of queued operations
  Future<int> getCount() async {
    if (_db == null) {
      await initialize();
    }

    final result = await _db!.rawQuery('SELECT COUNT(*) as count FROM sync_queue');
    return Sqflite.firstIntValue(result) ?? 0;
  }
}

