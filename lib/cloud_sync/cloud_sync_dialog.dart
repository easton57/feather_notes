import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_manager.dart';
import 'sync_provider.dart';
import 'nextcloud_provider.dart';
import 'icloud_provider.dart';
import 'google_drive_provider.dart';
import '../database_helper.dart';

/// Cloud Sync Configuration Dialog
class CloudSyncDialog extends StatefulWidget {
  final SyncManager syncManager;
  final VoidCallback onSyncRequested;

  const CloudSyncDialog({
    super.key,
    required this.syncManager,
    required this.onSyncRequested,
  });

  @override
  State<CloudSyncDialog> createState() => _CloudSyncDialogState();
}

class _CloudSyncDialogState extends State<CloudSyncDialog> {
  String? _selectedProviderId;
  SyncProvider? _selectedProvider;
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _appPasswordController = TextEditingController();
  final _appleIdController = TextEditingController();
  final _appSpecificPasswordController = TextEditingController();
  bool _useAppPassword = false;
  bool _isTesting = false;
  bool _isConfigured = false;
  Duration _currentSyncInterval = const Duration(minutes: 15);
  
  @override
  void initState() {
    super.initState();
    _loadConfiguration();
    _loadSyncInterval();
  }
  
  Future<void> _loadSyncInterval() async {
    final prefs = await SharedPreferences.getInstance();
    final minutes = prefs.getInt('background_sync_interval_minutes') ?? 15;
    setState(() {
      _currentSyncInterval = Duration(minutes: minutes);
    });
  }
  
  Duration _getCurrentSyncInterval() {
    return _currentSyncInterval;
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _appPasswordController.dispose();
    _appleIdController.dispose();
    _appSpecificPasswordController.dispose();
    super.dispose();
  }

  Future<void> _loadConfiguration() async {
    final provider = widget.syncManager.currentProvider;
    if (provider != null) {
      _selectedProviderId = provider.id;
      final availableProviders = widget.syncManager.getAvailableProviders();
      _selectedProvider = availableProviders.firstWhere(
        (p) => p.id == provider.id,
        orElse: () => availableProviders.first,
      );
      final config = await provider.getConfiguration();
      if (config != null) {
        if (provider.id == 'nextcloud') {
          _serverUrlController.text = config['serverUrl']?.toString() ?? '';
          _usernameController.text = config['username']?.toString() ?? '';
          _isConfigured = config['hasPassword'] == true || config['hasAppPassword'] == true;
          _useAppPassword = config['hasAppPassword'] == true;
          
          // Pre-fill password from stored configuration (decrypted)
          await _loadStoredPassword();
        } else if (provider.id == 'icloud') {
          _appleIdController.text = config['appleId']?.toString() ?? '';
          _isConfigured = config['hasAppSpecificPassword'] == true;
          
          // Pre-fill app-specific password from stored configuration
          await _loadStoredPassword();
        } else if (provider.id == 'google_drive') {
          _isConfigured = config['isAuthenticated'] == true;
        }
      }
    }
    setState(() {});
  }
  
  Future<void> _loadStoredPassword() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Try to load encrypted password from storage
    final encryptedAppPassword = prefs.getString('sync_app_password_encrypted');
    final encryptedPassword = prefs.getString('sync_password_encrypted');
    
    if (encryptedAppPassword != null) {
      // Decrypt and fill app password
      final decrypted = _decryptPassword(encryptedAppPassword);
      _appPasswordController.text = decrypted;
      _useAppPassword = true;
    } else if (encryptedPassword != null) {
      // Decrypt and fill regular password
      final decrypted = _decryptPassword(encryptedPassword);
      _passwordController.text = decrypted;
      _useAppPassword = false;
    }
  }
  
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

  SyncProvider? get computedSelectedProvider {
    if (_selectedProviderId == null) return null;
    final providers = widget.syncManager.getAvailableProviders();
    return providers.firstWhere(
      (p) => p.id == _selectedProviderId,
      orElse: () => providers.first,
    );
  }

  @override
  Widget build(BuildContext context) {
    final computedSelectedProvider = this.computedSelectedProvider;
    
    return AlertDialog(
      title: const Text('Cloud Sync Configuration'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select Sync Provider:'),
            const SizedBox(height: 8),
            DropdownButton<String>(
              value: _selectedProviderId,
              isExpanded: true,
              hint: const Text('Select a provider'),
              items: widget.syncManager.getAvailableProviders().map((provider) {
                return DropdownMenuItem<String>(
                  value: provider.id,
                  child: Text(provider.name),
                );
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _selectedProviderId = value;
                  _selectedProvider = computedSelectedProvider;
                  _isConfigured = false;
                });
              },
            ),
            if (computedSelectedProvider != null) ...[
              const SizedBox(height: 16),
              // Nextcloud configuration
              if (computedSelectedProvider.id == 'nextcloud') ...[
                TextField(
                  controller: _serverUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'https://nextcloud.example.com',
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  title: const Text('Use App Password'),
                  subtitle: const Text('Recommended for better security'),
                  value: _useAppPassword,
                  onChanged: (value) {
                    setState(() {
                      _useAppPassword = value ?? false;
                    });
                  },
                ),
                TextField(
                  controller: _useAppPassword ? _appPasswordController : _passwordController,
                  decoration: InputDecoration(
                    labelText: _useAppPassword ? 'App Password' : 'Password',
                    hintText: _useAppPassword
                        ? 'Generate in Nextcloud Settings > Security'
                        : 'Your Nextcloud password',
                  ),
                  obscureText: true,
                ),
              ],
              // iCloud configuration
              if (computedSelectedProvider.id == 'icloud') ...[
                TextField(
                  controller: _appleIdController,
                  decoration: const InputDecoration(
                    labelText: 'Apple ID',
                    hintText: 'your.email@example.com',
                  ),
                  keyboardType: TextInputType.emailAddress,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _appSpecificPasswordController,
                  decoration: const InputDecoration(
                    labelText: 'App-Specific Password',
                    hintText: 'xxxx-xxxx-xxxx-xxxx',
                    helperText: 'Generate at appleid.apple.com',
                  ),
                  obscureText: true,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Note: iCloud Drive WebDAV requires an app-specific password. Generate one at appleid.apple.com',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
              // Google Drive configuration
              if (computedSelectedProvider.id == 'google_drive') ...[
                const Text(
                  'Google Drive uses OAuth2 authentication. Click "Test Connection" to sign in with your Google account.',
                  style: TextStyle(fontSize: 14),
                ),
                const SizedBox(height: 8),
                if (_isConfigured) ...[
                  const Text(
                    '✓ Signed in to Google Drive',
                    style: TextStyle(color: Colors.green),
                  ),
                ],
              ],
            ],
            if (_isConfigured) ...[
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Sync Settings',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 8),
              // Background sync toggle
              CheckboxListTile(
                title: const Text('Background Sync'),
                subtitle: const Text('Automatically sync in the background'),
                value: widget.syncManager.backgroundSyncEnabled,
                onChanged: (value) async {
                  await widget.syncManager.setBackgroundSyncEnabled(value ?? false);
                  setState(() {});
                },
              ),
              // Background sync frequency selector
              if (widget.syncManager.backgroundSyncEnabled) ...[
                const SizedBox(height: 8),
                ListTile(
                  title: const Text('Sync Frequency'),
                  subtitle: const Text('How often to sync automatically'),
                  trailing: DropdownButton<Duration>(
                    value: _getCurrentSyncInterval(),
                    items: const [
                      DropdownMenuItem(
                        value: Duration(minutes: 5),
                        child: Text('Every 5 minutes'),
                      ),
                      DropdownMenuItem(
                        value: Duration(minutes: 15),
                        child: Text('Every 15 minutes'),
                      ),
                      DropdownMenuItem(
                        value: Duration(minutes: 30),
                        child: Text('Every 30 minutes'),
                      ),
                      DropdownMenuItem(
                        value: Duration(hours: 1),
                        child: Text('Every hour'),
                      ),
                      DropdownMenuItem(
                        value: Duration(hours: 2),
                        child: Text('Every 2 hours'),
                      ),
                      DropdownMenuItem(
                        value: Duration(hours: 6),
                        child: Text('Every 6 hours'),
                      ),
                      DropdownMenuItem(
                        value: Duration(hours: 12),
                        child: Text('Every 12 hours'),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value != null) {
                        await widget.syncManager.setBackgroundSyncInterval(value);
                        setState(() {
                          _currentSyncInterval = value;
                        });
                      }
                    },
                  ),
                ),
              ],
              // Manual sync button
              const SizedBox(height: 8),
              ElevatedButton.icon(
                onPressed: widget.onSyncRequested,
                icon: const Icon(Icons.sync),
                label: const Text('Sync Now'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
              // Selective sync button
              ListTile(
                title: const Text('Selective Sync'),
                subtitle: Text(
                  widget.syncManager.selectedNoteIds.isEmpty
                      ? 'All notes will be synced'
                      : '${widget.syncManager.selectedNoteIds.length} note(s) selected',
                ),
                trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                onTap: () => _showSelectiveSyncDialog(context),
              ),
              // Queued operations indicator
              FutureBuilder<int>(
                future: widget.syncManager.getQueuedOperationsCount(),
                builder: (context, snapshot) {
                  final count = snapshot.data ?? 0;
                  if (count > 0) {
                    return ListTile(
                      leading: const Icon(Icons.queue, color: Colors.orange),
                      title: const Text('Queued Operations'),
                      subtitle: Text('$count operation(s) waiting for connection'),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              const SizedBox(height: 8),
              const Text(
                '✓ Configured',
                style: TextStyle(color: Colors.green),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (_isConfigured)
          TextButton(
            onPressed: _disconnect,
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Disconnect'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _isTesting ? null : _testConnection,
          child: _isTesting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Test Connection'),
        ),
        if (computedSelectedProvider != null)
          TextButton(
            onPressed: _saveConfiguration,
            child: const Text('Save'),
          ),
      ],
    );
  }

  Future<void> _testConnection() async {
    if (_selectedProviderId == null) {
      _showError('Please select a sync provider');
      return;
    }

    final providers = widget.syncManager.getAvailableProviders();
    final provider = providers.firstWhere(
      (p) => p.id == _selectedProviderId,
      orElse: () => throw Exception('Provider not found'),
    );

    setState(() {
      _isTesting = true;
    });

    try {
      await widget.syncManager.setProvider(provider);
      
      Map<String, dynamic> config = {};
      if (provider.id == 'nextcloud') {
        config = {
          'serverUrl': _serverUrlController.text.trim(),
          'username': _usernameController.text.trim(),
          if (_useAppPassword)
            'appPassword': _appPasswordController.text.trim()
          else
            'password': _passwordController.text.trim(),
        };
      } else if (provider.id == 'icloud') {
        config = {
          'appleId': _appleIdController.text.trim(),
          'appSpecificPassword': _appSpecificPasswordController.text.trim(),
        };
      } else if (provider.id == 'google_drive') {
        // Google Drive uses OAuth, config is handled in configure()
        config = {};
      }
      
      await widget.syncManager.configureProvider(config);

      final success = await widget.syncManager.testConnection();
      if (mounted) {
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Connection successful!'),
              backgroundColor: Colors.green,
            ),
          );
          setState(() {
            _isConfigured = true;
          });
        } else {
          _showError('Connection failed: ${widget.syncManager.lastError ?? "Unknown error"}');
        }
      }
    } catch (e) {
      if (mounted) {
        _showError('Error: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTesting = false;
        });
      }
    }
  }

  Future<void> _saveConfiguration() async {
    if (_selectedProviderId == null) {
      _showError('Please select a sync provider');
      return;
    }

    final providers = widget.syncManager.getAvailableProviders();
    final provider = providers.firstWhere(
      (p) => p.id == _selectedProviderId,
      orElse: () => throw Exception('Provider not found'),
    );

    try {
      await widget.syncManager.setProvider(provider);
      
      Map<String, dynamic> config = {};
      if (provider.id == 'nextcloud') {
        config = {
          'serverUrl': _serverUrlController.text.trim(),
          'username': _usernameController.text.trim(),
          if (_useAppPassword)
            'appPassword': _appPasswordController.text.trim()
          else
            'password': _passwordController.text.trim(),
        };
      } else if (provider.id == 'icloud') {
        config = {
          'appleId': _appleIdController.text.trim(),
          'appSpecificPassword': _appSpecificPasswordController.text.trim(),
        };
      } else if (provider.id == 'google_drive') {
        // Google Drive uses OAuth, config is handled in configure()
        config = {};
      }
      
      await widget.syncManager.configureProvider(config);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sync configuration saved'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        _showError('Error saving configuration: $e');
      }
    }
  }

  Future<void> _disconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect Sync'),
        content: const Text('Are you sure you want to disconnect? This will clear all sync configuration.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await widget.syncManager.disconnect();
      if (mounted) {
        setState(() {
          _isConfigured = false;
          _selectedProviderId = null;
          _selectedProvider = null;
        });
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sync disconnected'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  Future<void> _showSelectiveSyncDialog(BuildContext context) async {
    final allNotes = await DatabaseHelper.instance.getAllNotes(
      searchQuery: null,
      sortBy: 'id',
      filterTags: null,
    );
    
    final selectedIds = Set<int>.from(widget.syncManager.selectedNoteIds);
    
    await showDialog(
      context: context,
      builder: (context) => _SelectiveSyncDialog(
        notes: allNotes,
        selectedIds: selectedIds,
        onSelectionChanged: (newSelection) async {
          await widget.syncManager.setSelectedNoteIds(newSelection);
          setState(() {});
        },
      ),
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }
}

/// Selective Sync Dialog
class _SelectiveSyncDialog extends StatefulWidget {
  final List<Map<String, dynamic>> notes;
  final Set<int> selectedIds;
  final Function(Set<int>) onSelectionChanged;

  const _SelectiveSyncDialog({
    required this.notes,
    required this.selectedIds,
    required this.onSelectionChanged,
  });

  @override
  State<_SelectiveSyncDialog> createState() => _SelectiveSyncDialogState();
}

class _SelectiveSyncDialogState extends State<_SelectiveSyncDialog> {
  late Set<int> _selectedIds;

  @override
  void initState() {
    super.initState();
    _selectedIds = Set<int>.from(widget.selectedIds);
  }

  @override
  Widget build(BuildContext context) {
    final allSelected = _selectedIds.isEmpty;
    
    return AlertDialog(
      title: const Text('Selective Sync'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Select notes to sync:'),
                TextButton(
                  onPressed: () {
                    setState(() {
                      if (allSelected) {
                        _selectedIds = {};
                      } else {
                        _selectedIds = widget.notes.map((n) => n['id'] as int).toSet();
                      }
                    });
                  },
                  child: Text(allSelected ? 'Deselect All' : 'Select All'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Divider(),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.notes.length,
                itemBuilder: (context, index) {
                  final note = widget.notes[index];
                  final noteId = note['id'] as int;
                  final title = note['title'] as String;
                  final isSelected = allSelected || _selectedIds.contains(noteId);
                  
                  return CheckboxListTile(
                    title: Text(title),
                    value: isSelected,
                    onChanged: (value) {
                      setState(() {
                        if (allSelected) {
                          _selectedIds = widget.notes.map((n) => n['id'] as int).toSet();
                          _selectedIds.remove(noteId);
                        } else {
                          if (value == true) {
                            _selectedIds.add(noteId);
                          } else {
                            _selectedIds.remove(noteId);
                          }
                        }
                      });
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _selectedIds.isEmpty
                  ? 'All notes will be synced'
                  : '${_selectedIds.length} of ${widget.notes.length} notes selected',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            widget.onSelectionChanged(_selectedIds);
            Navigator.pop(context);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

