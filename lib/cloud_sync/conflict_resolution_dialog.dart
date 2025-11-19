import 'package:flutter/material.dart';
import 'sync_provider.dart';

export 'sync_provider.dart' show SyncConflictResolution;

/// Dialog for resolving sync conflicts
class ConflictResolutionDialog extends StatelessWidget {
  final SyncConflict conflict;
  final Function(SyncConflictResolution) onResolve;

  const ConflictResolutionDialog({
    super.key,
    required this.conflict,
    required this.onResolve,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Sync Conflict: ${conflict.title}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This note has been modified on both local and remote. Choose how to resolve:',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 16),
            _buildConflictInfo(context),
            const SizedBox(height: 16),
            const Text(
              'Resolution Options:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            _buildResolutionOption(
              context,
              'Use Local Version',
              'Keep your local changes and overwrite remote',
              Icons.computer,
              SyncConflictResolution.useLocal,
            ),
            const SizedBox(height: 8),
            _buildResolutionOption(
              context,
              'Use Remote Version',
              'Download remote changes and overwrite local',
              Icons.cloud,
              SyncConflictResolution.useRemote,
            ),
            const SizedBox(height: 8),
            _buildResolutionOption(
              context,
              'Keep Both',
              'Keep local version and create a copy of remote',
              Icons.copy,
              SyncConflictResolution.keepBoth,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _buildConflictInfo(BuildContext context) {
    final localDate = conflict.localModified.toString().substring(0, 19);
    final remoteDate = conflict.remoteModified.toString().substring(0, 19);
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.computer, size: 16),
                const SizedBox(width: 8),
                const Text('Local:', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(localDate, style: const TextStyle(fontSize: 12)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.cloud, size: 16),
                const SizedBox(width: 8),
                const Text('Remote:', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(remoteDate, style: const TextStyle(fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResolutionOption(
    BuildContext context,
    String title,
    String description,
    IconData icon,
    SyncConflictResolution resolution,
  ) {
    return InkWell(
      onTap: () {
        onResolve(resolution);
        Navigator.pop(context);
      },
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Icon(icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Resolution options for sync conflicts
enum SyncConflictResolution {
  useLocal,
  useRemote,
  keepBoth,
}

