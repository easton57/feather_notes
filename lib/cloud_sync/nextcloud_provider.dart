import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart' as xml;
import 'package:path/path.dart' as path;
import 'sync_provider.dart';

/// Nextcloud/WebDAV sync provider
class NextcloudProvider implements SyncProvider {
  static const String _providerId = 'nextcloud';
  static const String _basePath = '/feather_notes';

  String? _serverUrl;
  String? _username;
  String? _password;
  String? _appPassword; // App-specific password (recommended)

  @override
  String get name => 'Nextcloud';

  @override
  String get id => _providerId;

  @override
  Future<bool> isConfigured() async {
    return _serverUrl != null && 
           _serverUrl!.isNotEmpty && 
           (_username != null || _appPassword != null);
  }

  @override
  Future<void> configure(Map<String, dynamic> config) async {
    _serverUrl = config['serverUrl']?.toString();
    _username = config['username']?.toString();
    _password = config['password']?.toString();
    _appPassword = config['appPassword']?.toString();

    // Remove trailing slash from server URL
    if (_serverUrl != null && _serverUrl!.endsWith('/')) {
      _serverUrl = _serverUrl!.substring(0, _serverUrl!.length - 1);
    }
  }

  @override
  Future<Map<String, dynamic>?> getConfiguration() async {
    if (!await isConfigured()) {
      return null;
    }
    return {
      'serverUrl': _serverUrl,
      'username': _username,
      'hasPassword': _password != null || _appPassword != null,
      'useAppPassword': _appPassword != null,
    };
  }

  @override
  Future<bool> testConnection() async {
    if (!await isConfigured()) {
      throw Exception('Provider not configured');
    }

    try {
      final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username/');
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
      // Re-throw with more context
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
      throw Exception('Nextcloud provider not configured');
    }

    final fileName = 'note_$noteId.json';
    final remotePath = '$_basePath/$fileName';
    final url = Uri.parse(
      '$_serverUrl/remote.php/dav/files/$_username$remotePath',
    );

    final jsonData = jsonEncode(noteData);
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
      throw Exception('Failed to upload note: ${response.statusCode} ${response.reasonPhrase}');
    }
  }

  @override
  Future<Map<String, dynamic>?> downloadNote(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$remotePath');
    final response = await http.get(
      url,
      headers: _getAuthHeaders(),
    );

    if (response.statusCode == 200) {
      try {
        return jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        throw Exception('Failed to parse note data: $e');
      }
    } else if (response.statusCode == 404) {
      return null;
    } else {
      throw Exception('Failed to download note: ${response.statusCode} ${response.reasonPhrase}');
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> listNotes() async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$_basePath/');
    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Depth'] = '1';
    
    final client = http.Client();
    http.Response response;
    try {
      final streamedResponse = await client.send(request);
      response = await http.Response.fromStream(streamedResponse);
    } finally {
      client.close();
    }

    if (response.statusCode != 207) {
      // Directory might not exist yet, return empty map
      if (response.statusCode == 404) {
        print('ListNotes: Directory not found (404), returning empty map');
        return {};
      }
      print('ListNotes: Error ${response.statusCode}: ${response.reasonPhrase}');
      print('ListNotes: Response body: ${response.body}');
      throw Exception('Failed to list notes: ${response.statusCode} ${response.reasonPhrase}');
    }

    final notes = <String, Map<String, dynamic>>{};
    final document = xml.XmlDocument.parse(response.body);
    print('ListNotes: Parsed XML document, found ${document.findAllElements('response').length} response elements');

    for (final responseElement in document.findAllElements('response')) {
      final href = responseElement.findElements('href').firstOrNull?.text;
      if (href == null || href.endsWith('/')) continue; // Skip directories

      final propstat = responseElement.findElements('propstat').firstOrNull;
      if (propstat == null) continue;

      final prop = propstat.findElements('prop').firstOrNull;
      if (prop == null) continue;

      final getLastModified = prop.findElements('getlastmodified').firstOrNull?.text;
      final getContentLength = prop.findElements('getcontentlength').firstOrNull?.text;

      if (href.contains('note_') && href.endsWith('.json')) {
        // Extract the path - href might be full URL or just path
        String remotePath;
        if (href.startsWith('http')) {
          // Full URL, extract just the path part
          final uri = Uri.parse(href);
          remotePath = uri.path;
        } else {
          // Just a path
          remotePath = href;
        }
        
        // Remove the /remote.php/dav/files/username prefix if present
        final prefix = '/remote.php/dav/files/$_username';
        if (remotePath.startsWith(prefix)) {
          remotePath = remotePath.substring(prefix.length);
        }
        
        // Ensure path starts with /feather_notes/ for consistency
        if (!remotePath.startsWith('/feather_notes/')) {
          // If it doesn't start with the base path, skip it (might be in wrong location)
          continue;
        }
        
        notes[remotePath] = {
          'path': remotePath,
          'lastModified': getLastModified != null 
              ? DateTime.parse(getLastModified).toLocal()
              : null,
          'size': getContentLength != null ? int.tryParse(getContentLength) : null,
        };
      }
    }

    return notes;
  }

  @override
  Future<void> deleteNote(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$remotePath');
    final response = await http.delete(
      url,
      headers: _getAuthHeaders(),
    );

    if (response.statusCode != 200 && response.statusCode != 204 && response.statusCode != 404) {
      throw Exception('Failed to delete note: ${response.statusCode} ${response.reasonPhrase}');
    }
  }

  @override
  Future<DateTime?> getLastModified(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$remotePath');
    final request = http.Request('PROPFIND', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Depth'] = '0';
    
    final client = http.Client();
    http.Response response;
    try {
      final streamedResponse = await client.send(request);
      response = await http.Response.fromStream(streamedResponse);
    } finally {
      client.close();
    }

    if (response.statusCode != 207) {
      return null;
    }

    final document = xml.XmlDocument.parse(response.body);
    final propstat = document.findAllElements('propstat').firstOrNull;
    if (propstat == null) return null;

    final prop = propstat.findElements('prop').firstOrNull;
    if (prop == null) return null;

    final getLastModified = prop.findElements('getlastmodified').firstOrNull?.text;
    if (getLastModified == null) return null;

    try {
      return DateTime.parse(getLastModified).toLocal();
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
    if (!await isConfigured()) {
      return SyncResult(error: 'Nextcloud provider not configured');
    }

    try {
      // Ensure base directory exists
      await _ensureDirectoryExists();

      // List remote notes
      final remoteNotes = await listNotes();
      print('Sync: Found ${remoteNotes.length} remote notes');
      print('Sync: Remote note paths: ${remoteNotes.keys.toList()}');
      final conflicts = <SyncConflict>[];
      int uploaded = 0;
      int downloaded = 0;

      // Create a map of local notes by ID
      // Note: localNotes structure is { 'note': {...}, 'canvas': {...} }
      final localNotesMap = <int, Map<String, dynamic>>{};
      for (final noteData in localNotes) {
        // Extract note info from the exported structure
        final note = noteData['note'] as Map<String, dynamic>?;
        if (note == null) {
          print('Sync: Warning: Note data missing note field, skipping: $noteData');
          continue;
        }
        
        final noteIdValue = note['id'];
        if (noteIdValue == null) {
          print('Sync: Warning: Note missing id field, skipping: $note');
          continue;
        }
        final noteId = noteIdValue is int ? noteIdValue : int.tryParse(noteIdValue.toString());
        if (noteId == null) {
          print('Sync: Warning: Note id is not a valid int, skipping: $note');
          continue;
        }
        localNotesMap[noteId] = noteData; // Store full noteData, not just note
      }

      // Upload local notes that are new or modified
      for (final localNoteData in localNotes) {
        // Extract note info from the exported structure
        final note = localNoteData['note'] as Map<String, dynamic>?;
        if (note == null) {
          print('Sync: Warning: Local note data missing note field, skipping');
          continue;
        }
        
        final noteIdValue = note['id'];
        if (noteIdValue == null) {
          print('Sync: Warning: Local note missing id field, skipping');
          continue;
        }
        final noteId = noteIdValue is int ? noteIdValue : int.tryParse(noteIdValue.toString());
        if (noteId == null) {
          print('Sync: Warning: Local note id is not a valid int, skipping');
          continue;
        }
        
        final titleValue = note['title'];
        if (titleValue == null) {
          print('Sync: Warning: Note $noteId missing title, skipping');
          continue;
        }
        final title = titleValue.toString();
        
        final modifiedAtValue = note['modified_at'];
        if (modifiedAtValue == null) {
          print('Sync: Warning: Note $noteId missing modified_at, skipping');
          continue;
        }
        // Handle both timestamp (int) and ISO string formats
        final localModified = _parseDateTime(modifiedAtValue);
        if (localModified == null) {
          print('Sync: Warning: Note $noteId has invalid modified_at format: $modifiedAtValue');
          continue;
        }
        final remotePath = '$_basePath/note_$noteId.json';

        if (remoteNotes.containsKey(remotePath)) {
          final remoteModified = remoteNotes[remotePath]!['lastModified'] as DateTime?;
          if (remoteModified != null && remoteModified.isAfter(localModified)) {
            // Remote is newer, check for conflict
            final remoteData = await downloadNote(remotePath);
            if (remoteData != null) {
              conflicts.add(SyncConflict(
                noteId: noteId,
                title: title,
                localData: localNoteData, // Use full noteData structure
                remoteData: remoteData,
                localModified: localModified,
                remoteModified: remoteModified,
              ));
            }
            continue;
          }
        }

        // Upload local note
        try {
          await uploadNote(
            noteId: noteId,
            title: title,
            noteData: localNoteData, // Upload the full noteData structure
          );
          uploaded++;
        } catch (e) {
          // Log error but continue
          print('Error uploading note $noteId: $e');
        }
      }

      // Download remote notes that are new or modified
      for (final entry in remoteNotes.entries) {
        final remotePath = entry.key;
        final remoteMetadata = entry.value;
        final fileName = path.basename(remotePath);
        
        // Extract note ID from filename (note_123.json)
        final match = RegExp(r'note_(\d+)\.json').firstMatch(fileName);
        if (match == null) continue;
        
        final remoteNoteId = int.tryParse(match.group(1)!);
        if (remoteNoteId == null) continue;

        final remoteModified = remoteMetadata['lastModified'] as DateTime?;
        if (remoteModified == null) continue;

        if (localNotesMap.containsKey(remoteNoteId)) {
          final localNoteData = localNotesMap[remoteNoteId]!;
          final localNote = localNoteData['note'] as Map<String, dynamic>?;
          if (localNote == null) {
            print('Sync: Warning: Local note data missing note field for ID $remoteNoteId');
            continue;
          }
          final modifiedAtValue = localNote['modified_at'];
          if (modifiedAtValue == null) {
            print('Sync: Warning: Local note $remoteNoteId missing modified_at');
            continue;
          }
          final localModified = _parseDateTime(modifiedAtValue);
          if (localModified == null) {
            print('Sync: Warning: Local note $remoteNoteId has invalid modified_at format: $modifiedAtValue');
            continue;
          }
          
          if (remoteModified.isAfter(localModified)) {
            // Remote is newer, download it
            try {
              final remoteData = await downloadNote(remotePath);
              if (remoteData != null) {
                onNoteUpdated(remoteNoteId, remoteData);
                downloaded++;
              }
            } catch (e) {
              print('Error downloading note $remoteNoteId: $e');
            }
          }
        } else {
          // New remote note, download it
          print('Sync: Found new remote note $remoteNoteId at path $remotePath');
          try {
            final remoteData = await downloadNote(remotePath);
            if (remoteData != null) {
              print('Sync: Successfully downloaded note $remoteNoteId, calling onNoteCreated');
              onNoteCreated(remoteData);
              downloaded++;
            } else {
              print('Sync: Warning: downloadNote returned null for $remotePath');
            }
          } catch (e) {
            print('Error downloading new note $remoteNoteId: $e');
          }
        }
      }

      return SyncResult(
        uploaded: uploaded,
        downloaded: downloaded,
        conflicts: conflicts.length,
        conflictList: conflicts,
      );
    } catch (e) {
      return SyncResult(error: e.toString());
    }
  }

  @override
  Future<void> disconnect() async {
    _serverUrl = null;
    _username = null;
    _password = null;
    _appPassword = null;
  }

  /// Parse a DateTime from various formats (timestamp int, ISO string, etc.)
  DateTime? _parseDateTime(dynamic value) {
    if (value == null) return null;
    
    if (value is int) {
      // Timestamp in milliseconds
      return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true).toLocal();
    } else if (value is String) {
      // Try parsing as ISO string first
      try {
        return DateTime.parse(value).toLocal();
      } catch (e) {
        // Try parsing as timestamp string
        final timestamp = int.tryParse(value);
        if (timestamp != null) {
          return DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true).toLocal();
        }
      }
    }
    return null;
  }

  /// Get authentication headers for HTTP requests
  Map<String, String> _getAuthHeaders() {
    // For app passwords, use username:appPassword format
    // For regular passwords, use username:password format
    final credentials = _appPassword != null 
        ? '$_username:$_appPassword' 
        : '$_username:$_password';
    final bytes = utf8.encode(credentials);
    final base64Str = base64Encode(bytes);
    return {
      'Authorization': 'Basic $base64Str',
    };
  }

  /// Ensure the base directory exists on the server
  Future<void> _ensureDirectoryExists() async {
    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$_basePath/');
    
    // Try to create directory (MKCOL)
    final request = http.Request('MKCOL', url);
    request.headers.addAll(_getAuthHeaders());
    
    final client = http.Client();
    http.Response response;
    try {
      final streamedResponse = await client.send(request);
      response = await http.Response.fromStream(streamedResponse);
    } finally {
      client.close();
    }

    // 201 = created, 405 = already exists, both are fine
    if (response.statusCode != 201 && response.statusCode != 405) {
      // If it's not a "method not allowed" error, it might be a real error
      // But we'll continue anyway as the directory might exist
    }
  }
}

