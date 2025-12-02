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

    // Ensure remotePath starts with /
    final normalizedPath = remotePath.startsWith('/') ? remotePath : '/$remotePath';
    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$normalizedPath');
    
    print('DownloadNote: Downloading from URL: $url');
    print('DownloadNote: Remote path: $normalizedPath');
    
    final response = await http.get(
      url,
      headers: _getAuthHeaders(),
    );

    print('DownloadNote: Response status: ${response.statusCode}');
    print('DownloadNote: Response body length: ${response.body.length}');

    if (response.statusCode == 200) {
      if (response.body.isEmpty) {
        print('DownloadNote: WARNING - Response body is empty');
        return null;
      }
      try {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        print('DownloadNote: Successfully parsed JSON. Keys: ${decoded.keys.toList()}');
        return decoded;
      } catch (e, stackTrace) {
        print('DownloadNote: ERROR parsing JSON: $e');
        print('DownloadNote: Response body (first 500 chars): ${response.body.length > 500 ? response.body.substring(0, 500) : response.body}');
        print('DownloadNote: Stack trace: $stackTrace');
        throw Exception('Failed to parse note data: $e');
      }
    } else if (response.statusCode == 404) {
      print('DownloadNote: File not found (404) at path: $normalizedPath');
      return null;
    } else {
      print('DownloadNote: Error ${response.statusCode}: ${response.reasonPhrase}');
      print('DownloadNote: Response body: ${response.body}');
      throw Exception('Failed to download note: ${response.statusCode} ${response.reasonPhrase}');
    }
  }

  @override
  Future<Map<String, Map<String, dynamic>>> listNotes() async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$_basePath/');
    
    // Try PROPFIND with explicit properties first
    http.Request request = http.Request('PROPFIND', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Depth'] = '1';
    
    // Add request body for PROPFIND
    request.body = '''<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getlastmodified/>
    <d:getcontentlength/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>''';
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    
    final client = http.Client();
    http.Response response;
    try {
      final streamedResponse = await client.send(request);
      response = await http.Response.fromStream(streamedResponse);
    } finally {
      client.close();
    }

    // If the first attempt fails, try without request body (some servers prefer this)
    if (response.statusCode != 207 && response.statusCode != 200) {
      print('ListNotes: First attempt failed with ${response.statusCode}, trying without request body...');
      final fallbackRequest = http.Request('PROPFIND', url);
      fallbackRequest.headers.addAll(_getAuthHeaders());
      fallbackRequest.headers['Depth'] = '1';
      
      final fallbackClient = http.Client();
      try {
        final fallbackStreamedResponse = await fallbackClient.send(fallbackRequest);
        response = await http.Response.fromStream(fallbackStreamedResponse);
        print('ListNotes: Fallback attempt returned ${response.statusCode}');
      } finally {
        fallbackClient.close();
      }
    }

    if (response.statusCode != 207 && response.statusCode != 200) {
      // Directory might not exist yet, return empty map
      if (response.statusCode == 404) {
        print('ListNotes: Directory not found (404), returning empty map');
        return {};
      }
      print('ListNotes: Error ${response.statusCode}: ${response.reasonPhrase}');
      print('ListNotes: Response body: ${response.body}');
      throw Exception('Failed to list notes: ${response.statusCode} ${response.reasonPhrase}');
    }

    print('ListNotes: Response status: ${response.statusCode}');
    print('ListNotes: Response body length: ${response.body.length}');

    final notes = <String, Map<String, dynamic>>{};
    
    // Parse XML with proper namespace handling
    xml.XmlDocument document;
    try {
      document = xml.XmlDocument.parse(response.body);
    } catch (e) {
      print('ListNotes: ERROR parsing XML: $e');
      print('ListNotes: Full response body: ${response.body}');
      return {};
    }
    
    // Find all response elements using namespace-aware search
    final davNamespace = 'DAV:';
    final allResponses = document.findAllElements('response', namespace: davNamespace).toList();
    
    // If no namespace matches, try without namespace
    final responseElements = allResponses.isNotEmpty 
        ? allResponses 
        : document.findAllElements('response').toList();
    
    print('ListNotes: Found ${responseElements.length} response elements');

    // Expected base path pattern
    final expectedBasePath = '/remote.php/dav/files/$_username$_basePath/';
    
    for (final responseElement in responseElements) {
      // Find href - try with namespace first, then without
      String? href;
      final hrefElements = responseElement.findAllElements('href', namespace: davNamespace);
      if (hrefElements.isNotEmpty) {
        href = hrefElements.first.text;
      } else {
        final hrefNoNs = responseElement.findAllElements('href');
        if (hrefNoNs.isNotEmpty) {
          href = hrefNoNs.first.text;
        }
      }
      
      if (href == null || href.isEmpty) {
        continue;
      }
      
      // Decode URL-encoded href
      href = Uri.decodeComponent(href);
      
      // Skip directories (end with /)
      if (href.endsWith('/')) {
        continue;
      }
      
      // Extract path from href
      String filePath = href;
      if (href.startsWith('http://') || href.startsWith('https://')) {
        final uri = Uri.parse(href);
        filePath = uri.path;
      }
      
      print('ListNotes: Processing href: $href -> filePath: $filePath');
      
      // Check if this is a note file
      if (!filePath.contains('note_') || !filePath.endsWith('.json')) {
        continue;
      }
      
      // Extract the remote path - we need to preserve the /feather_notes/ prefix
      // The href might be in formats like:
      // - /remote.php/dav/files/username/feather_notes/note_123.json
      // - https://server/remote.php/dav/files/username/feather_notes/note_123.json
      
      String remotePath;
      
      // Find the position of the base path in the file path
      final basePathPattern = '$_basePath/';
      final basePathIndex = filePath.indexOf(basePathPattern);
      
      if (basePathIndex != -1) {
        // Extract everything from the base path onwards
        remotePath = filePath.substring(basePathIndex);
        // Ensure it starts with /
        if (!remotePath.startsWith('/')) {
          remotePath = '/$remotePath';
        }
        print('ListNotes: Extracted remotePath from basePath: $remotePath');
      } else {
        // Fallback: try to find just the filename and construct the full path
        final fileName = filePath.split('/').last;
        if (fileName.startsWith('note_') && fileName.endsWith('.json')) {
          remotePath = '$_basePath/$fileName';
          if (!remotePath.startsWith('/')) {
            remotePath = '/$remotePath';
          }
          print('ListNotes: Constructed remotePath from filename: $remotePath');
        } else {
          print('ListNotes: Could not parse path from href: $href (filePath: $filePath)');
          continue;
        }
      }
      
      // Final validation: ensure the path includes the base path
      if (!remotePath.contains('$_basePath/')) {
        print('ListNotes: WARNING - remotePath does not contain base path: $remotePath');
        // Try to fix it
        final fileName = remotePath.split('/').last;
        if (fileName.startsWith('note_') && fileName.endsWith('.json')) {
          remotePath = '$_basePath/$fileName';
          if (!remotePath.startsWith('/')) {
            remotePath = '/$remotePath';
          }
          print('ListNotes: Fixed remotePath to: $remotePath');
        }
      }
      
      // Extract metadata
      DateTime? lastModified;
      int? size;
      
      // Find propstat
      final propstatElements = responseElement.findAllElements('propstat', namespace: davNamespace);
      if (propstatElements.isEmpty) {
        final propstatNoNs = responseElement.findAllElements('propstat');
        if (propstatNoNs.isNotEmpty) {
          final propstat = propstatNoNs.first;
          final prop = propstat.findAllElements('prop').firstOrNull;
          if (prop != null) {
            final lastMod = prop.findAllElements('getlastmodified').firstOrNull;
            if (lastMod != null) {
              try {
                lastModified = DateTime.parse(lastMod.text).toLocal();
              } catch (e) {
                print('ListNotes: Error parsing lastModified: $e');
              }
            }
            final contentLength = prop.findAllElements('getcontentlength').firstOrNull;
            if (contentLength != null && contentLength.text.isNotEmpty) {
              size = int.tryParse(contentLength.text);
            }
          }
        }
      } else {
        for (final propstat in propstatElements) {
          // Check status - we want 200 OK
          final status = propstat.findAllElements('status', namespace: davNamespace).firstOrNull;
          if (status != null && !status.text.contains('200')) {
            continue; // Skip non-200 status
          }
          
          final prop = propstat.findAllElements('prop', namespace: davNamespace).firstOrNull;
          if (prop != null) {
            final lastMod = prop.findAllElements('getlastmodified', namespace: davNamespace).firstOrNull;
            if (lastMod != null) {
              try {
                lastModified = DateTime.parse(lastMod.text).toLocal();
              } catch (e) {
                print('ListNotes: Error parsing lastModified: $e');
              }
            }
            final contentLength = prop.findAllElements('getcontentlength', namespace: davNamespace).firstOrNull;
            if (contentLength != null && contentLength.text.isNotEmpty) {
              size = int.tryParse(contentLength.text);
            }
            break; // Found valid propstat, break
          }
        }
      }
      
      print('ListNotes: Found note file: $remotePath (lastModified: $lastModified, size: $size)');
      
      // Final validation: ensure path includes base directory
      if (!remotePath.contains('$_basePath/')) {
        print('ListNotes: ERROR - Path does not include base path! Fixing: $remotePath');
        final fileName = remotePath.split('/').last;
        remotePath = '$_basePath/$fileName';
        if (!remotePath.startsWith('/')) {
          remotePath = '/$remotePath';
        }
        print('ListNotes: Fixed path to: $remotePath');
      }
      
      notes[remotePath] = {
        'path': remotePath,
        'lastModified': lastModified,
        'size': size,
      };
    }

    print('ListNotes: Returning ${notes.length} notes with paths: ${notes.keys.toList()}');
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
      print('Sync: Starting to list remote notes...');
      final remoteNotes = await listNotes();
      print('Sync: Found ${remoteNotes.length} remote notes');
      print('Sync: Remote note paths: ${remoteNotes.keys.toList()}');
      if (remoteNotes.isEmpty) {
        print('Sync: WARNING - No remote notes found! This might indicate:');
        print('Sync:   1. Directory does not exist on Nextcloud');
        print('Sync:   2. No notes have been uploaded yet');
        print('Sync:   3. Authentication or connection issue');
      }
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
      print('Sync: Starting download phase, processing ${remoteNotes.length} remote notes...');
      if (remoteNotes.isEmpty) {
        print('Sync: WARNING - No remote notes found. This could mean:');
        print('Sync:   1. Directory is empty on server');
        print('Sync:   2. listNotes() failed to parse files correctly');
        print('Sync:   3. Files exist but are not being detected');
      }
      
      for (final entry in remoteNotes.entries) {
        final remotePath = entry.key;
        final remoteMetadata = entry.value;
        final fileName = path.basename(remotePath);
        
        print('Sync: Processing remote note: path=$remotePath, fileName=$fileName');
        
        // Extract note ID from filename (note_123.json)
        final match = RegExp(r'note_(\d+)\.json').firstMatch(fileName);
        if (match == null) {
          print('Sync: Skipping $fileName - filename does not match note_XXX.json pattern');
          continue;
        }
        
        final remoteNoteId = int.tryParse(match.group(1)!);
        if (remoteNoteId == null) {
          print('Sync: Skipping $fileName - could not parse note ID from ${match.group(1)}');
          continue;
        }
        
        print('Sync: Extracted note ID $remoteNoteId from $fileName');

        final remoteModified = remoteMetadata['lastModified'] as DateTime?;
        
        if (localNotesMap.containsKey(remoteNoteId)) {
          // Note exists locally - check if we need to update it
          final localNoteData = localNotesMap[remoteNoteId]!;
          final localNote = localNoteData['note'] as Map<String, dynamic>?;
          if (localNote == null) {
            print('Sync: Warning: Local note data missing note field for ID $remoteNoteId - will download to fix');
            try {
              final remoteData = await downloadNote(remotePath);
              if (remoteData != null) {
                await onNoteUpdated(remoteNoteId, remoteData);
                downloaded++;
                print('Sync: Successfully downloaded and updated note $remoteNoteId (missing note field)');
              }
            } catch (e) {
              print('Sync: Error downloading note $remoteNoteId: $e');
            }
            continue;
          }
          
          final modifiedAtValue = localNote['modified_at'];
          DateTime? localModified;
          
          if (modifiedAtValue != null) {
            localModified = _parseDateTime(modifiedAtValue);
          }
          
          // Determine if we should download:
          // 1. If local modified_at is missing or invalid, download
          // 2. If remote is newer, download
          // 3. If remote modified time is unknown (null), still download to be safe
          final shouldDownload = localModified == null || 
                                 remoteModified == null || 
                                 remoteModified.isAfter(localModified);
          
          if (shouldDownload) {
            try {
              print('Sync: Downloading note $remoteNoteId (remote: $remoteModified, local: $localModified)');
              final remoteData = await downloadNote(remotePath);
              if (remoteData != null) {
                await onNoteUpdated(remoteNoteId, remoteData);
                downloaded++;
                print('Sync: Successfully downloaded and updated note $remoteNoteId');
              } else {
                print('Sync: Warning: downloadNote returned null for note $remoteNoteId');
              }
            } catch (e, stackTrace) {
              print('Sync: Error downloading note $remoteNoteId: $e');
              print('Sync: Stack trace: $stackTrace');
            }
          } else {
            print('Sync: Skipping note $remoteNoteId (local is newer or same: local=$localModified, remote=$remoteModified)');
          }
        } else {
          // New remote note (doesn't exist locally), download it
          print('Sync: Found new remote note $remoteNoteId at path $remotePath (lastModified: $remoteModified)');
          print('Sync: Note $remoteNoteId does not exist locally, will download and create');
          try {
            final remoteData = await downloadNote(remotePath);
            if (remoteData != null) {
              print('Sync: Successfully downloaded new note $remoteNoteId');
              print('Sync: Remote data structure: note=${remoteData.containsKey('note')}, canvas=${remoteData.containsKey('canvas')}');
              print('Sync: Calling onNoteCreated for note $remoteNoteId...');
              await onNoteCreated(remoteData);
              downloaded++;
              print('Sync: Successfully created note $remoteNoteId locally');
            } else {
              print('Sync: ERROR - downloadNote returned null for new note at $remotePath');
              print('Sync: This might indicate the file exists but cannot be downloaded');
            }
          } catch (e, stackTrace) {
            print('Sync: ERROR downloading new note $remoteNoteId: $e');
            print('Sync: Stack trace: $stackTrace');
          }
        }
      }
      
      print('Sync: Download phase complete. Downloaded $downloaded notes.');

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

  // Folder sync methods
  @override
  Future<String> uploadFolder({
    required int folderId,
    required String name,
    required Map<String, dynamic> folderData,
  }) async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final fileName = 'folder_$folderId.json';
    final remotePath = '$_basePath/folders/$fileName';
    final url = Uri.parse(
      '$_serverUrl/remote.php/dav/files/$_username$remotePath',
    );

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
      throw Exception('Nextcloud provider not configured');
    }

    final normalizedPath = remotePath.startsWith('/') ? remotePath : '/$remotePath';
    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$normalizedPath');
    
    final response = await http.get(
      url,
      headers: _getAuthHeaders(),
    );

    if (response.statusCode == 200) {
      if (response.body.isEmpty) {
        return null;
      }
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
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$_basePath/folders/');
    
    // Try PROPFIND with explicit properties first
    http.Request request = http.Request('PROPFIND', url);
    request.headers.addAll(_getAuthHeaders());
    request.headers['Depth'] = '1';
    
    request.body = '''<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getlastmodified/>
    <d:getcontentlength/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>''';
    request.headers['Content-Type'] = 'application/xml; charset=utf-8';
    
    final client = http.Client();
    http.Response response;
    try {
      final streamedResponse = await client.send(request);
      response = await http.Response.fromStream(streamedResponse);
    } finally {
      client.close();
    }

    // If the first attempt fails, try without request body
    if (response.statusCode != 207 && response.statusCode != 200) {
      final fallbackRequest = http.Request('PROPFIND', url);
      fallbackRequest.headers.addAll(_getAuthHeaders());
      fallbackRequest.headers['Depth'] = '1';
      
      final fallbackClient = http.Client();
      try {
        final fallbackStreamedResponse = await fallbackClient.send(fallbackRequest);
        response = await http.Response.fromStream(fallbackStreamedResponse);
      } finally {
        fallbackClient.close();
      }
    }

    if (response.statusCode != 207 && response.statusCode != 200) {
      if (response.statusCode == 404) {
        return {};
      }
      throw Exception('Failed to list folders: ${response.statusCode} ${response.reasonPhrase}');
    }

    final folders = <String, Map<String, dynamic>>{};
    
    try {
      final document = xml.XmlDocument.parse(response.body);
      final davNamespace = 'DAV:';
      final allResponses = document.findAllElements('response', namespace: davNamespace).toList();
      final responseElements = allResponses.isNotEmpty 
          ? allResponses 
          : document.findAllElements('response').toList();
      
      for (final responseElement in responseElements) {
        String? href;
        final hrefElements = responseElement.findAllElements('href', namespace: davNamespace);
        if (hrefElements.isNotEmpty) {
          href = hrefElements.first.text;
        } else {
          final hrefNoNs = responseElement.findAllElements('href');
          if (hrefNoNs.isNotEmpty) {
            href = hrefNoNs.first.text;
          }
        }
        
        if (href == null || href.isEmpty || href.endsWith('/')) {
          continue;
        }
        
        href = Uri.decodeComponent(href);
        
        String filePath = href;
        if (href.startsWith('http://') || href.startsWith('https://')) {
          final uri = Uri.parse(href);
          filePath = uri.path;
        }
        
        if (!filePath.contains('folder_') || !filePath.endsWith('.json')) {
          continue;
        }
        
        String remotePath;
        final basePathPattern = '$_basePath/folders/';
        final basePathIndex = filePath.indexOf(basePathPattern);
        
        if (basePathIndex != -1) {
          remotePath = filePath.substring(basePathIndex);
          if (!remotePath.startsWith('/')) {
            remotePath = '/$remotePath';
          }
        } else {
          final fileName = filePath.split('/').last;
          if (fileName.startsWith('folder_') && fileName.endsWith('.json')) {
            remotePath = '$_basePath/folders/$fileName';
            if (!remotePath.startsWith('/')) {
              remotePath = '/$remotePath';
            }
          } else {
            continue;
          }
        }
        
        DateTime? lastModified;
        final propstatElements = responseElement.findAllElements('propstat', namespace: davNamespace);
        if (propstatElements.isEmpty) {
          final propstatNoNs = responseElement.findAllElements('propstat');
          if (propstatNoNs.isNotEmpty) {
            final propstat = propstatNoNs.first;
            final prop = propstat.findAllElements('prop').firstOrNull;
            if (prop != null) {
              final lastMod = prop.findAllElements('getlastmodified').firstOrNull;
              if (lastMod != null) {
                try {
                  lastModified = DateTime.parse(lastMod.text).toLocal();
                } catch (e) {
                  // Ignore
                }
              }
            }
          }
        } else {
          for (final propstat in propstatElements) {
            final status = propstat.findAllElements('status', namespace: davNamespace).firstOrNull;
            if (status != null && !status.text.contains('200')) {
              continue;
            }
            
            final prop = propstat.findAllElements('prop', namespace: davNamespace).firstOrNull;
            if (prop != null) {
              final lastMod = prop.findAllElements('getlastmodified', namespace: davNamespace).firstOrNull;
              if (lastMod != null) {
                try {
                  lastModified = DateTime.parse(lastMod.text).toLocal();
                } catch (e) {
                  // Ignore
                }
              }
              break;
            }
          }
        }
        
        folders[remotePath] = {
          'path': remotePath,
          'lastModified': lastModified,
        };
      }
    } catch (e) {
      print('Error parsing folders XML: $e');
      return {};
    }

    return folders;
  }

  @override
  Future<void> deleteFolder(String remotePath) async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    final normalizedPath = remotePath.startsWith('/') ? remotePath : '/$remotePath';
    final url = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$normalizedPath');
    final response = await http.delete(
      url,
      headers: _getAuthHeaders(),
    );

    if (response.statusCode != 200 && response.statusCode != 204 && response.statusCode != 404) {
      throw Exception('Failed to delete folder: ${response.statusCode} ${response.reasonPhrase}');
    }
  }

  @override
  Future<void> syncFolders({
    required List<Map<String, dynamic>> localFolders,
    required Function(int folderId, Map<String, dynamic> folderData) onFolderUpdated,
    required Function(Map<String, dynamic> folderData) onFolderCreated,
  }) async {
    if (!await isConfigured()) {
      throw Exception('Nextcloud provider not configured');
    }

    try {
      // Ensure folders directory exists
      final foldersUrl = Uri.parse('$_serverUrl/remote.php/dav/files/$_username$_basePath/folders/');
      final mkcolRequest = http.Request('MKCOL', foldersUrl);
      mkcolRequest.headers.addAll(_getAuthHeaders());
      
      final client = http.Client();
      try {
        final streamedResponse = await client.send(mkcolRequest);
        final response = await http.Response.fromStream(streamedResponse);
        // 201 = created, 405 = already exists, both are fine
      } finally {
        client.close();
      }

      // List remote folders
      final remoteFolders = await listFolders();
      
      // Create a map of local folders by ID
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
        
        if (remoteFolders.containsKey(remotePath)) {
          final remoteModified = remoteFolders[remotePath]!['lastModified'] as DateTime?;
          final localModified = folder['created_at'] as int?;
          if (localModified != null && remoteModified != null) {
            final localModifiedDate = DateTime.fromMillisecondsSinceEpoch(localModified, isUtc: true).toLocal();
            if (remoteModified.isAfter(localModifiedDate)) {
              // Remote is newer, skip upload
              continue;
            }
          }
        }

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
      for (final entry in remoteFolders.entries) {
        final remotePath = entry.key;
        final fileName = path.basename(remotePath);
        
        final match = RegExp(r'folder_(\d+)\.json').firstMatch(fileName);
        if (match == null) continue;
        
        final remoteFolderId = int.tryParse(match.group(1)!);
        if (remoteFolderId == null) continue;

        if (localFoldersMap.containsKey(remoteFolderId)) {
          // Folder exists locally, check if we need to update
          final localFolder = localFoldersMap[remoteFolderId]!;
          final remoteModified = entry.value['lastModified'] as DateTime?;
          final localModified = localFolder['created_at'] as int?;
          
          if (localModified != null && remoteModified != null) {
            final localModifiedDate = DateTime.fromMillisecondsSinceEpoch(localModified, isUtc: true).toLocal();
            if (remoteModified.isAfter(localModifiedDate)) {
              // Remote is newer, download it
              try {
                final remoteData = await downloadFolder(remotePath);
                if (remoteData != null) {
                  await onFolderUpdated(remoteFolderId, remoteData);
                }
              } catch (e) {
                print('Error downloading folder $remoteFolderId: $e');
              }
            }
          }
        } else {
          // New remote folder, download it
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

