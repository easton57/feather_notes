import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'sync_provider.dart';
import 'sync_queue.dart';
import 'nextcloud_provider.dart';
import 'icloud_provider.dart';
import 'google_drive_provider.dart';

/// Manages cloud sync operations
class SyncManager {
  static final SyncManager _instance = SyncManager._internal();
  factory SyncManager() => _instance;
  SyncManager._internal();

  SyncProvider? _currentProvider;
  SyncStatus _status = SyncStatus.idle;
  String? _lastError;
  Timer? _backgroundSyncTimer;
  bool _backgroundSyncEnabled = false;
  Duration _backgroundSyncInterval = const Duration(minutes: 15);
  Set<int> _selectedNoteIds = {}; // Empty set means sync all notes
  final SyncQueue _syncQueue = SyncQueue();
  Function(List<SyncConflict>)? _onConflictsDetected;

  SyncProvider? get currentProvider => _currentProvider;
  SyncStatus get status => _status;
  String? get lastError => _lastError;
  bool get backgroundSyncEnabled => _backgroundSyncEnabled;
  Set<int> get selectedNoteIds => _selectedNoteIds;

  /// Initialize sync manager and load saved configuration
  Future<void> initialize() async {
    await _syncQueue.initialize();
    
    final prefs = await SharedPreferences.getInstance();
    final providerId = prefs.getString('sync_provider_id');
    
    if (providerId != null) {
      await _loadProvider(providerId);
      // Load and restore configuration
      await _loadProviderConfig();
    }
    
    // Load background sync settings
    _backgroundSyncEnabled = prefs.getBool('background_sync_enabled') ?? false;
    final intervalMinutes = prefs.getInt('background_sync_interval_minutes') ?? 15;
    _backgroundSyncInterval = Duration(minutes: intervalMinutes);
    
    // Load selected note IDs for selective sync
    final selectedIdsJson = prefs.getString('selected_sync_note_ids');
    if (selectedIdsJson != null) {
      final idsList = jsonDecode(selectedIdsJson) as List;
      _selectedNoteIds = idsList.map((id) => id as int).toSet();
    }
    
    // Start background sync if enabled
    if (_backgroundSyncEnabled) {
      _startBackgroundSync();
    }
    
    // Process queued operations will be handled when sync is called with callbacks
  }

  /// Set the current sync provider
  Future<void> setProvider(SyncProvider provider) async {
    _currentProvider = provider;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sync_provider_id', provider.id);
  }

  /// Configure the current provider
  Future<void> configureProvider(Map<String, dynamic> config) async {
    if (_currentProvider == null) {
      throw Exception('No sync provider set');
    }
    
    // Create a copy of config for storage (with hashed password for verification)
    final configForStorage = Map<String, dynamic>.from(config);
    
    // Hash passwords for storage (one-way hash for verification)
    // Store actual password encrypted in SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    
    if (config.containsKey('password') && config['password'] != null) {
      final password = config['password'] as String;
      configForStorage['password_hash'] = _hashPassword(password);
      configForStorage.remove('password'); // Don't store plain password in main config
      // Store encrypted password in SharedPreferences
      await prefs.setString('sync_password_encrypted', _encryptPassword(password));
    }
    if (config.containsKey('appPassword') && config['appPassword'] != null) {
      final appPassword = config['appPassword'] as String;
      configForStorage['appPassword_hash'] = _hashPassword(appPassword);
      configForStorage.remove('appPassword'); // Don't store plain app password in main config
      // Store encrypted app password in SharedPreferences
      await prefs.setString('sync_app_password_encrypted', _encryptPassword(appPassword));
    }
    
    await _currentProvider!.configure(config);
    await _saveProviderConfig(configForStorage);
  }

  /// Get available sync providers
  List<SyncProvider> getAvailableProviders() {
    return [
      NextcloudProvider(),
      ICloudProvider(),
      GoogleDriveProvider(),
    ];
  }

  /// Test connection to current provider
  Future<bool> testConnection() async {
    if (_currentProvider == null) {
      _lastError = 'No provider configured';
      return false;
    }
    try {
      final result = await _currentProvider!.testConnection();
      _lastError = null;
      return result;
    } catch (e) {
      _lastError = e.toString();
      return false;
    }
  }

  /// Set callback for conflict resolution
  void setConflictCallback(Function(List<SyncConflict>) callback) {
    _onConflictsDetected = callback;
  }

  /// Enable/disable background sync
  Future<void> setBackgroundSyncEnabled(bool enabled) async {
    _backgroundSyncEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('background_sync_enabled', enabled);
    
    if (enabled) {
      _startBackgroundSync();
    } else {
      _stopBackgroundSync();
    }
  }

  /// Set background sync interval
  Future<void> setBackgroundSyncInterval(Duration interval) async {
    _backgroundSyncInterval = interval;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('background_sync_interval_minutes', interval.inMinutes);
    
    if (_backgroundSyncEnabled) {
      _stopBackgroundSync();
      _startBackgroundSync();
    }
  }

  /// Set selected note IDs for selective sync (empty set = sync all)
  Future<void> setSelectedNoteIds(Set<int> noteIds) async {
    _selectedNoteIds = noteIds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_sync_note_ids', jsonEncode(noteIds.toList()));
  }

  /// Perform a full sync
  Future<SyncResult> sync({
    required List<Map<String, dynamic>> localNotes,
    required Function(int noteId, Map<String, dynamic> noteData) onNoteUpdated,
    required Function(Map<String, dynamic> noteData) onNoteCreated,
    bool processQueue = true,
  }) async {
    if (_currentProvider == null) {
      return SyncResult(error: 'No sync provider configured');
    }

    if (!await _currentProvider!.isConfigured()) {
      return SyncResult(error: 'Sync provider not configured');
    }

    _status = SyncStatus.syncing;
    _lastError = null;

    try {
      // Filter notes for selective sync
      List<Map<String, dynamic>> notesToSync = localNotes;
      if (_selectedNoteIds.isNotEmpty) {
        notesToSync = localNotes.where((noteData) {
          final note = noteData['note'] as Map<String, dynamic>?;
          final noteId = note?['id'] as int?;
          return noteId != null && _selectedNoteIds.contains(noteId);
        }).toList();
      }

      // Check connectivity
      bool isOnline = await _checkConnectivity();
      
      if (!isOnline) {
        // Queue operations for later
        await _queueOfflineOperations(notesToSync);
        return SyncResult(error: 'No internet connection. Operations queued.');
      }

      final result = await _currentProvider!.syncAll(
        localNotes: notesToSync,
        onNoteUpdated: onNoteUpdated,
        onNoteCreated: onNoteCreated,
      );

      // Handle conflicts
      if (result.hasConflicts && _onConflictsDetected != null) {
        _onConflictsDetected!(result.conflictList);
      }

      // Process queued operations if online
      if (processQueue && isOnline) {
        await _processSyncQueue();
      }

      if (result.hasError) {
        _status = SyncStatus.error;
        _lastError = result.error;
      } else if (result.hasConflicts) {
        _status = SyncStatus.conflict;
      } else {
        _status = SyncStatus.success;
      }

      return result;
    } catch (e) {
      _status = SyncStatus.error;
      _lastError = e.toString();
      
      // If error is due to connectivity, queue operations
      if (e.toString().contains('connection') || e.toString().contains('network')) {
        await _queueOfflineOperations(localNotes);
      }
      
      return SyncResult(error: e.toString());
    } finally {
      // Reset to idle after a delay
      Future.delayed(const Duration(seconds: 3), () {
        if (_status == SyncStatus.success) {
          _status = SyncStatus.idle;
        }
      });
    }
  }

  /// Disconnect current provider
  Future<void> disconnect() async {
    _stopBackgroundSync();
    
    if (_currentProvider != null) {
      await _currentProvider!.disconnect();
    }
    _currentProvider = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('sync_provider_id');
    await prefs.remove('sync_provider_config');
    // Remove encrypted passwords from SharedPreferences
    await prefs.remove('sync_password_encrypted');
    await prefs.remove('sync_app_password_encrypted');
    
    _status = SyncStatus.idle;
    _lastError = null;
    _selectedNoteIds.clear();
  }

  /// Load provider from saved configuration
  Future<void> _loadProvider(String providerId) async {
    final providers = getAvailableProviders();
    final provider = providers.firstWhere(
      (p) => p.id == providerId,
      orElse: () => throw Exception('Provider not found: $providerId'),
    );

    _currentProvider = provider;
  }

  /// Load provider configuration from storage
  Future<void> _loadProviderConfig() async {
    if (_currentProvider == null) return;

    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString('sync_provider_config');
    if (configJson != null) {
      try {
        final config = jsonDecode(configJson) as Map<String, dynamic>;
        // Restore configuration including passwords from secure storage
        final restoredConfig = <String, dynamic>{
          'serverUrl': config['serverUrl'],
          'username': config['username'],
        };
        
        // Restore password from encrypted SharedPreferences
        final encryptedAppPassword = prefs.getString('sync_app_password_encrypted');
        final encryptedPassword = prefs.getString('sync_password_encrypted');
        
        String? storedAppPassword;
        String? storedPassword;
        
        if (encryptedAppPassword != null) {
          storedAppPassword = _decryptPassword(encryptedAppPassword);
        }
        if (encryptedPassword != null) {
          storedPassword = _decryptPassword(encryptedPassword);
        }
        
        if (storedAppPassword != null) {
          restoredConfig['appPassword'] = storedAppPassword;
        } else if (storedPassword != null) {
          restoredConfig['password'] = storedPassword;
        }
        
        await _currentProvider!.configure(restoredConfig);
      } catch (e) {
        print('Error loading provider config: $e');
      }
    }
  }

  /// Save provider configuration
  Future<void> _saveProviderConfig(Map<String, dynamic> configForStorage) async {
    if (_currentProvider == null) return;

    final prefs = await SharedPreferences.getInstance();
    final config = await _currentProvider!.getConfiguration();
    if (config != null) {
      // Merge with stored config (which has hashed passwords)
      final configToSave = {
        ...config,
        ...configForStorage,
      };
      await prefs.setString('sync_provider_config', jsonEncode(configToSave));
    }
  }

  /// Hash a password for storage (one-way, for verification)
  String _hashPassword(String password) {
    final bytes = utf8.encode(password);
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  /// Simple encryption for passwords on Linux (base64 encoding with salt)
  /// Note: This is basic obfuscation, not true encryption. For production, use proper encryption.
  String _encryptPassword(String password) {
    // Simple base64 encoding with a salt for obfuscation
    // In production, use proper encryption like AES
    final salt = 'feather_notes_sync_salt_2024';
    final combined = '$salt$password';
    final bytes = utf8.encode(combined);
    return base64Encode(bytes);
  }

  /// Decrypt password from Linux storage
  String _decryptPassword(String encrypted) {
    try {
      final bytes = base64Decode(encrypted);
      final combined = utf8.decode(bytes);
      final salt = 'feather_notes_sync_salt_2024';
      if (combined.startsWith(salt)) {
        return combined.substring(salt.length);
      }
      return encrypted; // Fallback if format doesn't match
    } catch (e) {
      return encrypted; // Fallback on error
    }
  }

  /// Start background sync timer
  void _startBackgroundSync() {
    _stopBackgroundSync();
    _backgroundSyncTimer = Timer.periodic(_backgroundSyncInterval, (timer) async {
      // Trigger background sync if provider is configured
      if (_currentProvider != null && await _currentProvider!.isConfigured()) {
        // Note: Actual sync will be triggered by the app with proper callbacks
        // This timer just indicates when sync should happen
        // The app should call sync() periodically when background sync is enabled
      }
    });
  }
  
  /// Trigger background sync (called by app)
  Future<SyncResult?> triggerBackgroundSync({
    required List<Map<String, dynamic>> localNotes,
    required Function(int noteId, Map<String, dynamic> noteData) onNoteUpdated,
    required Function(Map<String, dynamic> noteData) onNoteCreated,
  }) async {
    if (!_backgroundSyncEnabled || _currentProvider == null) {
      return null;
    }
    
    if (!await _currentProvider!.isConfigured()) {
      return null;
    }
    
    // Only sync if status is idle (not already syncing)
    if (_status != SyncStatus.idle) {
      return null;
    }
    
    return await sync(
      localNotes: localNotes,
      onNoteUpdated: onNoteUpdated,
      onNoteCreated: onNoteCreated,
    );
  }

  /// Stop background sync timer
  void _stopBackgroundSync() {
    _backgroundSyncTimer?.cancel();
    _backgroundSyncTimer = null;
  }

  /// Check if device is online
  Future<bool> _checkConnectivity() async {
    try {
      final result = await InternetAddress.lookup('google.com');
      return result.isNotEmpty && result[0].rawAddress.isNotEmpty;
    } catch (e) {
      return false;
    }
  }

  /// Queue operations for offline execution
  Future<void> _queueOfflineOperations(List<Map<String, dynamic>> localNotes) async {
    for (final noteData in localNotes) {
      final note = noteData['note'] as Map<String, dynamic>?;
      if (note == null) continue;
      
      final noteId = note['id'] as int?;
      if (noteId == null) continue;
      
      // Check if note needs to be synced (selective sync)
      if (_selectedNoteIds.isNotEmpty && !_selectedNoteIds.contains(noteId)) {
        continue;
      }
      
      // Queue upload operation
      final operation = QueuedSyncOperation(
        id: 0, // Will be set by database
        type: SyncOperationType.upload,
        noteId: noteId,
        noteData: noteData,
        createdAt: DateTime.now(),
      );
      
      await _syncQueue.enqueue(operation);
    }
  }

  /// Process queued sync operations
  Future<void> _processSyncQueue({
    Function(int noteId, Map<String, dynamic> noteData)? onNoteUpdated,
    Function(Map<String, dynamic> noteData)? onNoteCreated,
  }) async {
    if (_currentProvider == null || !await _currentProvider!.isConfigured()) {
      return;
    }

    final operations = await _syncQueue.getAll();
    if (operations.isEmpty) return;

    final isOnline = await _checkConnectivity();
    if (!isOnline) return;

    for (final operation in operations) {
      try {
        switch (operation.type) {
          case SyncOperationType.upload:
            if (operation.noteData != null) {
              final note = operation.noteData!['note'] as Map<String, dynamic>?;
              if (note != null) {
                final title = note['title'] as String? ?? 'Untitled';
                await _currentProvider!.uploadNote(
                  noteId: operation.noteId,
                  title: title,
                  noteData: operation.noteData!,
                );
              }
            }
            break;
          case SyncOperationType.download:
            if (operation.remotePath != null) {
              final data = await _currentProvider!.downloadNote(operation.remotePath!);
              if (data != null && onNoteUpdated != null) {
                onNoteUpdated(operation.noteId, data);
              }
            }
            break;
          case SyncOperationType.delete:
            if (operation.remotePath != null) {
              await _currentProvider!.deleteNote(operation.remotePath!);
            }
            break;
        }
        
        // Remove successful operation from queue
        await _syncQueue.dequeue(operation.id);
      } catch (e) {
        // Increment retry count
        await _syncQueue.incrementRetry(operation.id);
        
        // Remove if retry count too high (e.g., > 5)
        if (operation.retryCount >= 5) {
          await _syncQueue.dequeue(operation.id);
        }
      }
    }
  }

  /// Get queued operations count
  Future<int> getQueuedOperationsCount() async {
    return await _syncQueue.getCount();
  }
}

