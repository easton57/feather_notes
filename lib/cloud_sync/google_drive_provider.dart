import 'dart:convert';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;
import 'sync_provider.dart';

/// Google Drive sync provider using Google Drive API
class GoogleDriveProvider implements SyncProvider {
  static const String _providerId = 'google_drive';
  static const String _folderName = 'feather_notes';
  
  // Google Drive API scopes
  static const List<String> _scopes = [
    'https://www.googleapis.com/auth/drive.file', // Access to files created by the app
  ];

  GoogleSignInAccount? _currentAccount;
  drive.DriveApi? _driveApi;
  String? _folderId;
  bool _initialized = false;

  @override
  String get name => 'Google Drive';

  @override
  String get id => _providerId;

  /// Initialize GoogleSignIn if not already initialized
  Future<void> _ensureInitialized({String? clientId}) async {
    if (!_initialized) {
      await GoogleSignIn.instance.initialize(
        clientId: clientId,
      );
      _initialized = true;
    }
  }

  @override
  Future<bool> isConfigured() async {
    try {
      await _ensureInitialized();
      final account = await GoogleSignIn.instance.attemptLightweightAuthentication();
      _currentAccount = account;
      return account != null;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<void> configure(Map<String, dynamic> config) async {
    // Google Drive uses OAuth2, so configuration is handled through sign-in
    // The config can contain clientId for custom OAuth setup if needed
    final clientId = config['clientId']?.toString();
    
    // Initialize GoogleSignIn
    await _ensureInitialized(clientId: clientId);
    
    // Try lightweight authentication first
    GoogleSignInAccount? account = await GoogleSignIn.instance.attemptLightweightAuthentication();
    
    // If that fails, do full authentication
    account ??= await GoogleSignIn.instance.authenticate();
    
    _currentAccount = account;
    
    // Get authentication headers with authorization for the required scopes
    final authHeaders = await account.authorizationClient.authorizationHeaders(
      _scopes,
      promptIfNecessary: true,
    );
    
    if (authHeaders == null) {
      throw Exception('Failed to get authentication headers');
    }
    
    // Create Drive API client
    final client = GoogleAuthClient(authHeaders);
    _driveApi = drive.DriveApi(client);
    
    // Ensure folder exists
    await _ensureFolder();
  }

  @override
  Future<Map<String, dynamic>?> getConfiguration() async {
    if (!await isConfigured()) {
      return null;
    }
    
    return {
      'email': _currentAccount?.email,
      'isSignedIn': _currentAccount != null,
    };
  }

  @override
  Future<bool> testConnection() async {
    if (!await isConfigured()) {
      return false;
    }
    
    try {
      // Try to get the folder to test connection
      await _ensureFolder();
      return true;
    } catch (e) {
      return false;
    }
  }

  @override
  Future<String> uploadNote({
    required int noteId,
    required String title,
    required Map<String, dynamic> noteData,
  }) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    // Refresh auth headers to ensure they're valid
    await _refreshAuthHeaders();
    await _ensureFolder();

    final fileName = 'note_$noteId.json';
    final fileContent = utf8.encode(jsonEncode(noteData));

    // Check if file already exists
    final existingFile = await _findFile(fileName);
    
    if (existingFile != null) {
      // Update existing file
      final media = drive.Media(
        Stream.value(fileContent),
        fileContent.length,
      );
      
      await _driveApi!.files.update(
        drive.File()..name = fileName,
        existingFile.id!,
        uploadMedia: media,
      );
      
      return existingFile.id!;
    } else {
      // Create new file
      final file = drive.File()
        ..name = fileName
        ..parents = [_folderId!];
      
      final media = drive.Media(
        Stream.value(fileContent),
        fileContent.length,
      );
      
      final createdFile = await _driveApi!.files.create(
        file,
        uploadMedia: media,
      );
      
      return createdFile.id!;
    }
  }

  @override
  Future<Map<String, dynamic>?> downloadNote(String remotePath) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    // Refresh auth headers to ensure they're valid
    await _refreshAuthHeaders();

    // remotePath is the file ID in Google Drive
    try {
      final media = await _driveApi!.files.get(
        remotePath,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      
      final stream = media.stream;
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
      final jsonString = utf8.decode(bytes);
      
      return jsonDecode(jsonString) as Map<String, dynamic>;
    } catch (e) {
      if (e.toString().contains('404')) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> listNotes() async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    // Refresh auth headers to ensure they're valid
    await _refreshAuthHeaders();
    await _ensureFolder();

    final notes = <String, Map<String, dynamic>>{};
    
    // List files in the folder
    final response = await _driveApi!.files.list(
      q: "'$_folderId' in parents and name contains 'note_' and name ends with '.json'",
    );

    for (final file in response.files ?? []) {
      if (file.id == null || file.name == null) continue;
      
      DateTime? modified;
      if (file.modifiedTime != null) {
        modified = file.modifiedTime.toLocal();
      }
      
      notes[file.id!] = {
        'remotePath': file.id!,
        'name': file.name,
        'modified_at': modified?.toIso8601String() ?? DateTime.now().toIso8601String(),
      };
    }

    return notes;
  }

  @override
  Future<void> deleteNote(String remotePath) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    // Refresh auth headers to ensure they're valid
    await _refreshAuthHeaders();

    try {
      await _driveApi!.files.delete(remotePath);
    } catch (e) {
      if (!e.toString().contains('404')) {
        rethrow;
      }
      // File not found, consider it deleted
    }
  }

  @override
  Future<DateTime?> getLastModified(String remotePath) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    // Refresh auth headers to ensure they're valid
    await _refreshAuthHeaders();

    try {
      final file = await _driveApi!.files.get(remotePath) as drive.File;
      
      return file.modifiedTime?.toLocal();
    } catch (e) {
      return null;
    }
  }

  @override
  Future<SyncResult> syncAll({
    required List<Map<String, dynamic>> localNotes,
    required Function(int noteId, Map<String, dynamic> noteData) onNoteUpdated,
    required Function(Map<String, dynamic> noteData) onNoteCreated,
  }) async {
    if (_driveApi == null || _currentAccount == null) {
      return SyncResult(error: 'Google Drive provider not configured');
    }

    try {
      // Refresh auth headers to ensure they're valid
      await _refreshAuthHeaders();
      await _ensureFolder();

      // List remote notes
      final remoteNotes = await listNotes();
      
      int uploaded = 0;
      int downloaded = 0;
      int conflicts = 0;
      final conflictList = <SyncConflict>[];

      // Create a map of local notes by ID
      final localNotesMap = <int, Map<String, dynamic>>{};
      for (final noteData in localNotes) {
        final noteId = noteData['note']?['id'] as int?;
        if (noteId != null) {
          localNotesMap[noteId] = noteData;
        }
      }

      // Create a map of remote notes by note ID (extracted from filename)
      final remoteNotesByNoteId = <int, Map<String, dynamic>>{};
      for (final entry in remoteNotes.entries) {
        final fileName = entry.value['name'] as String?;
        if (fileName != null && fileName.startsWith('note_') && fileName.endsWith('.json')) {
          final noteIdStr = fileName.substring(5, fileName.length - 5);
          final noteId = int.tryParse(noteIdStr);
          if (noteId != null) {
            remoteNotesByNoteId[noteId] = entry.value;
          }
        }
      }

      // Upload new/modified local notes
      for (final noteData in localNotes) {
        final note = noteData['note'] as Map<String, dynamic>?;
        if (note == null) continue;

        final noteId = note['id'] as int?;
        final title = note['title'] as String? ?? 'Untitled';
        if (noteId == null) continue;

        final remoteMetadata = remoteNotesByNoteId[noteId];
        if (remoteMetadata != null) {
          // Note exists remotely, check if we need to update
          final localModified = _parseDateTime(note['modified_at']);
          final remoteModified = _parseDateTime(remoteMetadata['modified_at']);

          if (localModified != null && remoteModified != null) {
            if (localModified.isAfter(remoteModified)) {
              // Local is newer, upload
              await uploadNote(noteId: noteId, title: title, noteData: noteData);
              uploaded++;
            } else if (remoteModified.isAfter(localModified)) {
              // Remote is newer, download
              final remotePath = remoteMetadata['remotePath'] as String?;
              if (remotePath != null) {
                final remoteData = await downloadNote(remotePath);
                if (remoteData != null) {
                  onNoteUpdated(noteId, remoteData);
                  downloaded++;
                }
              }
            }
            // If equal, skip (already in sync)
          } else {
            // Can't compare, upload to be safe
            await uploadNote(noteId: noteId, title: title, noteData: noteData);
            uploaded++;
          }
        } else {
          // New note, upload
          await uploadNote(noteId: noteId, title: title, noteData: noteData);
          uploaded++;
        }
      }

      // Download new remote notes
      for (final entry in remoteNotesByNoteId.entries) {
        final noteId = entry.key;
        final remoteMetadata = entry.value;

        if (localNotesMap.containsKey(noteId)) {
          continue; // Already processed
        }

        // New remote note, download it
        final remotePath = remoteMetadata['remotePath'] as String?;
        if (remotePath != null) {
          final remoteData = await downloadNote(remotePath);
          if (remoteData != null) {
            onNoteCreated(remoteData);
            downloaded++;
          }
        }
      }

      return SyncResult(
        uploaded: uploaded,
        downloaded: downloaded,
        conflicts: conflicts,
        conflictList: conflictList,
      );
    } catch (e) {
      return SyncResult(error: e.toString());
    }
  }

  /// Refresh authentication headers and update the Drive API client
  Future<void> _refreshAuthHeaders() async {
    if (_currentAccount == null) {
      throw Exception('No account available');
    }
    
    final authHeaders = await _currentAccount!.authorizationClient.authorizationHeaders(
      _scopes,
      promptIfNecessary: true,
    );
    
    if (authHeaders == null) {
      throw Exception('Failed to refresh authentication headers');
    }
    
    final client = GoogleAuthClient(authHeaders);
    _driveApi = drive.DriveApi(client);
  }

  @override
  Future<String> uploadFolder({
    required int folderId,
    required String name,
    required Map<String, dynamic> folderData,
  }) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    await _refreshAuthHeaders();
    await _ensureFolder();

    final fileName = 'folder_$folderId.json';
    final fileContent = utf8.encode(jsonEncode(folderData));

    final existingFile = await _findFile(fileName);
    
    if (existingFile != null) {
      final media = drive.Media(
        Stream.value(fileContent),
        fileContent.length,
      );
      
      await _driveApi!.files.update(
        drive.File()..name = fileName,
        existingFile.id!,
        uploadMedia: media,
      );
      
      return existingFile.id!;
    } else {
      final file = drive.File()
        ..name = fileName
        ..parents = [_folderId!];
      
      final media = drive.Media(
        Stream.value(fileContent),
        fileContent.length,
      );
      
      final createdFile = await _driveApi!.files.create(
        file,
        uploadMedia: media,
      );
      
      return createdFile.id!;
    }
  }

  @override
  Future<Map<String, dynamic>?> downloadFolder(String remotePath) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    await _refreshAuthHeaders();
    
    // remotePath is a file ID for Google Drive
    try {
      final file = await _driveApi!.files.get(
        remotePath,
        downloadOptions: drive.DownloadOptions.fullMedia,
      ) as drive.Media;
      
      final response = await file.stream.toList();
      final bytes = response.expand((chunk) => chunk).toList();
      final content = utf8.decode(bytes);
      
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      if (e.toString().contains('404')) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> listFolders() async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    await _refreshAuthHeaders();
    await _ensureFolder();

    final folders = <String, Map<String, dynamic>>{};
    
    final response = await _driveApi!.files.list(
      q: "'$_folderId' in parents and name contains 'folder_' and name ends with '.json' and trashed=false",
    );

    if (response.files != null) {
      for (final file in response.files!) {
        if (file.name != null && file.id != null) {
          folders[file.id!] = {
            'name': file.name,
            'id': file.id,
            'modifiedTime': file.modifiedTime?.toIso8601String(),
          };
        }
      }
    }

    return folders;
  }

  @override
  Future<void> deleteFolder(String remotePath) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    await _refreshAuthHeaders();
    
    try {
      await _driveApi!.files.delete(remotePath);
    } catch (e) {
      if (!e.toString().contains('404')) {
        rethrow;
      }
    }
  }

  @override
  Future<void> syncFolders({
    required List<Map<String, dynamic>> localFolders,
    required Function(int folderId, Map<String, dynamic> folderData) onFolderUpdated,
    required Function(Map<String, dynamic> folderData) onFolderCreated,
  }) async {
    if (_driveApi == null || _currentAccount == null) {
      throw Exception('Google Drive provider not configured');
    }

    try {
      await _refreshAuthHeaders();
      await _ensureFolder();

      final remoteFolders = await listFolders();
      final localFoldersMap = <int, Map<String, dynamic>>{};
      for (final folder in localFolders) {
        final folderId = folder['id'] as int?;
        if (folderId != null) {
          localFoldersMap[folderId] = folder;
        }
      }

      // Create a map of remote folders by folder ID (extracted from filename)
      final remoteFoldersByFolderId = <int, Map<String, dynamic>>{};
      for (final entry in remoteFolders.entries) {
        final fileName = entry.value['name'] as String?;
        if (fileName != null && fileName.startsWith('folder_') && fileName.endsWith('.json')) {
          final folderIdStr = fileName.substring(7, fileName.length - 5);
          final folderId = int.tryParse(folderIdStr);
          if (folderId != null) {
            remoteFoldersByFolderId[folderId] = {
              ...entry.value,
              'fileId': entry.key,
            };
          }
        }
      }

      // Upload local folders
      for (final folder in localFolders) {
        final folderId = folder['id'] as int?;
        final name = folder['name'] as String?;
        if (folderId == null || name == null) continue;

        try {
          await uploadFolder(
            folderId: folderId,
            name: name,
            folderData: folder,
          );
        } catch (e) {
          print('Error uploading folder $folderId: $e');
        }
      }

      // Download remote folders
      for (final entry in remoteFoldersByFolderId.entries) {
        final remoteFolderId = entry.key;
        final fileId = entry.value['fileId'] as String?;
        
        if (fileId == null) continue;

        if (localFoldersMap.containsKey(remoteFolderId)) {
          // Folder exists locally, check if we need to update
          final localFolder = localFoldersMap[remoteFolderId]!;
          final remoteModified = entry.value['modifiedTime'] as String?;
          final localModified = localFolder['created_at'] as int?;
          
          if (localModified != null && remoteModified != null) {
            try {
              final remoteModifiedDate = DateTime.parse(remoteModified);
              final localModifiedDate = DateTime.fromMillisecondsSinceEpoch(localModified, isUtc: true).toLocal();
              if (remoteModifiedDate.isAfter(localModifiedDate)) {
                // Remote is newer, download it
                try {
                  final remoteData = await downloadFolder(fileId);
                  if (remoteData != null) {
                    await onFolderUpdated(remoteFolderId, remoteData);
                  }
                } catch (e) {
                  print('Error downloading folder $remoteFolderId: $e');
                }
              }
            } catch (e) {
              // Ignore parse errors
            }
          }
        } else {
          // New remote folder, download it
          try {
            final remoteData = await downloadFolder(fileId);
            if (remoteData != null) {
              await onFolderCreated(remoteData);
            }
          } catch (e) {
            print('Error downloading new folder $remoteFolderId: $e');
          }
        }
      }
    } catch (e) {
      print('Error syncing folders: $e');
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    await GoogleSignIn.instance.signOut();
    _currentAccount = null;
    _driveApi = null;
    _folderId = null;
    _initialized = false;
  }

  /// Ensure the feather_notes folder exists in Google Drive
  Future<void> _ensureFolder() async {
    if (_driveApi == null) {
      throw Exception('Google Drive not configured');
    }

    // Check if folder already exists
    final response = await _driveApi!.files.list(
      q: "name='$_folderName' and mimeType='application/vnd.google-apps.folder' and trashed=false",
    );

    if (response.files != null && response.files!.isNotEmpty) {
      _folderId = response.files!.first.id;
      return;
    }

    // Create folder if it doesn't exist
    final folder = drive.File()
      ..name = _folderName
      ..mimeType = 'application/vnd.google-apps.folder';
    
    final createdFolder = await _driveApi!.files.create(folder);
    _folderId = createdFolder.id;
  }

  /// Find a file by name in the folder
  Future<drive.File?> _findFile(String fileName) async {
    if (_driveApi == null || _folderId == null) {
      return null;
    }

    final response = await _driveApi!.files.list(
      q: "'$_folderId' in parents and name='$fileName' and trashed=false",
    );

    if (response.files != null && response.files!.isNotEmpty) {
      return response.files!.first;
    }

    return null;
  }

  /// Parse a DateTime from various formats
  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;

    if (value is int) {
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    } else if (value is String) {
      try {
        return DateTime.parse(value).toLocal();
      } catch (e) {
        final timestamp = int.tryParse(value);
        if (timestamp != null) {
          return DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true).toLocal();
        }
      }
    }
    return null;
  }
}

/// HTTP client that uses Google authentication headers
class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _client.send(request);
  }
}

