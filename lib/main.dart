import 'dart:async';
import 'dart:ui' as ui;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'database_helper.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'cloud_sync/sync_manager.dart';
import 'cloud_sync/sync_provider.dart';
import 'cloud_sync/nextcloud_provider.dart';
import 'cloud_sync/conflict_resolution_dialog.dart';
import 'cloud_sync/cloud_sync_dialog.dart';
import 'cloud_sync/sync_settings_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize SQLite for desktop platforms
  // Note: This will show a warning about changing the default factory,
  // which is expected and necessary for desktop platforms
  if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  
  runApp(const NotesApp());
}

class NotesApp extends StatefulWidget {
  const NotesApp({super.key});

  @override
  State<NotesApp> createState() => _NotesAppState();
}

class _NotesAppState extends State<NotesApp> {
  ThemeMode _themeMode = ThemeMode.system;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeString = prefs.getString('theme_mode') ?? 'system';
    setState(() {
      _themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.toString() == 'ThemeMode.$themeModeString',
        orElse: () => ThemeMode.system,
      );
      _isLoading = false;
    });
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.toString().split('.').last);
    setState(() {
      _themeMode = mode;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      title: 'Infinite Notes',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        canvasColor: Colors.white,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        canvasColor: const Color(0xFF121212),
      ),
      themeMode: _themeMode,
      home: NotesHomePage(
        onThemeModeChanged: _setThemeMode,
      ),
    );
  }
}

class NotesHomePage extends StatefulWidget {
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  
  const NotesHomePage({super.key, required this.onThemeModeChanged});

  @override
  State<NotesHomePage> createState() => _NotesHomePageState();
}

class _NotesHomePageState extends State<NotesHomePage> {
  final List<Map<String, dynamic>> notes = []; // {id, title, tags, folder_id}
  final List<Map<String, dynamic>> folders = []; // {id, name, created_at, sort_order}
  int selectedIndex = 0;
  int? _editingIndex;
  int? _editingFolderIndex;
  final Map<int, TextEditingController> _noteControllers = {};
  final Map<int, TextEditingController> _folderControllers = {};
  final Map<int, NoteCanvasData> _noteCanvasData = {};
  bool _isLoading = true;
  bool _isCreatingDefaultNote = false; // Flag to prevent recursion
  
  // GlobalKey to preserve InfiniteCanvas state across rebuilds
  final Map<int, GlobalKey> _canvasKeys = {};
  
  // Search and filter state
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'id'; // 'id', 'title', 'date_created', 'date_modified'
  List<String> _selectedTags = [];
  List<String> _availableTags = [];
  
  // Folder expansion state
  final Set<int> _expandedFolders = {};
  
  // Scaffold key for drawer control
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    try {
      // Load available tags
      final tags = await DatabaseHelper.instance.getAllTags();
      
      // Load folders
      final foldersList = await DatabaseHelper.instance.getAllFolders();
      
      // Load notes with search, sort, and filter
      final notesList = await DatabaseHelper.instance.getAllNotes(
        searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
        sortBy: _sortBy,
        filterTags: _selectedTags.isEmpty ? null : _selectedTags,
      );
      final List<Map<String, dynamic>> loadedNotes = [];
      final Map<int, NoteCanvasData> loadedCanvasData = {};
      
      // Load all notes and their canvas data before setting state
      for (final n in notesList) {
        final noteId = n['id'] as int;
        final noteTags = n['tags'] as List<String>? ?? [];
        final folderId = n['folder_id'] as int?;
        loadedNotes.add({
          'id': noteId,
          'title': n['title'] as String,
          'tags': noteTags,
          'folder_id': folderId,
        });
        
        // Load canvas data for each note to ensure correct alignment
        try {
          final data = await DatabaseHelper.instance.loadCanvasData(noteId);
          
          // Validate and fix matrix if corrupted
          Matrix4 matrix = Matrix4.copy(data.matrix);
          final determinant = matrix.determinant();
          if (!determinant.isFinite || determinant == 0 || determinant.isNaN) {
            // Matrix is corrupted, reset to identity
            matrix = Matrix4.identity();
          }
          
          // Validate scale
          double scale = data.scale;
          if (!scale.isFinite || scale <= 0 || scale.isNaN) {
            scale = 1.0;
          }
          
          // Create a deep copy to avoid reference sharing
          loadedCanvasData[noteId] = NoteCanvasData(
            strokes: data.strokes.map((s) => Stroke(List.from(s.points), color: s.color, penSize: s.penSize)).toList(),
            textElements: data.textElements.map((te) => TextElement(te.position, te.text)).toList(),
            matrix: matrix,
            scale: scale,
          );
        } catch (e) {
          // If loading fails, use empty canvas data
          loadedCanvasData[noteId] = NoteCanvasData();
        }
      }
      
      // If no notes exist, create a default one before setting state
      // Use flag to prevent recursion
      if (loadedNotes.isEmpty && !_isCreatingDefaultNote) {
        _isCreatingDefaultNote = true;
        await _createDefaultNote();
        _isCreatingDefaultNote = false;
        // _createDefaultNote will set _isLoading = false
        return;
      }
      
      setState(() {
        notes.clear();
        notes.addAll(loadedNotes);
        folders.clear();
        folders.addAll(foldersList);
        _noteCanvasData.clear();
        _noteCanvasData.addAll(loadedCanvasData);
        _availableTags = tags;
        // Only reset selectedIndex if current selection is invalid
        if (selectedIndex >= notes.length || selectedIndex < 0) {
          selectedIndex = notes.isNotEmpty ? 0 : -1;
        }
        _isLoading = false;
      });
    } catch (e) {
      // If database doesn't exist yet, create default note
      // Use flag to prevent recursion
      if (notes.isEmpty && !_isCreatingDefaultNote) {
        _isCreatingDefaultNote = true;
        await _createDefaultNote();
        _isCreatingDefaultNote = false;
        // _createDefaultNote will handle setting _isLoading = false
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }
  
  void _applyFilters() {
    setState(() {
      _isLoading = true;
    });
    _loadNotes();
  }

  Widget _buildNotesList() {
    // Group notes by folder
    final Map<int?, List<Map<String, dynamic>>> notesByFolder = {};
    final List<int> noteIndices = [];
    
    for (int i = 0; i < notes.length; i++) {
      final folderId = notes[i]['folder_id'] as int?;
      if (!notesByFolder.containsKey(folderId)) {
        notesByFolder[folderId] = [];
      }
      notesByFolder[folderId]!.add(notes[i]);
      noteIndices.add(i);
    }
    
    return ListView(
      children: [
        // Notes without folders first
        if (notesByFolder.containsKey(null) && notesByFolder[null]!.isNotEmpty)
          ...notesByFolder[null]!.asMap().entries.map((entry) {
            final note = entry.value;
            final i = notes.indexWhere((n) => n['id'] == note['id']);
            return _buildNoteTile(i, note);
          }),
        
        // Folders with their notes
        ...folders.map((folder) {
          final folderId = folder['id'] as int;
          final folderNotes = notesByFolder[folderId] ?? [];
          final isExpanded = _expandedFolders.contains(folderId);
          
          return ExpansionTile(
            title: Row(
              children: [
                const Icon(Icons.folder, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(folder['name'] as String),
                ),
              ],
            ),
            initiallyExpanded: isExpanded,
            onExpansionChanged: (expanded) {
              // Prevent drawer from closing when expanding/collapsing folders
              setState(() {
                if (expanded) {
                  _expandedFolders.add(folderId);
                } else {
                  _expandedFolders.remove(folderId);
                }
              });
            },
            // Prevent the tile from closing the drawer
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: 'Edit Folder Name',
                  onPressed: () {
                    _showEditFolderDialog(context, folderId, folder['name'] as String);
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.delete, size: 18),
                  color: Colors.red,
                  onPressed: () => _deleteFolder(context, folderId),
                ),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: 'Add Note to Folder',
                  onPressed: () => _showCreateNoteDialog(context, folderId),
                ),
              ],
            ),
            children: folderNotes.isEmpty
                ? [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Text(
                        'No notes in this folder',
                        style: TextStyle(
                          color: Colors.grey[600],
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ]
                : folderNotes.map((note) {
                    final i = notes.indexWhere((n) => n['id'] == note['id']);
                    return Padding(
                      padding: const EdgeInsets.only(left: 16.0),
                      child: _buildNoteTile(i, note),
                    );
                  }).toList(),
          );
        }),
        
        // Add folder button - use InkWell to prevent drawer from closing
        InkWell(
          onTap: () {
            // Don't close drawer - show dialog instead
            _showCreateFolderDialog(context);
          },
          child: const ListTile(
            leading: Icon(Icons.create_new_folder),
            title: Text('New Folder'),
          ),
        ),
      ],
    );
  }

  Widget _buildNoteTile(int i, Map<String, dynamic> note) {
    final noteId = note['id'] as int;
    final noteTags = note['tags'] as List<String>? ?? [];
    
    return ListTile(
      title: Text(note['title'] as String),
      subtitle: noteTags.isNotEmpty
          ? Wrap(
              spacing: 4,
              runSpacing: 4,
              children: noteTags.map((tag) => Chip(
                label: Text(tag, style: const TextStyle(fontSize: 10)),
                padding: EdgeInsets.zero,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              )).toList(),
            )
          : null,
      selected: i == selectedIndex,
      onTap: () async {
        setState(() {
          selectedIndex = i;
        });
        // Ensure we load the correct note data before switching
        await _loadNoteData(noteId);
        if (context.mounted) {
          Navigator.pop(context);
        }
      },
      onLongPress: () {
        // Show edit dialog on long press
        _showEditNoteDialog(context, noteId, note['title'] as String);
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.label_outline, size: 20),
            tooltip: 'Edit Tags',
            onPressed: () => _showTagEditor(context, noteId, noteTags),
          ),
          IconButton(
            icon: const Icon(Icons.folder_outlined, size: 20),
            tooltip: 'Move to Folder',
            onPressed: () => _showMoveToFolderDialog(context, noteId, note['folder_id'] as int?),
          ),
          IconButton(
            icon: const Icon(Icons.edit, size: 20),
            tooltip: 'Edit Name',
            onPressed: () {
              _showEditNoteDialog(context, noteId, note['title'] as String);
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete, size: 20),
            color: Colors.red,
            onPressed: () => _deleteNote(context, i, noteId),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditNoteDialog(BuildContext context, int noteId, String currentTitle) async {
    final controller = TextEditingController(text: currentTitle);
    // Get scaffold to keep drawer open
    final scaffoldState = _scaffoldKey.currentState;
    final wasDrawerOpen = scaffoldState?.isDrawerOpen ?? false;
    
    // Use rootNavigator: false to prevent drawer from closing
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: const Text('Edit Note Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Note title',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(context, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty && result != currentTitle) {
      await DatabaseHelper.instance.updateNoteTitle(noteId, result);
      await _loadNotes();
      
      // Reopen drawer if it was open before
      if (wasDrawerOpen && scaffoldState != null) {
        scaffoldState.openDrawer();
      }
    } else if (wasDrawerOpen && scaffoldState != null) {
      // Reopen drawer if dialog was cancelled
      scaffoldState.openDrawer();
    }
  }

  Future<void> _showEditFolderDialog(BuildContext context, int folderId, String currentName) async {
    final controller = TextEditingController(text: currentName);
    // Get scaffold to keep drawer open
    final scaffoldState = _scaffoldKey.currentState;
    final wasDrawerOpen = scaffoldState?.isDrawerOpen ?? false;
    
    // Use rootNavigator: false to prevent drawer from closing
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: const Text('Edit Folder Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(context, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty && result != currentName) {
      await DatabaseHelper.instance.updateFolderName(folderId, result);
      await _loadNotes();
      
      // Reopen drawer if it was open before
      if (wasDrawerOpen && scaffoldState != null) {
        scaffoldState.openDrawer();
      }
    } else if (wasDrawerOpen && scaffoldState != null) {
      // Reopen drawer if dialog was cancelled
      scaffoldState.openDrawer();
    }
  }

  Future<void> _showCreateFolderDialog(BuildContext context) async {
    final controller = TextEditingController();
    // Get scaffold to keep drawer open
    final scaffoldState = _scaffoldKey.currentState;
    final wasDrawerOpen = scaffoldState?.isDrawerOpen ?? false;
    
    // Use rootNavigator: false to prevent drawer from closing
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: const Text('New Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Folder name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(context, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      final newFolderId = await DatabaseHelper.instance.createFolder(result);
      await _loadNotes();
      
      // Expand the newly created folder
      setState(() {
        _expandedFolders.add(newFolderId);
      });
      
      // Reopen drawer if it was open before
      if (wasDrawerOpen && scaffoldState != null) {
        scaffoldState.openDrawer();
      }
    } else if (wasDrawerOpen && scaffoldState != null) {
      // Reopen drawer if dialog was cancelled
      scaffoldState.openDrawer();
    }
  }

  Future<void> _deleteFolder(BuildContext context, int folderId) async {
    // Get scaffold to keep drawer open
    final scaffoldState = _scaffoldKey.currentState;
    final wasDrawerOpen = scaffoldState?.isDrawerOpen ?? false;
    
    // Use rootNavigator: false to prevent drawer from closing
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: const Text('Delete Folder'),
        content: const Text('Are you sure you want to delete this folder? Notes in this folder will be moved to the root.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await DatabaseHelper.instance.deleteFolder(folderId);
      _loadNotes();
      
      // Reopen drawer if it was open before
      if (wasDrawerOpen && scaffoldState != null) {
        scaffoldState.openDrawer();
      }
    } else if (wasDrawerOpen && scaffoldState != null) {
      // Reopen drawer if dialog was cancelled
      scaffoldState.openDrawer();
    }
  }

  Future<void> _showCreateNoteDialog(BuildContext context, int? folderId) async {
    final controller = TextEditingController();
    // Get scaffold to keep drawer open
    final scaffoldState = _scaffoldKey.currentState;
    final wasDrawerOpen = scaffoldState?.isDrawerOpen ?? false;
    
    // Use rootNavigator: false to prevent drawer from closing
    final result = await showDialog<String>(
      context: context,
      useRootNavigator: false,
      barrierDismissible: true,
      builder: (context) => AlertDialog(
        title: const Text('New Note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Note title',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              Navigator.pop(context, value.trim());
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    
    if (result != null && result.isNotEmpty) {
      final newNoteId = await DatabaseHelper.instance.createNote(result, folderId: folderId);
      
      // If note was created in a folder, expand that folder
      if (folderId != null) {
        setState(() {
          _expandedFolders.add(folderId);
        });
      }
      
      // Reload notes to get the new note in the list
      await _loadNotes();
      
      // Find and select the newly created note after reload
      setState(() {
        final index = notes.indexWhere((n) => n['id'] == newNoteId);
        if (index >= 0) {
          selectedIndex = index;
        }
      });
      
      // Load the note data if we found it
      if (selectedIndex >= 0 && selectedIndex < notes.length) {
        final noteId = notes[selectedIndex]['id'] as int;
        await _loadNoteData(noteId);
      }
      
      // Reopen drawer if it was open before
      if (wasDrawerOpen && scaffoldState != null) {
        scaffoldState.openDrawer();
      }
    } else if (wasDrawerOpen && scaffoldState != null) {
      // Reopen drawer if dialog was cancelled
      scaffoldState.openDrawer();
    }
  }

  Future<void> _showMoveToFolderDialog(BuildContext context, int noteId, int? currentFolderId) async {
    // Use a sentinel value to distinguish between cancel and "No Folder" selection
    // -1 = cancelled, -2 = "No Folder" (null), positive = folderId
    const int cancelSentinel = -1;
    const int noFolderSentinel = -2;
    
    // Use rootNavigator: false to prevent drawer from closing
    final result = await showDialog<int>(
      context: context,
      useRootNavigator: false,
      builder: (context) => AlertDialog(
        title: const Text('Move to Folder'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const Icon(Icons.folder_off),
                title: const Text('No Folder'),
                selected: currentFolderId == null,
                onTap: () => Navigator.pop(context, noFolderSentinel),
              ),
              const Divider(),
              if (folders.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text(
                    'No folders available. Create a folder first.',
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                )
              else
                ...folders.map((folder) {
                  final folderId = folder['id'] as int;
                  return ListTile(
                    leading: const Icon(Icons.folder),
                    title: Text(folder['name'] as String),
                    selected: currentFolderId == folderId,
                    onTap: () => Navigator.pop(context, folderId),
                  );
                }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, cancelSentinel),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    
    // Only move if user selected a different folder (not cancelled)
    if (result == null || result == cancelSentinel) {
      return; // User cancelled or dialog was dismissed
    }
    
    final targetFolderId = result == noFolderSentinel ? null : result;
    if (targetFolderId != currentFolderId) {
      try {
        // Move the note in the database
        final rowsAffected = await DatabaseHelper.instance.moveNoteToFolder(noteId, targetFolderId);
        
        if (rowsAffected > 0) {
          // If moving to a folder, expand that folder
          if (targetFolderId != null) {
            setState(() {
              _expandedFolders.add(targetFolderId);
            });
          }
          
          // Reload notes to reflect the change
          await _loadNotes();
          
          // Find and maintain selection of the moved note
          setState(() {
            final index = notes.indexWhere((n) => n['id'] == noteId);
            if (index >= 0) {
              selectedIndex = index;
            }
          });
          
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Note moved'),
                duration: Duration(seconds: 1),
              ),
            );
          }
        } else {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Note not found or already in that folder'),
                backgroundColor: Colors.orange,
              ),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to move note: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _createDefaultNote() async {
    try {
      // First check if notes already exist to prevent duplicate creation
      final existingNotes = await DatabaseHelper.instance.getAllNotes(
        searchQuery: null,
        sortBy: 'id',
        filterTags: null,
      );
      
      if (existingNotes.isNotEmpty) {
        // Notes already exist, just load them normally
        setState(() {
          _isLoading = false;
        });
        // Don't call _loadNotes here to avoid recursion - let the caller handle it
        return;
      }
      
      // Clear filters when creating default note
      _searchQuery = '';
      _selectedTags.clear();
      if (_searchController.text.isNotEmpty) {
        _searchController.clear();
      }
      
      final noteId = await DatabaseHelper.instance.createNote('New Note');
      
      // Load the note directly without calling _loadNotes to avoid recursion
      final note = await DatabaseHelper.instance.getNote(noteId);
      if (note != null) {
        final noteTags = await DatabaseHelper.instance.getNoteTags(noteId);
        final tags = await DatabaseHelper.instance.getAllTags();
        
        setState(() {
          notes.clear();
          notes.add({
            'id': noteId,
            'title': note['title'] as String,
            'tags': noteTags,
          });
          _noteCanvasData[noteId] = NoteCanvasData();
          _availableTags = tags;
          selectedIndex = 0;
          _isLoading = false;
        });
      } else {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _loadNoteData(int noteId) async {
    // Always reload from database to ensure we have the latest data and correct alignment
    try {
      final data = await DatabaseHelper.instance.loadCanvasData(noteId);
      
      // Validate and fix matrix if corrupted
      Matrix4 matrix = Matrix4.copy(data.matrix);
      final determinant = matrix.determinant();
      if (!determinant.isFinite || determinant == 0 || determinant.isNaN) {
        // Matrix is corrupted, reset to identity
        matrix = Matrix4.identity();
      }
      
      // Validate scale
      double scale = data.scale;
      if (!scale.isFinite || scale <= 0 || scale.isNaN) {
        scale = 1.0;
      }
      
      // Create a deep copy to avoid reference sharing between notes
      setState(() {
        _noteCanvasData[noteId] = NoteCanvasData(
          strokes: data.strokes.map((s) => Stroke(List.from(s.points), color: s.color, penSize: s.penSize)).toList(),
          textElements: data.textElements.map((te) => TextElement(te.position, te.text)).toList(),
          matrix: matrix,
          scale: scale,
        );
      });
    } catch (e) {
      // If loading fails, use empty canvas data
      setState(() {
        _noteCanvasData[noteId] = NoteCanvasData();
      });
    }
  }

  Future<void> _saveNoteData(int noteId, NoteCanvasData data) async {
    // Create a deep copy before storing to avoid reference sharing
    final dataCopy = NoteCanvasData(
      strokes: data.strokes.map((s) => Stroke(List.from(s.points), color: s.color, penSize: s.penSize)).toList(),
      textElements: data.textElements.map((te) => TextElement(te.position, te.text)).toList(),
      matrix: Matrix4.copy(data.matrix),
      scale: data.scale,
    );
    // Only update if data actually changed to prevent unnecessary rebuilds
    final existingData = _noteCanvasData[noteId];
    if (existingData == null || 
        existingData.strokes.length != dataCopy.strokes.length ||
        existingData.textElements.length != dataCopy.textElements.length ||
        existingData.matrix != dataCopy.matrix ||
        existingData.scale != dataCopy.scale) {
      _noteCanvasData[noteId] = dataCopy;
      await DatabaseHelper.instance.saveCanvasData(noteId, dataCopy);
    }
  }

  Future<void> _deleteNote(BuildContext context, int index, int noteId) async {
    // Don't allow deleting if it's the only note
    if (notes.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot delete the last note'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Note'),
        content: Text('Are you sure you want to delete "${notes[index]['title']}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Delete from database
        await DatabaseHelper.instance.deleteNote(noteId);
        
        // Determine new selectedIndex before removing the note
        int newSelectedIndex = selectedIndex;
        if (selectedIndex >= notes.length - 1) {
          // If deleting the last note or beyond, select the new last note
          newSelectedIndex = notes.length - 2;
        } else if (selectedIndex > index) {
          // If we deleted a note before the selected one, adjust index down
          newSelectedIndex = selectedIndex - 1;
        } else if (selectedIndex == index) {
          // If we deleted the currently selected note, stay at same index (which will be the next note)
          newSelectedIndex = selectedIndex;
          if (newSelectedIndex >= notes.length - 1) {
            newSelectedIndex = notes.length - 2;
          }
        }
        
        // Clean up controllers
        _noteControllers[noteId]?.dispose();
        _noteControllers.remove(noteId);
        
        // Remove canvas data
        _noteCanvasData.remove(noteId);
        
        // Remove from notes list
        notes.removeAt(index);
        
        // Update selectedIndex and reload all notes' data to ensure correct alignment
        setState(() {
          selectedIndex = newSelectedIndex.clamp(0, notes.length - 1);
        });
        
        // Reload all notes' canvas data to ensure correct alignment after deletion
        for (final note in notes) {
          final id = note['id'] as int;
          await _loadNoteData(id);
        }
        
        // Ensure the selected note's data is loaded
        if (selectedIndex >= 0 && selectedIndex < notes.length) {
          final newNoteId = notes[selectedIndex]['id'] as int;
          await _loadNoteData(newNoteId);
        }
        
        // Force a rebuild to update the UI
        if (mounted) {
          setState(() {});
        }
        
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Note deleted'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to delete note: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Theme.of(context).canvasColor,
      drawer: Drawer(
        child: Column(
          children: [
            DrawerHeader(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  'Your Notes',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
            ),
            // Search bar
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: 'Search notes...',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() {
                              _searchQuery = '';
                            });
                            _applyFilters();
                          },
                        )
                      : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                  _applyFilters();
                },
              ),
            ),
            // Sort dropdown
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: DropdownButton<String>(
                value: _sortBy,
                isExpanded: true,
                items: const [
                  DropdownMenuItem(value: 'id', child: Text('Creation Order')),
                  DropdownMenuItem(value: 'title', child: Text('Title (A-Z)')),
                  DropdownMenuItem(value: 'date_created', child: Text('Date Created')),
                  DropdownMenuItem(value: 'date_modified', child: Text('Recently Modified')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _sortBy = value;
                    });
                    _applyFilters();
                  }
                },
              ),
            ),
            // Tags filter
            if (_availableTags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: _availableTags.map((tag) {
                    final isSelected = _selectedTags.contains(tag);
                    return FilterChip(
                      label: Text(tag),
                      selected: isSelected,
                      onSelected: (selected) {
                        setState(() {
                          if (selected) {
                            _selectedTags.add(tag);
                          } else {
                            _selectedTags.remove(tag);
                          }
                        });
                        _applyFilters();
                      },
                    );
                  }).toList(),
                ),
              ),
            Expanded(
              child: _buildNotesList(),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings),
              title: const Text('Settings'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SettingsPage(
                      onThemeModeChanged: widget.onThemeModeChanged,
                      onDatabaseWiped: () {
                        // Reload notes after database wipe
                        _loadNotes();
                      },
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : (notes.isEmpty
                  ? const Center(child: Text('No notes available'))
                  : (selectedIndex >= 0 && selectedIndex < notes.length
                      ? () {
                          final noteId = notes[selectedIndex]['id'] as int;
                          // Get or create a GlobalKey for this note's canvas to preserve state
                          if (!_canvasKeys.containsKey(noteId)) {
                            _canvasKeys[noteId] = GlobalKey();
                          }
                          return InfiniteCanvas(
                            key: _canvasKeys[noteId],
                            noteId: noteId,
                            initialData: _noteCanvasData[noteId] ?? NoteCanvasData(),
                            onDataChanged: (data) async {
                              if (selectedIndex >= 0 && selectedIndex < notes.length) {
                                await _saveNoteData(noteId, data);
                              }
                            },
                          );
                        }()
                      : const Center(child: Text('No note selected')))),
          // Floating buttons and title
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            left: 16,
            child: Row(
              children: [
                // Hamburger menu button
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[700],
                  child: IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                    tooltip: 'Menu',
                  ),
                ),
                const SizedBox(width: 8),
                // Add note button
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[700],
                  child: IconButton(
                    icon: const Icon(Icons.add),
                    tooltip: 'Add Note',
                    onPressed: () async {
                      // Clear filters to ensure new note is visible
                      setState(() {
                        _searchQuery = '';
                        _selectedTags.clear();
                        _searchController.clear();
                      });
                      
                      // Get total note count for proper naming (ignoring filters)
                      final allNotes = await DatabaseHelper.instance.getAllNotes(searchQuery: null, sortBy: 'id', filterTags: null);
                      final noteId = await DatabaseHelper.instance.createNote('Note ${allNotes.length + 1}');
                      // Load the new note's data from database (even though it's empty, ensures consistency)
                      await _loadNoteData(noteId);
                      await _loadNotes(); // Reload to get tags
                      setState(() {
                        // Find the index of the newly created note
                        final index = notes.indexWhere((n) => n['id'] == noteId);
                        if (index >= 0) {
                          selectedIndex = index;
                        } else if (notes.isNotEmpty) {
                          // If note not found (shouldn't happen), select first note
                          selectedIndex = 0;
                        }
                        // Ensure canvas data is set
                        if (!_noteCanvasData.containsKey(noteId)) {
                          _noteCanvasData[noteId] = NoteCanvasData();
                        }
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                // Note title with same background and height as buttons
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[700],
                  child: SizedBox(
                    height: 48, // Match IconButton height (48px)
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          _isLoading 
                              ? 'Loading...' 
                              : (selectedIndex < notes.length ? notes[selectedIndex]['title'] as String : 'Infinite Notes'),
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  
  Future<void> _showTagEditor(BuildContext context, int noteId, List<String> currentTags) async {
    final tagController = TextEditingController(text: currentTags.join(', '));
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Tags'),
        content: TextField(
          controller: tagController,
          decoration: const InputDecoration(
            hintText: 'Enter tags separated by commas',
            labelText: 'Tags',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final tags = tagController.text
                  .split(',')
                  .map((t) => t.trim())
                  .where((t) => t.isNotEmpty)
                  .toList();
              Navigator.pop(context, tags);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    
    if (result != null) {
      await DatabaseHelper.instance.setNoteTags(noteId, result);
      await _loadNotes();
    }
  }
  
  @override
  void dispose() {
    for (final controller in _noteControllers.values) {
      controller.dispose();
    }
    _noteControllers.clear();
    _searchController.dispose();
    super.dispose();
  }
}

class InfiniteCanvas extends StatefulWidget {
  final int noteId;
  final NoteCanvasData? initialData;
  final Function(NoteCanvasData) onDataChanged;
  
  const InfiniteCanvas({
    super.key,
    required this.noteId,
    this.initialData,
    required this.onDataChanged,
  });

  @override
  State<InfiniteCanvas> createState() => _InfiniteCanvasState();
}

// Intent for submitting text (Enter key)
class _SubmitTextIntent extends Intent {
  const _SubmitTextIntent();
}

class _InfiniteCanvasState extends State<InfiniteCanvas> {
  late Matrix4 _matrix;
  late double _scale;
  late List<Stroke> _strokes;
  late List<TextElement> _textElements;
  
  Stroke? _currentStroke;
  final List<CanvasState> _undoStack = [];
  final List<CanvasState> _redoStack = [];
  bool _eraserMode = false;
  
  // Drawing color
  Color _selectedColor = Colors.black;
  bool _showColorPicker = false;
  bool _useColorWheel = false; // false = BlockPicker, true = ColorPicker (wheel)
  
  // Pen size (base width multiplier, 0.5 to 10.0)
  double _penSize = 1.0;
  
  // Text mode
  bool _textMode = false;
  TextElement? _activeTextElement;
  int? _editingTextElementIndex; // Index of text element being edited, null if creating new
  final FocusNode _textFocusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();
  DateTime? _textElementCreatedAt; // Track when text element was created to prevent immediate dismissal
  bool _textElementHasBeenFocused = false; // Track if text element has ever received focus

  Offset _lastFocalPoint = Offset.zero;
  int _pointerCount = 0;
  
  // Store theme brightness to ensure it's always current
  Brightness? _lastBrightness;
  
  // Panning state
  bool _isPanning = false;
  Offset? _panStartPosition; // Initial position when panning started
  Offset? _lastPanPosition; // Previous position for incremental delta calculation
  
  // Minimap state
  bool _showMinimap = true;
  
  // Text font size
  double _textFontSize = 16.0;
  
  // Collapsible menu state
  bool _showToolMenu = false;
  bool _showPenSizeControl = false;
  
  // Drawing indicator position
  Offset? _drawingIndicatorPosition;
  
  @override
  void initState() {
    super.initState();
    _loadCanvasData();
    
    // Listen for focus changes to track when text element has been focused
    _textFocusNode.addListener(() {
      if (_textFocusNode.hasFocus && _activeTextElement != null) {
        setState(() {
          _textElementHasBeenFocused = true;
        });
      }
    });
  }
  
  @override
  void didUpdateWidget(InfiniteCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    
    // If note ID changed, save current data and load the new note's canvas data
    if (oldWidget.noteId != widget.noteId) {
      _saveCurrentData();
      _loadCanvasData();
    } else if (oldWidget.initialData != widget.initialData) {
      // If same note but data changed (e.g., loaded from database), reload
      // BUT: NEVER reload if we have an active text element OR if one was recently created
      // This prevents the text box from disappearing during rebuilds
      
      // Check if text element was recently created (even if state was reset)
      final now = DateTime.now();
      final recentlyCreated = _textElementCreatedAt != null && 
          now.difference(_textElementCreatedAt!).inMilliseconds < 5000; // 5 seconds - increased for safety
      
      // Also check if text controller has text (indicates active editing)
      final hasText = _textController.text.isNotEmpty;
      
      if (_activeTextElement == null && !recentlyCreated && !hasText) {
        // Use a deep comparison to detect actual changes
        final dataEqual = _dataEquals(oldWidget.initialData, widget.initialData);
        if (!dataEqual) {
          _loadCanvasData();
        } else {
        }
      } else {
      }
    } else {
    }
  }
  
  bool _dataEquals(NoteCanvasData? a, NoteCanvasData? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.strokes.length != b.strokes.length) return false;
    if (a.textElements.length != b.textElements.length) return false;
    // For performance, just check lengths - full comparison would be expensive
    return true;
  }
  
  void _loadCanvasData() {
    
    // NEVER reload if we have an active text element OR if one was recently created
    // Check both the current state and the creation timestamp to catch cases where
    // the widget was rebuilt and state was reset but the text element should still exist
    final now = DateTime.now();
    final recentlyCreated = _textElementCreatedAt != null && 
        now.difference(_textElementCreatedAt!).inMilliseconds < 2000; // 2 seconds
    
    if (_activeTextElement != null || recentlyCreated) {
      // Even if blocked, preserve the matrix to prevent it from changing
      return;
    }
    
    // Create a deep copy to ensure we're not sharing references
    final data = widget.initialData ?? NoteCanvasData();
    
    // PRESERVE active text element and related state - don't lose it during reload
    // (Even though we check above, preserve it just in case)
    final preservedActiveTextElement = _activeTextElement;
    final preservedEditingTextElementIndex = _editingTextElementIndex;
    final preservedTextElementCreatedAt = _textElementCreatedAt;
    final preservedTextElementHasBeenFocused = _textElementHasBeenFocused;
    final preservedTextControllerText = _textController.text;
    // PRESERVE current matrix if text element is active (lock position)
    final preservedMatrix = _activeTextElement != null ? Matrix4.copy(_matrix) : null;
    final preservedScale = _activeTextElement != null ? _scale : null;
    
    setState(() {
      // If we have an active text element, DON'T change the matrix (lock position)
      if (preservedActiveTextElement != null && preservedMatrix != null) {
        _matrix = preservedMatrix;
        _scale = preservedScale ?? _scale;
      } else {
        // Validate and fix matrix if corrupted
        Matrix4 matrix = Matrix4.copy(data.matrix);
        final determinant = matrix.determinant();
        if (!determinant.isFinite || determinant == 0 || determinant.isNaN) {
          // Matrix is corrupted, reset to identity
          matrix = Matrix4.identity();
        }
        _matrix = matrix;
        
        // Validate scale
        double scale = data.scale;
        if (!scale.isFinite || scale <= 0 || scale.isNaN) {
          scale = 1.0;
        }
        _scale = scale;
      }
      
      
      // Create new lists to avoid reference sharing
      _strokes = data.strokes.map((s) => Stroke(List.from(s.points), color: s.color, penSize: s.penSize)).toList();
      _textElements = data.textElements.map((te) => TextElement(te.position, te.text)).toList();
      _currentStroke = null;
      _undoStack.clear();
      _redoStack.clear();
      
      // RESTORE preserved text element state
      _activeTextElement = preservedActiveTextElement;
      _editingTextElementIndex = preservedEditingTextElementIndex;
      _textElementCreatedAt = preservedTextElementCreatedAt;
      _textElementHasBeenFocused = preservedTextElementHasBeenFocused;
      if (preservedTextControllerText.isNotEmpty) {
        _textController.text = preservedTextControllerText;
      }
    });
    
  }
  
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Initialize color based on theme - this is called after initState and when dependencies change
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    if (_selectedColor == Colors.black && isDark) {
      setState(() {
        _selectedColor = Colors.white;
      });
    } else if (_selectedColor == Colors.white && !isDark) {
      setState(() {
        _selectedColor = Colors.black;
      });
    }
  }
  
  void _saveCurrentData() {
    // Don't save if we have an active text element that hasn't been focused yet
    // This prevents triggering parent reloads that cause the text box to disappear
    if (_activeTextElement != null && !_textElementHasBeenFocused) {
      return;
    }
    
    widget.onDataChanged(NoteCanvasData(
      strokes: _strokes,
      textElements: _textElements,
      matrix: _matrix,
      scale: _scale,
    ));
  }
  
  void _submitText() {
    setState(() {
      final value = _textController.text;
      if (value.isNotEmpty && _activeTextElement != null) {
        _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
        if (_editingTextElementIndex != null) {
          // Update existing text element
          _textElements[_editingTextElementIndex!] = TextElement(
            _activeTextElement!.position,
            value,
          );
        } else {
          // Add new text element
          _textElements.add(TextElement(_activeTextElement!.position, value));
        }
        _redoStack.clear();
        _saveCurrentData();
      }
      _activeTextElement = null;
      _editingTextElementIndex = null;
      _textController.clear();
      _textElementCreatedAt = null;
      _textElementHasBeenFocused = false;
      _textFocusNode.unfocus();
    });
  }
  
  Offset _transformToScreen(Offset localPoint) {
    final v = vm.Vector4(localPoint.dx, localPoint.dy, 0, 1);
    final r = _matrix.transform(v);
    return Offset(r.x, r.y);
  }
  
  // Calculate bounds of all content (strokes and text)
  Rect _calculateContentBounds() {
    if (_strokes.isEmpty && _textElements.isEmpty) {
      // Return default bounds if no content
      return const Rect.fromLTWH(-1000, -1000, 2000, 2000);
    }
    
    double minX = double.infinity;
    double minY = double.infinity;
    double maxX = double.negativeInfinity;
    double maxY = double.negativeInfinity;
    
    // Check all stroke points
    for (final stroke in _strokes) {
      for (final point in stroke.points) {
        minX = minX < point.position.dx ? minX : point.position.dx;
        minY = minY < point.position.dy ? minY : point.position.dy;
        maxX = maxX > point.position.dx ? maxX : point.position.dx;
        maxY = maxY > point.position.dy ? maxY : point.position.dy;
      }
    }
    
    // Check all text elements
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    
    for (final textElement in _textElements) {
      if (textElement.text.isEmpty) continue;
      textPainter.text = _markdownToTextSpan(textElement.text, textColor, baseFontSize: _textFontSize);
      textPainter.layout();
      
      final textWidth = textPainter.width;
      final textHeight = textPainter.height;
      
      minX = minX < textElement.position.dx ? minX : textElement.position.dx;
      minY = minY < textElement.position.dy ? minY : textElement.position.dy;
      maxX = maxX > (textElement.position.dx + textWidth) ? maxX : (textElement.position.dx + textWidth);
      maxY = maxY > (textElement.position.dy + textHeight) ? maxY : (textElement.position.dy + textHeight);
    }
    
    // Add padding
    const padding = 100.0;
    return Rect.fromLTRB(
      minX - padding,
      minY - padding,
      maxX + padding,
      maxY + padding,
    );
  }
  
  // Calculate current viewport bounds in canvas coordinates
  Rect _calculateViewportBounds(Size screenSize) {
    // Transform screen corners to canvas coordinates using the inverse matrix
    // The screen coordinates are relative to the Listener widget which fills the Stack
    
    // Get the four corners of the visible screen area
    final topLeft = Offset(0, 0);
    final topRight = Offset(screenSize.width, 0);
    final bottomLeft = Offset(0, screenSize.height);
    final bottomRight = Offset(screenSize.width, screenSize.height);
    
    // Transform each corner to canvas coordinates
    final canvasTopLeft = _transformToLocal(topLeft);
    final canvasTopRight = _transformToLocal(topRight);
    final canvasBottomLeft = _transformToLocal(bottomLeft);
    final canvasBottomRight = _transformToLocal(bottomRight);
    
    // Find the bounding box of all transformed corners
    // This gives us the actual viewport bounds in canvas coordinates
    final xCoords = [canvasTopLeft.dx, canvasTopRight.dx, canvasBottomLeft.dx, canvasBottomRight.dx];
    final yCoords = [canvasTopLeft.dy, canvasTopRight.dy, canvasBottomLeft.dy, canvasBottomRight.dy];
    
    final minX = xCoords.reduce((a, b) => a < b ? a : b);
    final maxX = xCoords.reduce((a, b) => a > b ? a : b);
    final minY = yCoords.reduce((a, b) => a < b ? a : b);
    final maxY = yCoords.reduce((a, b) => a > b ? a : b);
    
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  @override
  Widget build(BuildContext context) {
    // Get theme brightness directly from context and track changes
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    
    // Initialize color based on theme if not set
    if (_selectedColor == Colors.black && isDark) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedColor == Colors.black) {
          setState(() {
            _selectedColor = Colors.white;
          });
        }
      });
    } else if (_selectedColor == Colors.white && !isDark) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedColor == Colors.white) {
          setState(() {
            _selectedColor = Colors.black;
          });
        }
      });
    }
    
    // Force rebuild if brightness changed
    if (_lastBrightness != null && _lastBrightness != brightness) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _lastBrightness = brightness;
          });
        }
      });
    } else {
      _lastBrightness = brightness;
    }
    
    return Stack(
      children: [
        Listener(
          onPointerDown: (e) {
            setState(() => _pointerCount++);
            // Don't interfere - just track pointer count for multi-touch detection
          },
          onPointerUp: (e) {
            setState(() => _pointerCount = (_pointerCount - 1).clamp(0, 10));
            // Don't interfere - just track pointer count for multi-touch detection
          },
          onPointerSignal: (event) {
            // Lock canvas position when text box is active
            if (_activeTextElement != null) {
              return; // Don't allow scrolling while text box is active
            }
            
            // Handle mouse wheel scrolling for zoom
            if (event.kind == ui.PointerDeviceKind.mouse) {
              // Try to access scrollDelta property (available on scroll events)
              try {
                // Use dynamic access since scrollDelta might not be in the type definition
                // but is available at runtime for scroll events
                final scrollDelta = (event as dynamic).scrollDelta;
                
                if (scrollDelta != null) {
                  final delta = scrollDelta as Offset;
                  
                  if (delta.dy.abs() > 0.1) { // Only zoom if there's significant vertical scroll
                    setState(() {
                      // Use vertical scroll for zoom
                      // Negative dy means scroll up (zoom in), positive dy means scroll down (zoom out)
                      // Scale factor based on scroll amount for smoother zooming
                      final scrollAmount = delta.dy.abs();
                      final baseZoomFactor = scrollAmount > 10 ? 1.15 : 1.1; // Faster zoom for larger scrolls
                      final zoomFactor = delta.dy < 0 ? baseZoomFactor : 1.0 / baseZoomFactor;
                      
                      // Get the focal point (mouse position) in screen coordinates
                      final focalPoint = event.localPosition;
                      
                      // Transform focal point to canvas coordinates
                      final focal = _transformToLocal(focalPoint);
                      
                      // Create transformation matrix for scaling around focal point
                      // This is: T(-focal) * S(scale) * T(focal)
                      final scaleTransform = Matrix4.identity()
                        ..translate(-focal.dx, -focal.dy, 0)
                        ..scale(zoomFactor)
                        ..translate(focal.dx, focal.dy, 0);
                      
                      // Apply scaling transformation
                      _matrix = scaleTransform * _matrix;
                      
                      _saveCurrentData();
                    });
                  }
                }
              } catch (e) {
                // If scrollDelta is not available on this platform, ignore
                // This can happen on some platforms or Flutter versions
              }
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (details) {
              _lastFocalPoint = details.focalPoint;
              _scale = 1.0; // Initialize scale to 1.0 for relative scaling
            },
            onScaleUpdate: (details) {
              // Lock canvas position/zoom when text box is active
              if (_activeTextElement != null) {
                return; // Don't allow panning/zooming while text box is active
              }
              
              // Handle both single-finger panning (when scale is 1.0) and two-finger pinch zoom
              if (details.pointerCount >= 2) {
                setState(() {
                  // Handle panning (translation)
                  final dx = details.focalPoint.dx - _lastFocalPoint.dx;
                  final dy = details.focalPoint.dy - _lastFocalPoint.dy;
                  
                  // Handle zooming (scaling)
                  final newScale = details.scale;
                  final scaleFactor = newScale / _scale;
                  
                  // Only apply scaling if scale actually changed (avoid unnecessary updates)
                  if (scaleFactor != 1.0) {
                    // Get the focal point in screen coordinates (where the user is pinching)
                    final focalScreen = details.focalPoint;
                    
                    // Transform focal point to canvas coordinates using current matrix
                    final focalCanvas = _transformToLocal(focalScreen);
                    
                    // To scale around the focal point while keeping it fixed in screen space:
                    // We want the canvas point at focalCanvas to map to the same screen position
                    // after scaling. The formula is:
                    // newMatrix = T(focalScreen) * S(scaleFactor) * T(-focalScreen) * oldMatrix
                    // But since we're applying to the matrix that goes from canvas to screen,
                    // we need to work in canvas space:
                    // newMatrix = oldMatrix * T(-focalCanvas) * S(1/scaleFactor) * T(focalCanvas)
                    // Wait, that's backwards. Let me think...
                    //
                    // Actually, the matrix transforms canvas -> screen
                    // To scale around a screen point, we need:
                    // newMatrix = T(focalScreen) * S(scaleFactor) * T(-focalScreen) * oldMatrix
                    // But we want to apply it as: newMatrix = scaleTransform * oldMatrix
                    // So: scaleTransform = T(focalScreen) * S(scaleFactor) * T(-focalScreen)
                    //
                    // However, since we're working in canvas space for the matrix,
                    // we need to transform the focal point to canvas space first
                    final scaleTransform = Matrix4.identity()
                      ..translate(focalScreen.dx, focalScreen.dy, 0)
                      ..scale(scaleFactor)
                      ..translate(-focalScreen.dx, -focalScreen.dy, 0);
                    
                    // Apply: newMatrix = scaleTransform * oldMatrix
                    _matrix = scaleTransform * _matrix;
                  }
                  
                  // Apply translation (panning)
                  if (dx != 0 || dy != 0) {
                    final currentTranslation = _matrix.getTranslation();
                    final newX = currentTranslation.x + dx;
                    final newY = currentTranslation.y + dy;
                    final newZ = currentTranslation.z;
                    
                    // Update translation in matrix
                    final newMatrix = Matrix4.copy(_matrix);
                    newMatrix.storage[12] = newX;
                    newMatrix.storage[13] = newY;
                    newMatrix.storage[14] = newZ;
                    _matrix = newMatrix;
                  }
                  
                  // Update state
                  _scale = newScale;
                  _lastFocalPoint = details.focalPoint;
                  _saveCurrentData();
                });
              }
            },
            onScaleEnd: (_) => _scale = 1.0,
            child: Transform(
                key: ValueKey('transform_${_matrix.getTranslation()}'),
                transform: _matrix,
                child: CustomPaint(
                  // Key includes note ID and current stroke point count to force repaint during drawing
                  key: ValueKey('canvas_${widget.noteId}_${isDark}_${_strokes.length}_${_textElements.length}_${_currentStroke?.points.length ?? 0}'),
                  painter: _CanvasPainter(
                    _strokes, // Pass direct reference so changes are immediately visible
                    _textElements,
                    isDark,
                    _textFontSize,
                  ),
                  child: SizedBox(width: 20000, height: 20000),
                ),
              ),
            ),
          ),
        Positioned.fill(
          child: IgnorePointer(
            ignoring: _pointerCount >= 2, // Ignore when multi-touch to let GestureDetector handle it
            child: Listener(
              onPointerDown: (event) {
                // CRITICAL: Don't interfere with multi-touch gestures - let GestureDetector handle them
                // Check pointer count FIRST before doing anything else
                if (_pointerCount >= 2) {
                  // Cancel any stroke that might have been started by the first touch
                  if (_currentStroke != null) {
                    setState(() {
                      if (_strokes.isNotEmpty && _strokes.last == _currentStroke) {
                        _strokes.removeLast();
                      }
                      _currentStroke = null;
                    });
                  }
                  return; // Let GestureDetector handle pinch zoom and two-finger pan
                }
              
              // Don't intercept if text field is active
              if (_activeTextElement != null) return;
              
              final isStylus = event.kind == ui.PointerDeviceKind.stylus || event.kind == ui.PointerDeviceKind.invertedStylus;
              final isMouse = event.kind == ui.PointerDeviceKind.mouse;
              final isTouch = event.kind == ui.PointerDeviceKind.touch;
              
              // If this is a touch event and there's already a current stroke, this might be the start of multi-touch
              // Cancel the stroke to prevent dots from appearing
              if (isTouch && _currentStroke != null && _pointerCount == 1) {
                setState(() {
                  if (_strokes.isNotEmpty && _strokes.last == _currentStroke) {
                    _strokes.removeLast();
                  }
                  _currentStroke = null;
                });
                return; // Let GestureDetector handle multi-touch
              }
              
              
              // Check for right-click panning FIRST (before drawing)
              // Note: buttons might not be set on onPointerDown, so we'll also check in onPointerMove
              // But we can prevent stroke creation here if buttons is available
              if (isMouse && event.buttons == 2) {
                // Right-click panning - prevent drawing
                setState(() {
                  _isPanning = true;
                  _panStartPosition = event.localPosition;
                  _lastPanPosition = event.localPosition; // Initialize last position
                  // Cancel any active stroke
                  if (_currentStroke != null) {
                    // Remove the stroke from strokes list if it was just added
                    if (_strokes.isNotEmpty && _strokes.last == _currentStroke) {
                      _strokes.removeLast();
                    }
                    _currentStroke = null;
                  }
                });
                return;
              }
              
              // Don't start drawing if we're panning
              if (_isPanning) {
                return;
              }
              
              // Allow touch drawing on Android - only pan with two fingers or long press
              if (isStylus || (isMouse && !_textMode) || (isTouch && !_textMode)) {
                // Double-check we're not panning (buttons might not have been set on down)
                if (isMouse && event.buttons == 2) {
                  setState(() {
                    _isPanning = true;
                    _panStartPosition = event.localPosition;
                    _lastPanPosition = event.localPosition; // Initialize last position
                    _currentStroke = null;
                  });
                  return;
                }
                
                final local = _transformToLocal(event.localPosition);
                final brightness = Theme.of(context).brightness;
                final isDark = brightness == Brightness.dark;
                final eraserColor = isDark ? const Color(0xFF121212) : Colors.white;
                
                setState(() {
                  final pressure = isStylus ? event.pressure : 0.5;
                  // Eraser uses 2x pen size for easier erasing
                  final effectivePenSize = _eraserMode ? _penSize * 2.0 : _penSize;
                  _currentStroke = Stroke(
                    [Point(local, pressure)], 
                    color: _eraserMode ? eraserColor : _selectedColor,
                    penSize: effectivePenSize,
                  );
                  _drawingIndicatorPosition = event.localPosition;
                  _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
                  _strokes.add(_currentStroke!);
                  _redoStack.clear();
                  _saveCurrentData();
                });
              } else if ((isMouse || isTouch) && _textMode) {
                // Click/tap to place text cursor or edit existing text
                final local = _transformToLocal(event.localPosition);
                
                // Check if clicking on an existing text element
                int? clickedTextIndex;
                // Get text color from theme
                final brightness = Theme.of(context).brightness;
                final isDark = brightness == Brightness.dark;
                final textColor = isDark ? Colors.white : Colors.black;
                for (int i = _textElements.length - 1; i >= 0; i--) {
                  if (_textElements[i].hitTest(local, fontSize: _textFontSize, textColor: textColor)) {
                    clickedTextIndex = i;
                    break;
                  }
                }
                
                setState(() {
                  if (clickedTextIndex != null) {
                    // Edit existing text element
                    _editingTextElementIndex = clickedTextIndex;
                    _activeTextElement = TextElement(
                      _textElements[clickedTextIndex].position,
                      _textElements[clickedTextIndex].text,
                    );
                    _textController.text = _textElements[clickedTextIndex].text;
                  } else {
                    // Create new text element
                    _editingTextElementIndex = null;
                    _activeTextElement = TextElement(local, '');
                    _textController.clear();
                  }
                  // Track when text element was created to prevent immediate dismissal
                  _textElementCreatedAt = DateTime.now();
                  _textElementHasBeenFocused = false; // Reset focus tracking
                });
                
                // Request focus using post-frame callback to ensure widget is built and stable
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  // Use a small delay to ensure the TextField widget is fully built
                  Future.delayed(const Duration(milliseconds: 100), () {
                    if (mounted && _activeTextElement != null) {
                      _textFocusNode.requestFocus();
                      // Mark as focused after a short delay to ensure focus is actually set
                      Future.delayed(const Duration(milliseconds: 150), () {
                        if (mounted && _activeTextElement != null && _textFocusNode.hasFocus) {
                          setState(() {
                            _textElementHasBeenFocused = true;
                          });
                        } else {
                          // Retry focus request if it failed
                          if (mounted && _activeTextElement != null && !_textFocusNode.hasFocus) {
                            _textFocusNode.requestFocus();
                          }
                        }
                      });
                      // Move cursor to end of text when editing
                      if (_editingTextElementIndex != null) {
                        _textController.selection = TextSelection.fromPosition(
                          TextPosition(offset: _textController.text.length),
                        );
                      }
                    } else {
                    }
                  });
                });
              }
            },
            onPointerMove: (event) {
              // CRITICAL: Don't interfere with multi-touch gestures - let GestureDetector handle them
              // Check pointer count FIRST before doing anything else
              if (_pointerCount >= 2) {
                return; // Let GestureDetector handle pinch zoom and two-finger pan
              }
              
              // Don't intercept if text field is active
              if (_activeTextElement != null) return;
              
              final isStylus = event.kind == ui.PointerDeviceKind.stylus || event.kind == ui.PointerDeviceKind.invertedStylus;
              final isMouse = event.kind == ui.PointerDeviceKind.mouse;
              final isTouch = event.kind == ui.PointerDeviceKind.touch;
              
              
              // Check for right-click panning (buttons == 2 means right mouse button)
              if (isMouse && event.buttons == 2 && !_isPanning) {
                // Start right-click panning
                setState(() {
                  _isPanning = true;
                  _panStartPosition = event.localPosition;
                  _lastPanPosition = event.localPosition; // Initialize last position
                  // Cancel any active stroke that might have been created
                  if (_currentStroke != null) {
                    // Remove the stroke from strokes list if it was just added
                    if (_strokes.isNotEmpty && _strokes.last == _currentStroke) {
                      _strokes.removeLast();
                    }
                    _currentStroke = null;
                  }
                });
                // Don't return - continue to panning handling below so first move is processed
              }
              
              // Lock canvas position when text box is active
              if (_activeTextElement != null && _isPanning) {
                // Cancel panning if text box is active
                setState(() {
                  _isPanning = false;
                  _panStartPosition = null;
                  _lastPanPosition = null;
                });
                return;
              }
              
              // Handle panning (right-click mouse or two-finger touch via GestureDetector)
              // Use the same approach as two-finger panning: calculate delta from previous position
              if (_isPanning && _lastPanPosition != null) {
                // Calculate delta from the previous position (like two-finger panning does)
                final dx = event.localPosition.dx - _lastPanPosition!.dx;
                final dy = event.localPosition.dy - _lastPanPosition!.dy;
                final translationBefore = _matrix.getTranslation();
                
                // Validate delta before applying (prevent NaN or infinite values)
                if (dx.isFinite && dy.isFinite && !dx.isNaN && !dy.isNaN) {
                  setState(() {
                    // Manually update translation by extracting current translation, adding delta, and setting it back
                    // This ensures proper accumulation regardless of other transformations in the matrix
                    final currentTranslation = _matrix.getTranslation();
                    final newX = currentTranslation.x + dx;
                    final newY = currentTranslation.y + dy;
                    final newZ = currentTranslation.z;
                    
                    // Create a new matrix with the updated translation
                    // Preserve scale and rotation by copying the matrix and then setting translation entries
                    // Translation is stored in matrix storage[12] (x), storage[13] (y), storage[14] (z)
                    final newMatrix = Matrix4.copy(_matrix);
                    newMatrix.storage[12] = newX;  // x translation
                    newMatrix.storage[13] = newY;  // y translation
                    newMatrix.storage[14] = newZ;  // z translation
                    _matrix = newMatrix;
                    
                    _lastPanPosition = event.localPosition; // Update last position for next frame
                    final translationAfter = _matrix.getTranslation();
                    // Don't save on every move to avoid performance issues
                    // Save will happen on pointer up
                  });
                } else {
                }
                return;
              }
              
              // If we were panning but buttons changed, stop panning
              if (_isPanning && isMouse && event.buttons != 2) {
                setState(() {
                  _isPanning = false;
                  _panStartPosition = null;
                  _lastPanPosition = null;
                  _saveCurrentData();
                });
                return;
              }
              
              // Don't draw if we're panning
              if (_isPanning) {
                return;
              }
              
              if (_currentStroke != null && (isStylus || (isMouse && !_textMode) || (isTouch && !_textMode))) {
                final local = _transformToLocal(event.localPosition);
                final pressure = isStylus ? event.pressure : 0.5;
                // Add point and immediately trigger repaint for real-time drawing
                _currentStroke!.points.add(Point(local, pressure));
                
                // Call setState immediately for real-time drawing
                // Use a microtask to batch rapid updates slightly without visible delay
                if (mounted) {
                  setState(() {
                    _drawingIndicatorPosition = event.localPosition;
                    // Trigger repaint - the point is already added above
                    // Save data periodically during drawing (but not every frame for performance)
                    if (_currentStroke!.points.length % 10 == 0) {
                      _saveCurrentData();
                    }
                  });
                }
              }
            },
            onPointerUp: (event) {
              
              // End panning if active
              if (_isPanning) {
                setState(() {
                  _isPanning = false;
                  _panStartPosition = null;
                  _lastPanPosition = null;
                  _saveCurrentData();
                });
                // Don't process drawing if we were panning
                return;
              }
              
              if (_activeTextElement == null) {
                // Always update on pointer up to ensure final point is drawn
                setState(() {
                  _currentStroke = null;
                  _drawingIndicatorPosition = null;
                  _saveCurrentData();
                });
              }
            },
            behavior: HitTestBehavior.translucent, // Allow events to pass through to GestureDetector below
            ),
          ),
        ),
        // Collapsible tool menu
        Positioned(
          top: MediaQuery.of(context).padding.top + 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Menu toggle button
              Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey[700],
                child: IconButton(
                  icon: Icon(_showToolMenu ? Icons.close : Icons.build),
                  tooltip: _showToolMenu ? 'Close Toolbox' : 'Open Toolbox',
                  onPressed: () => setState(() => _showToolMenu = !_showToolMenu),
                ),
              ),
              // Collapsible menu items
              if (_showToolMenu) ...[
                const SizedBox(height: 8),
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[700],
                  child: IconButton(
                    icon: const Icon(Icons.undo),
                    tooltip: 'Undo',
                    onPressed: undo,
                  ),
                ),
                const SizedBox(height: 8),
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: Colors.grey[700],
                  child: IconButton(
                    icon: const Icon(Icons.redo),
                    tooltip: 'Redo',
                    onPressed: redo,
                  ),
                ),
                const SizedBox(height: 8),
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: _eraserMode ? Theme.of(context).colorScheme.primary.withOpacity(0.3) : Colors.grey[700],
                  child: IconButton(
                    icon: Icon(_eraserMode ? Icons.cleaning_services : Icons.cleaning_services),
                    tooltip: _eraserMode ? 'Eraser (Active)' : 'Eraser',
                    onPressed: () => setState(() => _eraserMode = !_eraserMode),
                  ),
                ),
                const SizedBox(height: 8),
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: _textMode ? Theme.of(context).colorScheme.primary.withOpacity(0.3) : Colors.grey[700],
                  child: IconButton(
                    icon: Icon(_textMode ? Icons.text_fields : Icons.text_fields),
                    tooltip: _textMode ? 'Text Mode (Active)' : 'Text Mode',
                    onPressed: () => setState(() {
                      _textMode = !_textMode;
                      if (!_textMode) {
                        _textFocusNode.unfocus();
                        _activeTextElement = null;
                        _editingTextElementIndex = null;
                        _textController.clear();
                        _textElementCreatedAt = null;
                        _textElementHasBeenFocused = false;
                      }
                    }),
                  ),
                ),
                const SizedBox(height: 8),
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: _showColorPicker ? Theme.of(context).colorScheme.primary.withOpacity(0.3) : Colors.grey[700],
                  child: IconButton(
                    icon: const Icon(Icons.palette),
                    tooltip: _showColorPicker ? 'Color Picker (Open)' : 'Color Picker',
                    onPressed: () => setState(() => _showColorPicker = !_showColorPicker),
                  ),
                ),
                const SizedBox(height: 8),
                // Pen size control button
                Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  color: _showPenSizeControl ? Theme.of(context).colorScheme.primary.withOpacity(0.3) : Colors.grey[700],
                  child: IconButton(
                    icon: const Icon(Icons.edit),
                    tooltip: _showPenSizeControl ? 'Hide Pen Size' : 'Show Pen Size',
                    onPressed: () => setState(() => _showPenSizeControl = !_showPenSizeControl),
                  ),
                ),
                // Collapsible pen size control
                if (_showPenSizeControl) ...[
                  const SizedBox(height: 8),
                  Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey[700],
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      width: 200,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.edit, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                'Pen Size: ${_penSize.toStringAsFixed(1)}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                          if (_eraserMode) ...[
                            const SizedBox(height: 4),
                            Text(
                              'Eraser Size: ${(_penSize * 2.0).toStringAsFixed(1)}',
                              style: TextStyle(
                                fontSize: 11,
                                color: Theme.of(context).colorScheme.primary,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Slider(
                            value: _penSize,
                            min: 0.5,
                            max: 10.0,
                            divisions: 95,
                            label: _penSize.toStringAsFixed(1),
                            onChanged: (value) {
                              setState(() {
                                _penSize = value;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
        // Color picker overlay
        if (_showColorPicker)
          Builder(
            builder: (context) {
              final screenSize = MediaQuery.of(context).size;
              final isMobile = Platform.isAndroid || Platform.isIOS || screenSize.width < 600;
              
              // Adjust size and position for mobile
              final pickerWidth = isMobile ? 280.0 : 350.0;
              final pickerPadding = isMobile ? 8.0 : 12.0;
              final containerWidth = pickerWidth + (pickerPadding * 2);
              
              return Positioned(
                top: MediaQuery.of(context).padding.top + (isMobile ? 80 : 16),
                right: isMobile ? 8 : 80,
                left: isMobile ? 8 : null,
                child: SizedBox(
                  width: containerWidth,
                  child: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      width: pickerWidth,
                      constraints: BoxConstraints(
                        maxWidth: pickerWidth,
                        minWidth: pickerWidth,
                      ),
                      padding: EdgeInsets.all(pickerPadding),
                      decoration: BoxDecoration(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Tab selector for picker type
                          SizedBox(
                            width: pickerWidth,
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextButton.icon(
                                    icon: const Icon(Icons.grid_view, size: 18),
                                    label: const Text('Presets'),
                                    onPressed: () => setState(() => _useColorWheel = false),
                                    style: TextButton.styleFrom(
                                      backgroundColor: !_useColorWheel
                                          ? Theme.of(context).colorScheme.primary.withOpacity(0.2)
                                          : null,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextButton.icon(
                                    icon: const Icon(Icons.color_lens, size: 18),
                                    label: const Text('Custom'),
                                    onPressed: () => setState(() => _useColorWheel = true),
                                    style: TextButton.styleFrom(
                                      backgroundColor: _useColorWheel
                                          ? Theme.of(context).colorScheme.primary.withOpacity(0.2)
                                          : null,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Color picker widget (BlockPicker or ColorPicker)
                        _useColorWheel
                            ? MediaQuery(
                                // Override MediaQuery to give ColorPicker a fixed width context
                                // This prevents it from reacting to window width changes
                                data: MediaQuery.of(context).copyWith(
                                  size: Size(pickerWidth, isMobile ? 400 : 600),
                                ),
                                child: ClipRect(
                                  child: SizedBox(
                                    width: pickerWidth,
                                    child: ColorPicker(
                                      pickerColor: _selectedColor,
                                      onColorChanged: (color) {
                                        setState(() {
                                          _selectedColor = color;
                                        });
                                      },
                                      enableAlpha: false,
                                      displayThumbColor: true,
                                      paletteType: PaletteType.hslWithSaturation,
                                      pickerAreaHeightPercent: isMobile ? 0.5 : 0.6,
                                    ),
                                  ),
                                ),
                              )
                            : MediaQuery(
                                // Override MediaQuery to give BlockPicker a fixed width context
                                // This prevents it from reacting to window width changes
                                data: MediaQuery.of(context).copyWith(
                                  size: Size(pickerWidth, isMobile ? 400 : 600),
                                ),
                                child: ClipRect(
                                  child: SizedBox(
                                    width: pickerWidth,
                                    child: Align(
                                      alignment: Alignment.centerLeft,
                                      widthFactor: 1.0,
                                      child: BlockPicker(
                                        pickerColor: _selectedColor,
                                        onColorChanged: (color) {
                                          setState(() {
                                            _selectedColor = color;
                                          });
                                        },
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: pickerWidth,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                TextButton.icon(
                                  icon: const Icon(Icons.check, size: 18),
                                  label: const Text('Done'),
                                  onPressed: () => setState(() => _showColorPicker = false),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        // Font size adjuster (shown when in text mode and menu is open)
        if (_textMode && _showToolMenu)
          Positioned(
            top: MediaQuery.of(context).padding.top + 16,
            right: 80,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.format_size, size: 20),
                        const SizedBox(width: 8),
                        Text(
                          'Font Size: ${_textFontSize.toInt()}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Slider(
                      value: _textFontSize,
                      min: 8.0,
                      max: 48.0,
                      divisions: 40,
                      label: _textFontSize.toInt().toString(),
                      onChanged: (value) {
                        setState(() {
                          _textFontSize = value;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove),
                          onPressed: () {
                            setState(() {
                              _textFontSize = (_textFontSize - 1).clamp(8.0, 48.0);
                            });
                          },
                        ),
                        SizedBox(
                          width: 60,
                          child: Text(
                            '${_textFontSize.toInt()}',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: () {
                            setState(() {
                              _textFontSize = (_textFontSize + 1).clamp(8.0, 48.0);
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Text input overlay - placed last so it's on top
        // Only show dismiss handler after a delay to prevent immediate dismissal when creating text box
        // IMPORTANT: This must be AFTER the text box widget so taps on the text box are handled first
        if (_activeTextElement != null)
          Positioned.fill(
            child: IgnorePointer(
              ignoring: false,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () {
                  
                  // Prevent dismissal if text element was just created (within last 1500ms to be safe)
                  final now = DateTime.now();
                  if (_textElementCreatedAt != null) {
                    final timeSinceCreation = now.difference(_textElementCreatedAt!).inMilliseconds;
                    if (timeSinceCreation < 1500) {
                      return; // Don't dismiss if just created
                    }
                  }
                  
                  // Only dismiss if:
                  // 1. The text element has been focused at least once (to avoid dismissing before focus is set)
                  // 2. Focus is not currently active (user clicked outside after focusing)
                  if (_textElementHasBeenFocused && !_textFocusNode.hasFocus) {
                    setState(() {
                      if (_textController.text.isNotEmpty && _activeTextElement != null) {
                        _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
                        if (_editingTextElementIndex != null) {
                          // Update existing text element
                          _textElements[_editingTextElementIndex!] = TextElement(
                            _activeTextElement!.position,
                            _textController.text,
                          );
                        } else {
                          // Add new text element
                          _textElements.add(TextElement(_activeTextElement!.position, _textController.text));
                        }
                        _redoStack.clear();
                        _saveCurrentData();
                      }
                      _activeTextElement = null;
                      _editingTextElementIndex = null;
                      _textController.clear();
                      _textElementCreatedAt = null;
                      _textElementHasBeenFocused = false;
                      _textFocusNode.unfocus();
                    });
                  } else {
                  }
                },
                child: Container(color: Colors.transparent),
              ),
            ),
          ),
        // Drawing indicator circle
        if (_drawingIndicatorPosition != null && _currentStroke != null)
          Positioned(
            left: _drawingIndicatorPosition!.dx - (_eraserMode ? _penSize * 2.0 : _penSize) * 0.5,
            top: _drawingIndicatorPosition!.dy - (_eraserMode ? _penSize * 2.0 : _penSize) * 0.5,
            child: IgnorePointer(
              child: Container(
                width: (_eraserMode ? _penSize * 2.0 : _penSize).clamp(4.0, 50.0),
                height: (_eraserMode ? _penSize * 2.0 : _penSize).clamp(4.0, 50.0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _eraserMode 
                        ? Theme.of(context).colorScheme.error.withOpacity(0.8)
                        : _selectedColor.withOpacity(0.8),
                    width: 2,
                  ),
                  color: Colors.transparent,
                ),
              ),
            ),
          ),
        if (_activeTextElement != null)
          Positioned.fill(
            child: Center(
              child: GestureDetector(
                onTap: () {
                  // Prevent tap from propagating to dismiss handler
                },
                behavior: HitTestBehavior.opaque,
                child: Builder(
                  builder: (context) {
                    final brightness = Theme.of(context).brightness;
                    final isDark = brightness == Brightness.dark;
                    return Material(
                      elevation: 4,
                      borderRadius: BorderRadius.circular(4),
                      color: Theme.of(context).colorScheme.surface,
                      child: Container(
                        constraints: const BoxConstraints(minWidth: 200, maxWidth: 400),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          border: Border.all(
                            color: Colors.grey[700]!,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Shortcuts(
                              shortcuts: {
                                // Enter key submits (without Shift)
                                const SingleActivator(LogicalKeyboardKey.enter): const _SubmitTextIntent(),
                              },
                              child: Actions(
                                actions: {
                                  _SubmitTextIntent: CallbackAction<_SubmitTextIntent>(
                                    onInvoke: (intent) {
                                      _submitText();
                                      return null;
                                    },
                                  ),
                                },
                                child: TextField(
                                  controller: _textController,
                                  focusNode: _textFocusNode,
                                  autofocus: true,
                                  keyboardType: TextInputType.multiline,
                                  textInputAction: TextInputAction.newline,
                                  maxLines: null,
                                  minLines: 1,
                              style: TextStyle(
                                fontSize: _textFontSize,
                                color: Theme.of(context).colorScheme.onSurface,
                              ),
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                hintText: 'Type here... (Shift+Enter for new line)',
                                hintStyle: TextStyle(
                                  color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                                ),
                                    isDense: true,
                                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                                  ),
                                  onChanged: (value) {
                                    setState(() {
                                      if (_activeTextElement != null) {
                                        _activeTextElement = TextElement(_activeTextElement!.position, value);
                                      }
                                    });
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            // Save button
                            ElevatedButton(
                              onPressed: _submitText,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.grey[700]!,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 8),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(4),
                                ),
                              ),
                              child: const Text('Save'),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        // Minimap
        if (_showMinimap)
          Builder(
            builder: (context) {
              final screenSize = MediaQuery.of(context).size;
              final padding = MediaQuery.of(context).padding;
              // Calculate minimap size based on screen size
              // Use 20% of screen width/height, but cap at reasonable min/max sizes
              // Also ensure it doesn't overlap with buttons (right side has buttons at ~80px from right)
              final maxWidth = screenSize.width * 0.25;
              final maxHeight = screenSize.height * 0.25;
              // Ensure we leave space for buttons on the right (at least 100px)
              final availableWidth = screenSize.width - 100;
              final availableHeight = screenSize.height - padding.bottom - 32; // 16px bottom + 16px margin
              final minimapWidth = (maxWidth < availableWidth ? maxWidth : availableWidth).clamp(120.0, 300.0);
              final minimapHeight = (maxHeight < availableHeight ? maxHeight : availableHeight).clamp(120.0, 300.0);
              final minimapSize = Size(minimapWidth, minimapHeight);
              
              return Positioned(
                bottom: padding.bottom + 48, // Increased to 48 to better avoid gesture bar on Android
                right: 16,
                child: _MinimapWidget(
                  size: minimapSize,
                  strokes: _strokes,
                  textElements: _textElements,
                  contentBounds: _calculateContentBounds(),
                  viewportBounds: _calculateViewportBounds(screenSize),
                  isDark: isDark,
                  onTap: (localPoint) {
                    // Pan to the clicked location on the minimap
                    final contentBounds = _calculateContentBounds();
                    final scaleX = minimapSize.width / contentBounds.width;
                    final scaleY = minimapSize.height / contentBounds.height;
                    final scale = scaleX < scaleY ? scaleX : scaleY;
                    
                    // Calculate offset to center content in minimap
                    final offsetX = -contentBounds.left * scale;
                    final offsetY = -contentBounds.top * scale;
                    
                    // Convert minimap click position to canvas coordinates
                    final canvasX = (localPoint.dx - offsetX) / scale;
                    final canvasY = (localPoint.dy - offsetY) / scale;
                    final canvasPoint = Offset(canvasX, canvasY);
                    
                    // Center the viewport on this canvas point
                    final targetTranslation = vm.Vector3(
                      screenSize.width / 2 - canvasPoint.dx,
                      screenSize.height / 2 - canvasPoint.dy,
                      0,
                    );
                    
                    setState(() {
                      final currentTranslation = _matrix.getTranslation();
                      final newX = targetTranslation.x;
                      final newY = targetTranslation.y;
                      final newZ = currentTranslation.z;
                      
                      final newMatrix = Matrix4.copy(_matrix);
                      newMatrix.storage[12] = newX;
                      newMatrix.storage[13] = newY;
                      newMatrix.storage[14] = newZ;
                      _matrix = newMatrix;
                      _saveCurrentData();
                    });
                  },
                ),
              );
            },
          ),
      ],
    );
  }
  
  @override
  void dispose() {
    _textFocusNode.dispose();
    _textController.dispose();
    super.dispose();
  }

  Offset _transformToLocal(Offset screenPoint) {
    final determinant = _matrix.determinant();
    if (determinant == 0 || !determinant.isFinite) {
      return screenPoint;
    }
    final inverted = Matrix4.copy(_matrix)..invert();
    final v = vm.Vector4(screenPoint.dx, screenPoint.dy, 0, 1);
    final r = inverted.transform(v);
    return Offset(r.x, r.y);
  }

  void undo() {
    if (_undoStack.isNotEmpty) {
      setState(() {
        _redoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
        final state = _undoStack.removeLast();
        _strokes..clear()..addAll(state.strokes);
        _textElements..clear()..addAll(state.textElements);
        _saveCurrentData();
      });
    }
  }

  void redo() {
    if (_redoStack.isNotEmpty) {
      setState(() {
        _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
        final state = _redoStack.removeLast();
        _strokes..clear()..addAll(state.strokes);
        _textElements..clear()..addAll(state.textElements);
        _saveCurrentData();
      });
    }
  }
}

class CanvasState {
  final List<Stroke> strokes;
  final List<TextElement> textElements;
  CanvasState(this.strokes, this.textElements);
}

// Complete canvas state for a note (strokes, text, transform matrix, etc.)
class NoteCanvasData {
  final List<Stroke> strokes;
  final List<TextElement> textElements;
  final Matrix4 matrix;
  final double scale;
  
  NoteCanvasData({
    List<Stroke>? strokes,
    List<TextElement>? textElements,
    Matrix4? matrix,
    double? scale,
  })  : strokes = strokes ?? [],
        textElements = textElements ?? [],
        matrix = matrix ?? Matrix4.identity(),
        scale = scale ?? 1.0;
  
  NoteCanvasData copy() {
    return NoteCanvasData(
      strokes: List.from(strokes),
      textElements: List.from(textElements),
      matrix: Matrix4.copy(matrix),
      scale: scale,
    );
  }
  
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is NoteCanvasData &&
        other.strokes.length == strokes.length &&
        other.textElements.length == textElements.length &&
        other.scale == scale;
  }
  
  @override
  int get hashCode => Object.hash(strokes.length, textElements.length, scale);
}

class Point {
  final Offset position;
  final double pressure;
  Point(this.position, this.pressure);
}

class Stroke {
  final List<Point> points;
  final Color color;
  final double penSize;
  Stroke(this.points, {Color? color, double? penSize}) 
      : color = color ?? Colors.black,
        penSize = penSize ?? 1.0;

  bool hitTest(Offset pos) {
    for (final p in points) {
      if ((p.position - pos).distance < 12) return true;
    }
    return false;
  }

  Map<String, dynamic> toJson() {
    return {
      'points': points.map((p) => {
        'x': p.position.dx,
        'y': p.position.dy,
        'pressure': p.pressure,
      }).toList(),
      'color': color.value,
      'penSize': penSize,
    };
  }

  factory Stroke.fromJson(Map<String, dynamic> json) {
    final pointsData = json['points'] as List<dynamic>? ?? [];
    final points = pointsData.map((p) => Point(
      Offset((p['x'] as num).toDouble(), (p['y'] as num).toDouble()),
      (p['pressure'] as num?)?.toDouble() ?? 0.5,
    )).toList();
    final colorValue = json['color'] as int?;
    final color = colorValue != null ? Color(colorValue) : Colors.black;
    final penSize = (json['penSize'] as num?)?.toDouble() ?? 1.0;
    return Stroke(points, color: color, penSize: penSize);
  }
}

class TextElement {
  final Offset position;
  final String text;
  TextElement(this.position, this.text);

  /// Check if a point is within the bounds of this text element
  bool hitTest(Offset point, {required double fontSize, Color textColor = Colors.black}) {
    // Create a TextPainter to measure the text bounds (using markdown rendering for accurate size)
    final textPainter = TextPainter(
      text: _markdownToTextSpan(text, textColor, baseFontSize: fontSize),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    
    final textRect = Rect.fromLTWH(
      position.dx,
      position.dy,
      textPainter.width,
      textPainter.height,
    );
    
    return textRect.contains(point);
  }

  Map<String, dynamic> toJson() {
    return {
      'position': {'x': position.dx, 'y': position.dy},
      'text': text,
    };
  }

  factory TextElement.fromJson(Map<String, dynamic> json) {
    final pos = json['position'] as Map<String, dynamic>;
    return TextElement(
      Offset((pos['x'] as num).toDouble(), (pos['y'] as num).toDouble()),
      json['text'] as String,
    );
  }
}

/// Convert markdown text to a styled TextSpan
/// Supports: headers (#), bold (**text**), italic (*text*), inline code (`code`)
TextSpan _markdownToTextSpan(String markdownText, Color textColor, {double baseFontSize = 16.0}) {
  if (markdownText.isEmpty) {
    return TextSpan(text: '', style: TextStyle(color: textColor, fontSize: baseFontSize));
  }
  
  // Parse markdown using regex (simpler and more reliable for basic markdown)
  final lines = markdownText.split('\n');
  
  // Use a regex-based approach: parse line by line and handle inline formatting
  List<TextSpan> children = [];
  final baseStyle = TextStyle(color: textColor, fontSize: baseFontSize);
  
  // Process each line
  for (int lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    String line = lines[lineIndex];
    if (line.isEmpty) {
      if (lineIndex < lines.length - 1) {
        children.add(TextSpan(text: '\n', style: baseStyle));
      }
      continue;
    }
    
    // Check for headers
    TextStyle lineStyle = baseStyle;
    if (line.startsWith('# ')) {
      line = line.substring(2);
      lineStyle = baseStyle.copyWith(fontSize: baseFontSize * 2.0, fontWeight: FontWeight.bold);
    } else if (line.startsWith('## ')) {
      line = line.substring(3);
      lineStyle = baseStyle.copyWith(fontSize: baseFontSize * 1.75, fontWeight: FontWeight.bold);
    } else if (line.startsWith('### ')) {
      line = line.substring(4);
      lineStyle = baseStyle.copyWith(fontSize: baseFontSize * 1.5, fontWeight: FontWeight.bold);
    } else if (line.startsWith('#### ')) {
      line = line.substring(5);
      lineStyle = baseStyle.copyWith(fontSize: baseFontSize * 1.25, fontWeight: FontWeight.bold);
    } else if (line.startsWith('##### ') || line.startsWith('###### ')) {
      line = line.replaceFirst(RegExp(r'^#{5,6} '), '');
      lineStyle = baseStyle.copyWith(fontSize: baseFontSize * 1.1, fontWeight: FontWeight.bold);
    }
    
    // Process inline formatting: **bold**, *italic*, `code`
    int pos = 0;
    while (pos < line.length) {
      // Check for bold **text** or __text__
      final boldMatch = RegExp(r'\*\*(.+?)\*\*|__(.+?)__').firstMatch(line.substring(pos));
      // Check for italic *text* or _text_ (but not **)
      final italicMatch = RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)|(?<!_)_(?!_)(.+?)(?<!_)_(?!_)').firstMatch(line.substring(pos));
      // Check for inline code `code`
      final codeMatch = RegExp(r'`(.+?)`').firstMatch(line.substring(pos));
      
      // Find the earliest match
      int? earliestPos;
      String? matchType;
      String? matchText;
      
      if (boldMatch != null) {
        final matchPos = pos + boldMatch.start;
        if (earliestPos == null || matchPos < earliestPos) {
          earliestPos = matchPos;
          matchType = 'bold';
          matchText = boldMatch.group(1) ?? boldMatch.group(2) ?? '';
        }
      }
      
      if (italicMatch != null) {
        final matchPos = pos + italicMatch.start;
        if (earliestPos == null || matchPos < earliestPos) {
          earliestPos = matchPos;
          matchType = 'italic';
          matchText = italicMatch.group(1) ?? italicMatch.group(2) ?? '';
        }
      }
      
      if (codeMatch != null) {
        final matchPos = pos + codeMatch.start;
        if (earliestPos == null || matchPos < earliestPos) {
          earliestPos = matchPos;
          matchType = 'code';
          matchText = codeMatch.group(1) ?? '';
        }
      }
      
      if (earliestPos != null && matchType != null && matchText != null) {
        // Add text before the match
        if (earliestPos > pos) {
          children.add(TextSpan(text: line.substring(pos, earliestPos), style: lineStyle));
        }
        
        // Add the formatted text
        TextStyle formattedStyle = lineStyle;
        if (matchType == 'bold') {
          formattedStyle = lineStyle.copyWith(fontWeight: FontWeight.bold);
        } else if (matchType == 'italic') {
          formattedStyle = lineStyle.copyWith(fontStyle: FontStyle.italic);
        } else if (matchType == 'code') {
          formattedStyle = lineStyle.copyWith(
            fontFamily: 'monospace',
            backgroundColor: textColor.withOpacity(0.1),
          );
        }
        children.add(TextSpan(text: matchText, style: formattedStyle));
        
        // Move position past the match
        final matchLength = matchType == 'bold' ? matchText.length + 4 : 
                           matchType == 'code' ? matchText.length + 2 : matchText.length + 2;
        pos = earliestPos + matchLength;
      } else {
        // No more matches, add remaining text
        children.add(TextSpan(text: line.substring(pos), style: lineStyle));
        break;
      }
    }
    
    // Add newline after each line (except last)
    if (lineIndex < lines.length - 1) {
      children.add(TextSpan(text: '\n', style: baseStyle));
    }
  }
  
  // If no children were created, return simple TextSpan
  if (children.isEmpty) {
    return TextSpan(text: markdownText, style: baseStyle);
  }
  
  return TextSpan(children: children, style: baseStyle);
}

class _CanvasPainter extends CustomPainter {
  final List<Stroke> strokes;
  final List<TextElement> textElements;
  final bool isDark;
  final double fontSize;
  
  _CanvasPainter(this.strokes, this.textElements, this.isDark, this.fontSize);

  @override
  void paint(Canvas canvas, Size size) {
    // Determine colors based on theme
    // IMPORTANT: Verify theme detection is correct
    // brightness == Brightness.dark means dark theme → isDark = true
    // brightness == Brightness.light means light theme → isDark = false
    // 
    // Light mode (isDark=false): white background, black strokes (should be visible)
    // Dark mode (isDark=true): dark background, white strokes (should be visible)
    final canvasColor = isDark ? const Color(0xFF121212) : Colors.white;
    final textColor = isDark ? Colors.white : Colors.black;
    
    // Always draw canvas background first to ensure it's visible
    // Use a large rect to ensure full coverage even if size is wrong
    final backgroundPaint = Paint()
      ..color = canvasColor
      ..style = PaintingStyle.fill;
    // Draw background covering the entire canvas area
    final bgRect = size.width > 0 && size.height > 0 
        ? Rect.fromLTWH(0, 0, size.width, size.height)
        : const Rect.fromLTWH(0, 0, 20000, 20000);
    canvas.drawRect(bgRect, backgroundPaint);

    // Draw strokes - optimized for real-time drawing
    for (final stroke in strokes) {
      final points = stroke.points;
      final strokeColor = stroke.color;
      
      // Draw single point as a dot for immediate feedback
      if (points.length == 1) {
        final point = points.first;
        final dotPaint = Paint()
          ..color = strokeColor
          ..style = PaintingStyle.fill;
        // Use penSize as base, then apply pressure variation
        final baseRadius = stroke.penSize * 0.5;
        final radius = baseRadius + point.pressure * baseRadius;
        canvas.drawCircle(point.position, radius, dotPaint);
        continue;
      }
      
      if (points.length < 2) continue;
      
      final paint = Paint()
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      
      // Use quadratic curves for smoother lines with fewer points
      final path = Path()..moveTo(points.first.position.dx, points.first.position.dy);
      
      if (points.length == 2) {
        path.lineTo(points[1].position.dx, points[1].position.dy);
      } else {
        // Use quadratic bezier for smoother curves
        for (var i = 1; i < points.length; i++) {
          if (i == 1) {
            path.lineTo(points[i].position.dx, points[i].position.dy);
          } else {
            final prev = points[i - 1].position;
            final curr = points[i].position;
            final mid = Offset((prev.dx + curr.dx) / 2, (prev.dy + curr.dy) / 2);
            path.quadraticBezierTo(prev.dx, prev.dy, mid.dx, mid.dy);
          }
        }
        // Draw last segment
        if (points.length > 2) {
          path.lineTo(points.last.position.dx, points.last.position.dy);
        }
      }
      
      // Calculate average pressure more efficiently
      double totalPressure = 0;
      for (final p in points) {
        totalPressure += p.pressure;
      }
      // Use penSize as base multiplier, then apply pressure variation
      final baseWidth = stroke.penSize;
      paint.strokeWidth = baseWidth + (totalPressure / points.length) * (baseWidth * 2.0);
      canvas.drawPath(path, paint);
    }
    
    // Draw text elements - reuse TextPainter
    final textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );
    for (final textElement in textElements) {
      if (textElement.text.isEmpty) continue;
      // Convert markdown to styled TextSpan
      textPainter.text = _markdownToTextSpan(textElement.text, textColor, baseFontSize: fontSize);
      textPainter.layout();
      textPainter.paint(canvas, textElement.position);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    if (oldDelegate is! _CanvasPainter) return true;
    
    // Always repaint if theme changed - this is critical
    if (oldDelegate.isDark != isDark) return true;
    
    // Always repaint if stroke or text count changed
    if (oldDelegate.strokes.length != strokes.length) return true;
    if (oldDelegate.textElements.length != textElements.length) return true;
    
    // Check if any stroke was modified - check ALL strokes for point count changes
    // This is critical for real-time drawing
    final minLength = strokes.length < oldDelegate.strokes.length 
        ? strokes.length 
        : oldDelegate.strokes.length;
    
    // Check all strokes, especially the last one (current stroke being drawn)
    for (var i = 0; i < minLength; i++) {
      if (i >= oldDelegate.strokes.length || i >= strokes.length) return true;
      if (strokes[i].points.length != oldDelegate.strokes[i].points.length) {
        return true;
      }
    }
    
    // If we have more strokes than before, definitely repaint
    if (strokes.length > oldDelegate.strokes.length) return true;
    
    return false;
  }
}

class _MinimapWidget extends StatelessWidget {
  final Size size;
  final List<Stroke> strokes;
  final List<TextElement> textElements;
  final Rect contentBounds;
  final Rect viewportBounds;
  final bool isDark;
  final Function(Offset) onTap;
  
  const _MinimapWidget({
    required this.size,
    required this.strokes,
    required this.textElements,
    required this.contentBounds,
    required this.viewportBounds,
    required this.isDark,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    final scaleX = size.width / contentBounds.width;
    final scaleY = size.height / contentBounds.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    
    return GestureDetector(
      onTapDown: (details) {
        // Convert tap position to canvas coordinates
        final localPoint = details.localPosition;
        onTap(localPoint);
      },
      child: Container(
        width: size.width,
        height: size.height,
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.grey.shade200,
          border: Border.all(
            color: isDark ? Colors.grey.shade700 : Colors.grey.shade400,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CustomPaint(
            painter: _MinimapPainter(
              strokes: strokes,
              textElements: textElements,
              contentBounds: contentBounds,
              viewportBounds: viewportBounds,
              scale: scale,
              isDark: isDark,
              fontSize: 16.0, // Minimap uses fixed smaller font size
            ),
            size: size,
          ),
        ),
      ),
    );
  }
}

class _MinimapPainter extends CustomPainter {
  final List<Stroke> strokes;
  final List<TextElement> textElements;
  final Rect contentBounds;
  final Rect viewportBounds;
  final double scale;
  final bool isDark;
  final double fontSize;
  
  _MinimapPainter({
    required this.strokes,
    required this.textElements,
    required this.contentBounds,
    required this.viewportBounds,
    required this.scale,
    required this.isDark,
    required this.fontSize,
  });
  
  @override
  void paint(Canvas canvas, Size size) {
    // Draw background
    final backgroundPaint = Paint()
      ..color = isDark ? const Color(0xFF121212) : Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, backgroundPaint);
    
    // Calculate offset to center content in minimap
    final offsetX = -contentBounds.left * scale;
    final offsetY = -contentBounds.top * scale;
    final contentOffset = Offset(offsetX, offsetY);
    
    canvas.save();
    canvas.translate(contentOffset.dx, contentOffset.dy);
    canvas.scale(scale);
    
    // Draw strokes (simplified - just lines, no pressure)
    for (final stroke in strokes) {
      if (stroke.points.length < 2) continue;
      
      final paint = Paint()
        ..color = stroke.color.withOpacity(0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0 / scale; // Scale down stroke width
      
      final path = Path();
      path.moveTo(stroke.points.first.position.dx, stroke.points.first.position.dy);
      for (var i = 1; i < stroke.points.length; i++) {
        path.lineTo(stroke.points[i].position.dx, stroke.points[i].position.dy);
      }
      canvas.drawPath(path, paint);
    }
    
    // Draw text elements (simplified - just rectangles)
    final textColor = isDark ? Colors.white : Colors.black;
    final textPaint = Paint()
      ..color = textColor.withOpacity(0.4)
      ..style = PaintingStyle.fill;
    
    final textPainter = TextPainter(textDirection: TextDirection.ltr);
    for (final textElement in textElements) {
      if (textElement.text.isEmpty) continue;
      textPainter.text = _markdownToTextSpan(textElement.text, textColor, baseFontSize: fontSize);
      textPainter.layout();
      
      final textRect = Rect.fromLTWH(
        textElement.position.dx,
        textElement.position.dy,
        textPainter.width,
        textPainter.height,
      );
      canvas.drawRect(textRect, textPaint);
    }
    
    canvas.restore();
    
    // Draw viewport indicator
    final viewportPaint = Paint()
      ..color = Colors.blue.withOpacity(0.3)
      ..style = PaintingStyle.fill;
    final viewportBorderPaint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    
    // Calculate viewport rectangle in minimap coordinates
    // contentOffset already accounts for -contentBounds.left * scale
    // So we just need to add viewportBounds.left * scale to position it correctly
    final viewportRect = Rect.fromLTWH(
      viewportBounds.left * scale + contentOffset.dx,
      viewportBounds.top * scale + contentOffset.dy,
      viewportBounds.width * scale,
      viewportBounds.height * scale,
    );
    
    canvas.drawRect(viewportRect, viewportPaint);
    canvas.drawRect(viewportRect, viewportBorderPaint);
  }
  
  @override
  bool shouldRepaint(_MinimapPainter oldDelegate) {
    return oldDelegate.strokes.length != strokes.length ||
        oldDelegate.textElements.length != textElements.length ||
        oldDelegate.viewportBounds != viewportBounds ||
        oldDelegate.isDark != isDark;
  }
}

class SettingsPage extends StatefulWidget {
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  final VoidCallback? onDatabaseWiped;
  
  const SettingsPage({
    super.key,
    required this.onThemeModeChanged,
    this.onDatabaseWiped,
  });

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ThemeMode _currentThemeMode = ThemeMode.system;
  final SyncManager _syncManager = SyncManager();

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
    _syncManager.initialize();
  }
  
  Future<void> _showCloudSyncDialog(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (context) => CloudSyncDialog(
        syncManager: _syncManager,
        onSyncRequested: () => _performSync(context),
      ),
    );
    setState(() {}); // Refresh UI after dialog closes
  }
  
  Future<void> _performSync(BuildContext context) async {
    if (_syncManager.currentProvider == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please configure a sync provider first'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    if (!await _syncManager.currentProvider!.isConfigured()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sync provider not configured'),
            backgroundColor: Colors.orange,
          ),
        );
      }
      return;
    }

    // Show loading indicator
    if (context.mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const Center(
          child: Card(
            child: Padding(
              padding: EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text('Syncing...'),
                ],
              ),
            ),
          ),
        ),
      );
    }

    try {
      // Prepare local notes for sync (in export format)
      final allNotes = await DatabaseHelper.instance.getAllNotes(
        searchQuery: null,
        sortBy: 'id',
        filterTags: null,
      );
      
      final localNotesForSync = <Map<String, dynamic>>[];
      for (final note in allNotes) {
        final noteId = note['id'] as int;
        final exportedNote = await DatabaseHelper.instance.exportNote(noteId);
        final tags = await DatabaseHelper.instance.getNoteTags(noteId);
        exportedNote['note'] = {
          ...exportedNote['note'] as Map<String, dynamic>,
          'tags': tags,
        };
        localNotesForSync.add(exportedNote);
      }

      // Perform sync
      final result = await _syncManager.sync(
        localNotes: localNotesForSync,
        onNoteUpdated: (noteId, noteData) async {
          // Update existing note
          final note = noteData['note'] as Map<String, dynamic>?;
          final canvas = noteData['canvas'] as Map<String, dynamic>?;
          
          if (note == null || canvas == null) {
            return;
          }
          
          // Update note title if changed
          final titleValue = note['title'];
          if (titleValue != null) {
            await DatabaseHelper.instance.updateNoteTitle(noteId, titleValue.toString());
          }
          
          // Update tags
          final tags = (note['tags'] as List<dynamic>?)?.map((t) => t.toString()).toList() ?? [];
          await DatabaseHelper.instance.setNoteTags(noteId, tags);
          
          // Update canvas data
          final strokesData = canvas['strokes'] as List<dynamic>?;
          final strokes = strokesData != null
              ? strokesData.map<Stroke>((s) {
                  if (s is Map<String, dynamic>) {
                    return Stroke.fromJson(s);
                  } else if (s is String) {
                    return Stroke.fromJson(jsonDecode(s) as Map<String, dynamic>);
                  }
                  return Stroke.fromJson(s as Map<String, dynamic>);
                }).toList()
              : <Stroke>[];
          final textElementsData = canvas['text_elements'] as List<dynamic>?;
          final textElements = textElementsData != null
              ? textElementsData.map<TextElement>((te) {
                  if (te is Map<String, dynamic>) {
                    return TextElement.fromJson(te);
                  }
                  return TextElement.fromJson(te as Map<String, dynamic>);
                }).toList()
              : <TextElement>[];
          final matrixData = canvas['matrix'];
          Matrix4 matrix = Matrix4.identity();
          if (matrixData != null) {
            if (matrixData is List) {
              matrix = _parseMatrix(matrixData);
            } else if (matrixData is String) {
              final values = jsonDecode(matrixData) as List<dynamic>;
              matrix = _parseMatrix(values);
            }
          }
          final scale = (canvas['scale'] as num?)?.toDouble() ?? 1.0;
          
          final canvasData = NoteCanvasData(
            strokes: strokes,
            textElements: textElements,
            matrix: matrix,
            scale: scale,
          );
          
          await DatabaseHelper.instance.saveCanvasData(noteId, canvasData);
        },
        onNoteCreated: (noteData) async {
          // Create new note from remote using importNote
          await DatabaseHelper.instance.importNote(noteData);
        },
      );

      // Close loading dialog
      if (context.mounted) {
        Navigator.pop(context);
      }

      // Show results
      if (context.mounted) {
        String message = 'Sync completed: ';
        if (result.uploaded > 0) message += '${result.uploaded} uploaded, ';
        if (result.downloaded > 0) message += '${result.downloaded} downloaded';
        if (result.uploaded == 0 && result.downloaded == 0) {
          message = 'Sync completed: No changes';
        }
        if (result.hasConflicts) {
          message += '\n${result.conflicts} conflict(s) detected';
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            backgroundColor: result.hasError ? Colors.red : (result.hasConflicts ? Colors.orange : Colors.green),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  Matrix4 _parseMatrix(List<dynamic> data) {
    if (data.length != 16) return Matrix4.identity();
    return Matrix4.fromList(data.map((e) => e as double).toList());
  }

  Future<void> _loadThemeMode() async {
    final prefs = await SharedPreferences.getInstance();
    final themeModeString = prefs.getString('theme_mode') ?? 'system';
    setState(() {
      _currentThemeMode = ThemeMode.values.firstWhere(
        (mode) => mode.toString() == 'ThemeMode.$themeModeString',
        orElse: () => ThemeMode.system,
      );
    });
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    await widget.onThemeModeChanged(mode);
    setState(() {
      _currentThemeMode = mode;
    });
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(isDark ? Icons.dark_mode : Icons.light_mode),
            title: const Text('Theme'),
            subtitle: Text(_getThemeModeDescription(_currentThemeMode)),
            trailing: DropdownButton<ThemeMode>(
              value: _currentThemeMode,
              onChanged: (ThemeMode? newMode) {
                if (newMode != null) {
                  _setThemeMode(newMode);
                }
              },
              items: const [
                DropdownMenuItem(
                  value: ThemeMode.system,
                  child: Text('System'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.light,
                  child: Text('Light'),
                ),
                DropdownMenuItem(
                  value: ThemeMode.dark,
                  child: Text('Dark'),
                ),
              ],
            ),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Wipe Database', style: TextStyle(color: Colors.red)),
            subtitle: const Text('Delete all notes and data. This cannot be undone.'),
            onTap: () => _showWipeDatabaseDialog(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('Export Notes'),
            subtitle: const Text('Export all notes to JSON file'),
            onTap: () => _exportNotes(context),
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Import Notes'),
            subtitle: const Text('Import notes from JSON file'),
            onTap: () => _importNotes(context),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.cloud_sync),
            title: const Text('Cloud Sync'),
            subtitle: const Text('Configure sync provider and frequency'),
            onTap: () => _showCloudSyncDialog(context),
          ),
          const ListTile(
            leading: Icon(Icons.brush),
            title: Text('Drawing Settings'),
            subtitle: Text('Brush width, color, stylus behavior'),
          ),
          const ListTile(
            leading: Icon(Icons.crop_free),
            title: Text('Canvas Settings'),
            subtitle: Text('Infinite canvas options and transforms'),
          ),
        ],
      ),
    );
  }

  String _getThemeModeDescription(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Follow system theme';
      case ThemeMode.light:
        return 'Always light';
      case ThemeMode.dark:
        return 'Always dark';
    }
  }
  
  Future<void> _showWipeDatabaseDialog(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Wipe Database'),
        content: const Text(
          'This will permanently delete ALL notes, drawings, text, and tags. '
          'This action cannot be undone.\n\n'
          'Are you absolutely sure you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Wipe Database'),
          ),
        ],
      ),
    );
    
    if (confirmed == true && context.mounted) {
      try {
        await DatabaseHelper.instance.wipeDatabase();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Database wiped successfully'),
              duration: Duration(seconds: 2),
            ),
          );
          // Trigger reload callback if provided
          widget.onDatabaseWiped?.call();
          // Navigate back
          Navigator.pop(context);
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Failed to wipe database: $e'),
              backgroundColor: Colors.red,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    }
  }

  Future<void> _exportNotes(BuildContext context) async {
    try {
      final exportData = await DatabaseHelper.instance.exportAllNotes();
      final jsonString = const JsonEncoder.withIndent('  ').convert(exportData);
      
      // Get downloads directory or documents directory
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${directory.path}/feather_notes_export_$timestamp.json');
      
      await file.writeAsString(jsonString);
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Notes exported to: ${file.path}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _importNotes(BuildContext context) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result != null && result.files.single.path != null) {
        final file = File(result.files.single.path!);
        final jsonString = await file.readAsString();
        final importData = jsonDecode(jsonString) as Map<String, dynamic>;

        await DatabaseHelper.instance.importAllNotes(importData);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Notes imported successfully! Please restart the app.'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Import failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

