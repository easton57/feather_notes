/// Abstract interface for cloud sync providers
abstract class SyncProvider {
  /// Provider name for display
  String get name;

  /// Provider identifier
  String get id;

  /// Whether the provider is configured and ready to sync
  Future<bool> isConfigured();

  /// Configure the provider with necessary credentials/settings
  Future<void> configure(Map<String, dynamic> config);

  /// Get current configuration
  Future<Map<String, dynamic>?> getConfiguration();

  /// Test the connection to the cloud service
  Future<bool> testConnection();

  /// Upload a note to the cloud
  /// Returns the remote path/ID of the uploaded note
  Future<String> uploadNote({
    required int noteId,
    required String title,
    required Map<String, dynamic> noteData,
  });

  /// Download a note from the cloud
  /// Returns the note data
  Future<Map<String, dynamic>?> downloadNote(String remotePath);

  /// List all notes in the cloud
  /// Returns a map of remote paths to note metadata
  Future<Map<String, Map<String, dynamic>>> listNotes();

  /// Delete a note from the cloud
  Future<void> deleteNote(String remotePath);

  /// Get the last modified timestamp for a note
  Future<DateTime?> getLastModified(String remotePath);

  /// Sync all notes (upload local changes, download remote changes)
  Future<SyncResult> syncAll({
    required List<Map<String, dynamic>> localNotes,
    required Function(int noteId, Map<String, dynamic> noteData) onNoteUpdated,
    required Function(Map<String, dynamic> noteData) onNoteCreated,
  });

  /// Disconnect/clear configuration
  Future<void> disconnect();
}

/// Result of a sync operation
class SyncResult {
  final int uploaded;
  final int downloaded;
  final int conflicts;
  final List<SyncConflict> conflictList;
  final String? error;

  SyncResult({
    this.uploaded = 0,
    this.downloaded = 0,
    this.conflicts = 0,
    this.conflictList = const [],
    this.error,
  });

  bool get hasError => error != null;
  bool get hasConflicts => conflicts > 0;
}

/// Represents a sync conflict
class SyncConflict {
  final int noteId;
  final String title;
  final Map<String, dynamic> localData;
  final Map<String, dynamic> remoteData;
  final DateTime localModified;
  final DateTime remoteModified;

  SyncConflict({
    required this.noteId,
    required this.title,
    required this.localData,
    required this.remoteData,
    required this.localModified,
    required this.remoteModified,
  });
}

/// Sync status
enum SyncStatus {
  idle,
  syncing,
  success,
  error,
  conflict,
}

/// Resolution options for sync conflicts
enum SyncConflictResolution {
  useLocal,
  useRemote,
  keepBoth,
}

