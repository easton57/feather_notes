import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_manager.dart';
import 'sync_provider.dart';
import '../database_helper.dart';

/// Sync Settings Page - Quick access to sync features without password entry
class SyncSettingsPage extends StatefulWidget {
  final SyncManager syncManager;
  final VoidCallback onSyncRequested;

  const SyncSettingsPage({
    super.key,
    required this.syncManager,
    required this.onSyncRequested,
  });

  @override
  State<SyncSettingsPage> createState() => _SyncSettingsPageState();
}

class _SyncSettingsPageState extends State<SyncSettingsPage> {
  Duration _currentSyncInterval = const Duration(minutes: 15);
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSyncInterval();
  }

  Future<void> _loadSyncInterval() async {
    final prefs = await SharedPreferences.getInstance();
    final minutes = prefs.getInt('background_sync_interval_minutes') ?? 15;
    setState(() {
      _currentSyncInterval = Duration(minutes: minutes);
      _isLoading = false;
    });
  }

  String _formatDuration(Duration duration) {
    if (duration.inMinutes < 60) {
      return 'Every ${duration.inMinutes} minutes';
    } else if (duration.inHours == 1) {
      return 'Every hour';
    } else {
      return 'Every ${duration.inHours} hours';
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.syncManager.currentProvider;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync Settings'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16.0),
              children: [
                // Current provider info
                if (provider != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.cloud, size: 24),
                              const SizedBox(width: 8),
                              Text(
                                provider.name,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Status: ${_getStatusText()}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                
                // Manual sync button
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.sync),
                        title: const Text('Manual Sync'),
                        subtitle: const Text('Sync your notes now'),
                        trailing: IconButton(
                          icon: const Icon(Icons.play_arrow),
                          onPressed: () {
                            Navigator.pop(context);
                            // Call the sync callback after navigation completes
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              widget.onSyncRequested();
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Background sync settings
                Card(
                  child: Column(
                    children: [
                      CheckboxListTile(
                        title: const Text('Background Sync'),
                        subtitle: const Text('Automatically sync in the background'),
                        value: widget.syncManager.backgroundSyncEnabled,
                        onChanged: (value) async {
                          await widget.syncManager.setBackgroundSyncEnabled(value ?? false);
                          setState(() {});
                        },
                      ),
                      if (widget.syncManager.backgroundSyncEnabled) ...[
                        const Divider(height: 1),
                        ListTile(
                          title: const Text('Sync Frequency'),
                          subtitle: Text(_formatDuration(_currentSyncInterval)),
                          trailing: DropdownButton<Duration>(
                            value: _currentSyncInterval,
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
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('Sync frequency set to ${_formatDuration(value)}'),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                
                // Selective sync
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.filter_list),
                    title: const Text('Selective Sync'),
                    subtitle: Text(
                      widget.syncManager.selectedNoteIds.isEmpty
                          ? 'All notes will be synced'
                          : '${widget.syncManager.selectedNoteIds.length} note(s) selected',
                    ),
                    trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                    onTap: () => _showSelectiveSyncDialog(context),
                  ),
                ),
                const SizedBox(height: 16),
                
                // Queued operations
                FutureBuilder<int>(
                  future: widget.syncManager.getQueuedOperationsCount(),
                  builder: (context, snapshot) {
                    final count = snapshot.data ?? 0;
                    if (count > 0) {
                      return Card(
                        color: Colors.orange.shade50,
                        child: ListTile(
                          leading: const Icon(Icons.queue, color: Colors.orange),
                          title: const Text('Queued Operations'),
                          subtitle: Text('$count operation(s) waiting for connection'),
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
              ],
            ),
    );
  }

  String _getStatusText() {
    switch (widget.syncManager.status) {
      case SyncStatus.idle:
        return 'Ready';
      case SyncStatus.syncing:
        return 'Syncing...';
      case SyncStatus.success:
        return 'Last sync successful';
      case SyncStatus.error:
        return 'Error: ${widget.syncManager.lastError ?? "Unknown"}';
      case SyncStatus.conflict:
        return 'Conflicts detected';
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

