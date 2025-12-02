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

    // Debug: Print raw response
    print('ListNotes: Response status: ${response.statusCode}');
    print('ListNotes: Response body length: ${response.body.length}');
    print('ListNotes: Response body (first 500 chars): ${response.body.substring(0, response.body.length > 500 ? 500 : response.body.length)}');

    final notes = <String, Map<String, dynamic>>{};
    
    // Try to parse XML
    xml.XmlDocument document;
    try {
      document = xml.XmlDocument.parse(response.body);
    } catch (e) {
      print('ListNotes: ERROR parsing XML: $e');
      print('ListNotes: Full response body: ${response.body}');
      return {};
    }
    
    print('ListNotes: Parsed XML document successfully');
    
    // Check for different possible XML structures
    final allResponses = document.findAllElements('response');
    print('ListNotes: Found ${allResponses.length} response elements');
    
    // Get all response elements, handling namespaces
    // WebDAV PROPFIND responses have a multistatus root with response children
    List<xml.XmlElement> responseElements = [];
    
    // First, find the multistatus element (root of WebDAV response)
    xml.XmlElement? multistatusElement;
    
    // Try finding multistatus without namespace
    final multistatusCandidates = document.findAllElements('multistatus').toList();
    if (multistatusCandidates.isNotEmpty) {
      multistatusElement = multistatusCandidates.first;
    } else {
      // Try with d: prefix
      final multistatusWithPrefix = document.findAllElements('d:multistatus').toList();
      if (multistatusWithPrefix.isNotEmpty) {
        multistatusElement = multistatusWithPrefix.first;
      } else {
        // Try finding by namespace URI (common WebDAV namespaces)
        final allElements = document.findAllElements('*');
        for (final element in allElements) {
          if (element.name.local == 'multistatus') {
            multistatusElement = element;
            break;
          }
        }
      }
    }
    
    if (multistatusElement != null) {
      print('ListNotes: Found multistatus element');
      // Find all response elements within multistatus
      responseElements = multistatusElement.findAllElements('response').toList();
      if (responseElements.isEmpty) {
        // Try with d: prefix
        responseElements = multistatusElement.findAllElements('d:response').toList();
      }
      if (responseElements.isEmpty) {
        // Try finding by local name regardless of namespace
        responseElements = multistatusElement.children
            .whereType<xml.XmlElement>()
            .where((e) => e.name.local == 'response')
            .toList();
      }
    } else {
      // If no multistatus, try finding responses directly
      print('ListNotes: No multistatus found, searching for responses directly');
      responseElements = document.findAllElements('response').toList();
      if (responseElements.isEmpty) {
        responseElements = document.findAllElements('d:response').toList();
      }
      if (responseElements.isEmpty) {
        // Try finding by local name
        responseElements = document.findAllElements('*')
            .where((e) => e.name.local == 'response')
            .toList();
      }
    }
    
    print('ListNotes: Found ${responseElements.length} response elements (after namespace handling)');
    
    if (responseElements.isEmpty) {
      // Print the entire document structure for debugging
      print('ListNotes: Document root: ${document.rootElement.name.local}');
      print('ListNotes: Root namespace: ${document.rootElement.name.namespaceUri}');
      final rootChildren = document.rootElement.children.whereType<xml.XmlElement>().toList();
      print('ListNotes: Root has ${rootChildren.length} child elements');
      for (final child in rootChildren) {
        print('ListNotes:   - ${child.name.local} (namespace: ${child.name.namespaceUri})');
        final grandChildren = child.children.whereType<xml.XmlElement>().toList();
        print('ListNotes:     Has ${grandChildren.length} children');
        for (final gc in grandChildren.take(5)) {
          print('ListNotes:       - ${gc.name.local} (namespace: ${gc.name.namespaceUri})');
        }
      }
      print('ListNotes: Full XML (first 2000 chars): ${response.body.substring(0, response.body.length > 2000 ? 2000 : response.body.length)}');
    }

    for (final responseElement in responseElements) {
      // Try to find href with and without namespace
      xml.XmlElement? hrefElement = responseElement.findElements('href').firstOrNull;
      if (hrefElement == null) {
        hrefElement = responseElement.findElements('d:href', namespace: 'DAV:').firstOrNull;
      }
      final href = hrefElement?.text;
      
      if (href == null) {
        print('ListNotes: Skipping response element - no href found');
        continue;
      }
      
      print('ListNotes: Processing href: $href');
      
      if (href.endsWith('/')) {
        print('ListNotes: Skipping directory: $href');
        continue; // Skip directories
      }
      
      // Log all files found, even if they don't match our pattern
      print('ListNotes: Found file: $href');

      // Find propstat with namespace handling
      xml.XmlElement? propstat = responseElement.findElements('propstat').firstOrNull;
      if (propstat == null) {
        propstat = responseElement.findElements('d:propstat', namespace: 'DAV:').firstOrNull;
      }
      if (propstat == null) {
        print('ListNotes: Skipping $href - no propstat found');
        continue;
      }

      // Find prop with namespace handling
      xml.XmlElement? prop = propstat.findElements('prop').firstOrNull;
      if (prop == null) {
        prop = propstat.findElements('d:prop', namespace: 'DAV:').firstOrNull;
      }
      if (prop == null) {
        print('ListNotes: Skipping $href - no prop found');
        continue;
      }

      // Find getlastmodified with namespace handling
      xml.XmlElement? lastModifiedElement = prop.findElements('getlastmodified').firstOrNull;
      if (lastModifiedElement == null) {
        lastModifiedElement = prop.findElements('d:getlastmodified', namespace: 'DAV:').firstOrNull;
      }
      final getLastModified = lastModifiedElement?.text;
      
      // Find getcontentlength with namespace handling
      xml.XmlElement? contentLengthElement = prop.findElements('getcontentlength').firstOrNull;
      if (contentLengthElement == null) {
        contentLengthElement = prop.findElements('d:getcontentlength', namespace: 'DAV:').firstOrNull;
      }
      final getContentLength = contentLengthElement?.text;

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
          // If it doesn't start with the base path, log it but still process it
          // (might be in a different location or format)
          print('ListNotes: Warning - path $remotePath does not start with /feather_notes/, but processing anyway');
          // Don't skip - process it anyway in case the path format is different
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
          final localNoteData = localNotesMap[remoteNoteId]!;
          final localNote = localNoteData['note'] as Map<String, dynamic>?;
          if (localNote == null) {
            print('Sync: Warning: Local note data missing note field for ID $remoteNoteId');
            continue;
          }
          final modifiedAtValue = localNote['modified_at'];
          if (modifiedAtValue == null) {
            print('Sync: Warning: Local note $remoteNoteId missing modified_at');
            // If local note has no modified_at, download remote to update it
            try {
              final remoteData = await downloadNote(remotePath);
              if (remoteData != null) {
                onNoteUpdated(remoteNoteId, remoteData);
                downloaded++;
              }
            } catch (e) {
              print('Error downloading note $remoteNoteId: $e');
            }
            continue;
          }
          final localModified = _parseDateTime(modifiedAtValue);
          if (localModified == null) {
            print('Sync: Warning: Local note $remoteNoteId has invalid modified_at format: $modifiedAtValue');
            // If local modified_at is invalid, download remote to fix it
            try {
              final remoteData = await downloadNote(remotePath);
              if (remoteData != null) {
                onNoteUpdated(remoteNoteId, remoteData);
                downloaded++;
              }
            } catch (e) {
              print('Error downloading note $remoteNoteId: $e');
            }
            continue;
          }
          
          // Download if remote is newer than local, or if remote modified time is null
          // (null might indicate metadata parsing issue, but note exists on server)
          final shouldDownload = remoteModified == null || remoteModified.isAfter(localModified);
          
          if (shouldDownload) {
            // Remote is newer or unknown - download it
            try {
              print('Sync: Downloading note $remoteNoteId (remote: $remoteModified, local: $localModified)');
              final remoteData = await downloadNote(remotePath);
              if (remoteData != null) {
                onNoteUpdated(remoteNoteId, remoteData);
                downloaded++;
                print('Sync: Successfully downloaded and updated note $remoteNoteId');
              } else {
                print('Sync: Warning: downloadNote returned null for note $remoteNoteId');
              }
            } catch (e) {
              print('Error downloading note $remoteNoteId: $e');
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
            }
          } catch (e, stackTrace) {
            print('ERROR downloading new note $remoteNoteId: $e');
            print('Stack trace: $stackTrace');
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

