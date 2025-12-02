import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:path/path.dart' as path;
import 'sync_provider.dart';

/// iCloud Drive sync provider using WebDAV
/// Note: iCloud Drive WebDAV is available on macOS and iOS
class ICloudProvider implements SyncProvider {
  static const String _providerId = 'icloud';
  static const String _basePath = '/feather_notes';
  
  // iCloud Drive WebDAV base URL format
  static const String _webdavBase = 'https://p%40icloud.com@webdav.icloud.com';

  String? _appleId;
  String? _appSpecificPassword; // Required for iCloud WebDAV

  @override
  String get name => 'iCloud Drive';

  @override
  String get id => _providerId;

  @override
  Future<bool> isConfigured() async {
    return _appleId != null && 
           _appleId!.isNotEmpty && 
           _appSpecificPassword != null &&
           _appSpecificPassword!.isNotEmpty;
  }

  @override
  Future<void> configure(Map<String, dynamic> config) async {
    _appleId = config['appleId']?.toString();
    _appSpecificPassword = config['appSpecificPassword']?.toString();
  }

  @override
  Future<Map<String, dynamic>?> getConfiguration() async {
    if (!await isConfigured()) {
      return null;
    }
    return {
      'appleId': _appleId,
      'hasPassword': _appSpecificPassword != null,
    };
  }

  @override
  Future<bool> testConnection() async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    try {
      // Test connection to iCloud Drive root
      final url = Uri.parse('$_webdavBase/');
      final request = http.Request('PROPFIND', url);
      request.headers.addAll(_getAuthHeaders());
      
      final client = http.Client();
      try {
        final streamedResponse = await client.send(request);
        final response = await http.Response.fromStream(streamedResponse);
        
        if (response.statusCode == 207 || response.statusCode == 200) {
          return true;
        } else {
          throw Exception('Connection failed: ${response.statusCode} ${response.reasonPhrase}');
        }
      } finally {
        client.close();
      }
    } catch (e) {
      if (e is Exception) {
        throw e;
      }
      throw Exception('Connection error: $e');
    }
  }

  @override
  Future<String> uploadNote({
    required int noteId,
    required String title,
    required Map<String, dynamic> noteData,
  }) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    // Ensure base directory exists
    await _ensureBaseDirectory();

    final fileName = 'note_$noteId.json';
    final remotePath = '$_basePath/$fileName';
    final url = Uri.parse('$_webdavBase$remotePath');

    final request = http.Request('PUT', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode(noteData);

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return remotePath;
      } else {
        throw Exception('Upload failed: ${response.statusCode} ${response.reasonPhrase}');
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<Map<String, dynamic>?> downloadNote(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    final url = Uri.parse('$_webdavBase$remotePath');
    final request = http.Request('GET', url);
    request.headers.addAll(_getAuthHeaders());

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } else if (response.statusCode == 404) {
        return null;
      } else {
        throw Exception('Download failed: ${response.statusCode} ${response.reasonPhrase}');
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> listNotes() async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    // Ensure base directory exists
    await _ensureBaseDirectory();

    final url = Uri.parse('$_webdavBase$_basePath/');
    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Depth'] = '1';

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 207) {
        throw Exception('List failed: ${response.statusCode} ${response.reasonPhrase}');
      }

      final notes = <String, Map<String, dynamic>>{};
      final document = xml.XmlDocument.parse(response.body);
      
      for (final responseElement in document.findAllElements('response')) {
        final href = responseElement.findElements('href').firstOrNull?.text;
        if (href == null || href == '$_basePath/' || !href.endsWith('.json')) {
          continue;
        }

        // Extract remote path
        String remotePath = href;
        if (remotePath.startsWith('/')) {
          remotePath = remotePath.substring(1);
        }
        if (!remotePath.startsWith(_basePath.substring(1))) {
          continue;
        }

        // Get last modified date
        final propstat = responseElement.findElements('propstat').firstOrNull;
        final prop = propstat?.findElements('prop').firstOrNull;
        final getlastmodified = prop?.findElements('getlastmodified').firstOrNull?.text;
        
        DateTime? modified;
        if (getlastmodified != null) {
          try {
            modified = DateTime.parse(getlastmodified);
          } catch (e) {
            // Ignore parse errors
          }
        }

        notes[remotePath] = {
          'remotePath': remotePath,
          'modified_at': modified?.toIso8601String() ?? DateTime.now().toIso8601String(),
        };
      }

      return notes;
    } finally {
      client.close();
    }
  }

  @override
  Future<void> deleteNote(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    final url = Uri.parse('$_webdavBase$remotePath');
    final request = http.Request('DELETE', url);
    request.headers.addAll(_getAuthHeaders());

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200 && response.statusCode != 204 && response.statusCode != 404) {
        throw Exception('Delete failed: ${response.statusCode} ${response.reasonPhrase}');
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<DateTime?> getLastModified(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    final url = Uri.parse('$_webdavBase$remotePath');
    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Depth'] = '0';

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 207) {
        return null;
      }

      final document = xml.XmlDocument.parse(response.body);
      final responseElement = document.findAllElements('response').firstOrNull;
      final propstat = responseElement?.findElements('propstat').firstOrNull;
      final prop = propstat?.findElements('prop').firstOrNull;
      final getlastmodified = prop?.findElements('getlastmodified').firstOrNull?.text;

      if (getlastmodified != null) {
        try {
          return DateTime.parse(getlastmodified);
        } catch (e) {
          return null;
        }
      }
      return null;
    } finally {
      client.close();
    }
  }

  @override
  Future<SyncResult> syncAll({
    required List<Map<String, dynamic>> localNotes,
    required Function(int noteId, Map<String, dynamic> noteData) onNoteUpdated,
    required Function(Map<String, dynamic> noteData) onNoteCreated,
  }) async {
    if (!await isConfigured()) {
      return SyncResult(error: 'iCloud provider not configured');
    }

    try {
      // Ensure base directory exists
      await _ensureBaseDirectory();

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

      // Upload new/modified local notes
      for (final noteData in localNotes) {
        final note = noteData['note'] as Map<String, dynamic>?;
        if (note == null) continue;

        final noteId = note['id'] as int?;
        final title = note['title'] as String? ?? 'Untitled';
        if (noteId == null) continue;

        final fileName = 'note_$noteId.json';
        final remotePath = '$_basePath/$fileName';

        final remoteMetadata = remoteNotes[remotePath];
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
              final remoteData = await downloadNote(remotePath);
              if (remoteData != null) {
                onNoteUpdated(noteId, remoteData);
                downloaded++;
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
      for (final entry in remoteNotes.entries) {
        final remotePath = entry.key;
        final remoteMetadata = entry.value;

        // Extract note ID from filename
        final fileName = path.basename(remotePath);
        if (!fileName.startsWith('note_') || !fileName.endsWith('.json')) {
          continue;
        }

        final noteIdStr = fileName.substring(5, fileName.length - 5);
        final noteId = int.tryParse(noteIdStr);

        if (noteId == null || localNotesMap.containsKey(noteId)) {
          continue; // Already processed or invalid
        }

        // New remote note, download it
        final remoteData = await downloadNote(remotePath);
        if (remoteData != null) {
          onNoteCreated(remoteData);
          downloaded++;
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

  @override
  Future<String> uploadFolder({
    required int folderId,
    required String name,
    required Map<String, dynamic> folderData,
  }) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    final fileName = 'folder_$folderId.json';
    final remotePath = '$_basePath/folders/$fileName';
    final url = Uri.parse('$_webdavBase$remotePath');

    final jsonData = jsonEncode(folderData);
    final response = await http.put(
      url,
      headers: {
        ..._getAuthHeaders(),
        'Content-Type': 'application/json',
      },
      body: jsonData,
    );

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return remotePath;
    } else {
      throw Exception('Failed to upload folder: ${response.statusCode} ${response.reasonPhrase}');
    }
  }

  @override
  Future<Map<String, dynamic>?> downloadFolder(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    final url = Uri.parse('$_webdavBase$remotePath');
    final response = await http.get(
      url,
      headers: _getAuthHeaders(),
    );

    if (response.statusCode == 200) {
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        throw Exception('Failed to parse folder data: $e');
      }
    } else if (response.statusCode == 404) {
      return null;
    } else {
      throw Exception('Failed to download folder: ${response.statusCode} ${response.reasonPhrase}');
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> listFolders() async {
    // Similar to listNotes but for folders
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    final url = Uri.parse('$_webdavBase$_basePath/folders/');
    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Depth'] = '1';

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 207) {
        if (response.statusCode == 404) {
          return {};
        }
        throw Exception('Failed to list folders: ${response.statusCode} ${response.reasonPhrase}');
      }

      final folders = <String, Map<String, dynamic>>{};
      final document = xml.XmlDocument.parse(response.body);

      for (final responseElement in document.findAllElements('response')) {
        final href = responseElement.findElements('href').firstOrNull?.text;
        if (href == null || href == '$_basePath/folders/' || !href.endsWith('.json')) {
          continue;
        }

        String remotePath = href;
        if (remotePath.startsWith('/')) {
          remotePath = remotePath.substring(1);
        }
        if (!remotePath.startsWith(_basePath.substring(1) + '/folders/')) {
          continue;
        }

        final propstat = responseElement.findElements('propstat').firstOrNull;
        final prop = propstat?.findElements('prop').firstOrNull;
        final getlastmodified = prop?.findElements('getlastmodified').firstOrNull?.text;

        DateTime? modified;
        if (getlastmodified != null) {
          try {
            modified = DateTime.parse(getlastmodified);
          } catch (e) {
            // Ignore parse errors
          }
        }

        folders[remotePath] = {
          'remotePath': remotePath,
          'modified_at': modified?.toIso8601String() ?? DateTime.now().toIso8601String(),
        };
      }

      return folders;
    } finally {
      client.close();
    }
  }

  @override
  Future<void> deleteFolder(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    final url = Uri.parse('$_webdavBase$remotePath');
    final request = http.Request('DELETE', url);
    request.headers.addAll(_getAuthHeaders());

    final client = http.Client();
    try {
      final streamedResponse = await client.send(request);
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode != 200 && response.statusCode != 204 && response.statusCode != 404) {
        throw Exception('Delete failed: ${response.statusCode} ${response.reasonPhrase}');
      }
    } finally {
      client.close();
    }
  }

  @override
  Future<void> syncFolders({
    required List<Map<String, dynamic>> localFolders,
    required Function(int folderId, Map<String, dynamic> folderData) onFolderUpdated,
    required Function(Map<String, dynamic> folderData) onFolderCreated,
  }) async {
    if (!await isConfigured()) {
      throw Exception('iCloud provider not configured');
    }

    try {
      await _ensureBaseDirectory();
      final foldersUrl = Uri.parse('$_webdavBase$_basePath/folders/');
      final mkcolRequest = http.Request('MKCOL', foldersUrl);
      mkcolRequest.headers.addAll(_getAuthHeaders());
      
      final client = http.Client();
      try {
        await client.send(mkcolRequest);
      } finally {
        client.close();
      }

      final remoteFolders = await listFolders();
      final localFoldersMap = <int, Map<String, dynamic>>{};
      for (final folder in localFolders) {
        final folderId = folder['id'] as int?;
        if (folderId != null) {
          localFoldersMap[folderId] = folder;
        }
      }

      // Upload local folders
      for (final folder in localFolders) {
        final folderId = folder['id'] as int?;
        final name = folder['name'] as String?;
        if (folderId == null || name == null) continue;

        final remotePath = '$_basePath/folders/folder_$folderId.json';
        
        if (!remoteFolders.containsKey(remotePath)) {
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
      }

      // Download remote folders
      for (final entry in remoteFolders.entries) {
        final remotePath = entry.key;
        final fileName = path.basename(remotePath);
        
        final match = RegExp(r'folder_(\d+)\.json').firstMatch(fileName);
        if (match == null) continue;
        
        final remoteFolderId = int.tryParse(match.group(1)!);
        if (remoteFolderId == null) continue;

        if (!localFoldersMap.containsKey(remoteFolderId)) {
          try {
            final remoteData = await downloadFolder(remotePath);
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
    _appleId = null;
    _appSpecificPassword = null;
  }

  /// Get authentication headers for iCloud WebDAV
  Map<String, String> _getAuthHeaders() {
    if (_appleId == null || _appSpecificPassword == null) {
      throw Exception('iCloud not configured');
    }

    // iCloud WebDAV uses basic auth with Apple ID and app-specific password
    final credentials = base64Encode(utf8.encode('$_appleId:$_appSpecificPassword'));
    return {
      'Authorization': 'Basic $credentials',
    };
  }

  /// Ensure the base directory exists
  Future<void> _ensureBaseDirectory() async {
    final url = Uri.parse('$_webdavBase$_basePath/');
    
    // Try to create directory
    final mkcolRequest = http.Request('MKCOL', url);
    mkcolRequest.headers.addAll(_getAuthHeaders());

    final client = http.Client();
    try {
      final streamedResponse = await client.send(mkcolRequest);
      final response = await http.Response.fromStream(streamedResponse);
      
      // 201 = created, 405 = already exists (method not allowed)
      if (response.statusCode != 201 && response.statusCode != 405) {
        // Directory might already exist, try to verify with PROPFIND
        final propfindRequest = http.Request('PROPFIND', url);
        propfindRequest.headers.addAll(_getAuthHeaders());
        propfindRequest.headers['Depth'] = '0';
        
        final propfindResponse = await client.send(propfindRequest);
        final propfindResult = await http.Response.fromStream(propfindResponse);
        
        if (propfindResult.statusCode != 207 && propfindResult.statusCode != 200) {
          throw Exception('Failed to create/verify base directory: ${response.statusCode}');
        }
      }
    } finally {
      client.close();
    }
  }

  /// Parse a DateTime from various formats (timestamp int, ISO string, etc.)
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

