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
  final List<Map<String, dynamic>> notes = []; // {id, title, tags}
  int selectedIndex = 0;
  int? _editingIndex;
  final Map<int, TextEditingController> _noteControllers = {};
  final Map<int, NoteCanvasData> _noteCanvasData = {};
  bool _isLoading = true;
  bool _isCreatingDefaultNote = false; // Flag to prevent recursion
  
  // Search and filter state
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  String _sortBy = 'id'; // 'id', 'title', 'date_created', 'date_modified'
  List<String> _selectedTags = [];
  List<String> _availableTags = [];

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  Future<void> _loadNotes() async {
    try {
      // Load available tags
      final tags = await DatabaseHelper.instance.getAllTags();
      
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
        loadedNotes.add({
          'id': noteId,
          'title': n['title'] as String,
          'tags': noteTags,
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
            strokes: data.strokes.map((s) => Stroke(List.from(s.points), color: s.color)).toList(),
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
        _noteCanvasData.clear();
        _noteCanvasData.addAll(loadedCanvasData);
        _availableTags = tags;
        selectedIndex = 0;
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
          strokes: data.strokes.map((s) => Stroke(List.from(s.points), color: s.color)).toList(),
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
      strokes: data.strokes.map((s) => Stroke(List.from(s.points), color: s.color)).toList(),
      textElements: data.textElements.map((te) => TextElement(te.position, te.text)).toList(),
      matrix: Matrix4.copy(data.matrix),
      scale: data.scale,
    );
    _noteCanvasData[noteId] = dataCopy;
    await DatabaseHelper.instance.saveCanvasData(noteId, dataCopy);
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
    final scaffoldKey = GlobalKey<ScaffoldState>();
    
    return Scaffold(
      key: scaffoldKey,
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
              child: ListView.builder(
                itemCount: notes.length,
                itemBuilder: (context, i) {
                  final noteId = notes[i]['id'] as int;
                  final noteTags = notes[i]['tags'] as List<String>? ?? [];
                  if (_editingIndex == i) {
                    if (!_noteControllers.containsKey(noteId)) {
                      _noteControllers[noteId] = TextEditingController(text: notes[i]['title'] as String);
                    }
                    return ListTile(
                      title: TextField(
                        controller: _noteControllers[noteId],
                        autofocus: true,
                        style: const TextStyle(fontSize: 16),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onSubmitted: (value) async {
                          if (value.trim().isNotEmpty) {
                            await DatabaseHelper.instance.updateNoteTitle(noteId, value.trim());
                            setState(() {
                              notes[i]['title'] = value.trim();
                              _editingIndex = null;
                              _noteControllers[noteId]?.dispose();
                              _noteControllers.remove(noteId);
                            });
                          } else {
                            setState(() {
                              _editingIndex = null;
                              _noteControllers[noteId]?.dispose();
                              _noteControllers.remove(noteId);
                            });
                          }
                        },
                        onEditingComplete: () async {
                          final value = _noteControllers[noteId]?.text.trim() ?? '';
                          if (value.isNotEmpty) {
                            await DatabaseHelper.instance.updateNoteTitle(noteId, value);
                            setState(() {
                              notes[i]['title'] = value;
                              _editingIndex = null;
                              _noteControllers[noteId]?.dispose();
                              _noteControllers.remove(noteId);
                            });
                          } else {
                            setState(() {
                              _editingIndex = null;
                              _noteControllers[noteId]?.dispose();
                              _noteControllers.remove(noteId);
                            });
                          }
                        },
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.check),
                        onPressed: () async {
                          final value = _noteControllers[noteId]?.text.trim() ?? '';
                          if (value.isNotEmpty) {
                            await DatabaseHelper.instance.updateNoteTitle(noteId, value);
                            setState(() {
                              notes[i]['title'] = value;
                              _editingIndex = null;
                              _noteControllers[noteId]?.dispose();
                              _noteControllers.remove(noteId);
                            });
                          } else {
                            setState(() {
                              _editingIndex = null;
                              _noteControllers[noteId]?.dispose();
                              _noteControllers.remove(noteId);
                            });
                          }
                        },
                      ),
                    );
                  }
                  return ListTile(
                    title: Text(notes[i]['title'] as String),
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
                      setState(() {
                        _editingIndex = i;
                      });
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
                          icon: const Icon(Icons.edit, size: 20),
                          onPressed: () {
                            setState(() {
                              _editingIndex = i;
                            });
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
                },
              ),
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
                      ? InfiniteCanvas(
                          key: ValueKey('canvas_${notes[selectedIndex]['id']}'),
                          noteId: notes[selectedIndex]['id'] as int,
                          initialData: _noteCanvasData[notes[selectedIndex]['id'] as int] ?? NoteCanvasData(),
                          onDataChanged: (data) async {
                            if (selectedIndex >= 0 && selectedIndex < notes.length) {
                              final noteId = notes[selectedIndex]['id'] as int;
                              await _saveNoteData(noteId, data);
                            }
                          },
                        )
                      : const Center(child: Text('No note selected')))),
          // Floating buttons and title
          Positioned(
            top: 16,
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
                    onPressed: () => scaffoldKey.currentState?.openDrawer(),
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
                // Note title with transparent background
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    _isLoading 
                        ? 'Loading...' 
                        : (selectedIndex < notes.length ? notes[selectedIndex]['title'] as String : 'Infinite Notes'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: Theme.of(context).textTheme.titleMedium?.color,
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
  
  // Text mode
  bool _textMode = false;
  TextElement? _activeTextElement;
  int? _editingTextElementIndex; // Index of text element being edited, null if creating new
  final FocusNode _textFocusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();

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
  
  @override
  void initState() {
    super.initState();
    _loadCanvasData();
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
      // Use a deep comparison to detect actual changes
      if (!_dataEquals(oldWidget.initialData, widget.initialData)) {
        _loadCanvasData();
      }
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
    // Create a deep copy to ensure we're not sharing references
    final data = widget.initialData ?? NoteCanvasData();
    print('[_loadCanvasData] Loading canvas data, initial matrix: ${data.matrix.getTranslation()}, scale: ${data.scale}');
    setState(() {
      // Validate and fix matrix if corrupted
      Matrix4 matrix = Matrix4.copy(data.matrix);
      final determinant = matrix.determinant();
      print('[_loadCanvasData] Matrix determinant: $determinant');
      if (!determinant.isFinite || determinant == 0 || determinant.isNaN) {
        // Matrix is corrupted, reset to identity
        print('[_loadCanvasData] Matrix corrupted, resetting to identity');
        matrix = Matrix4.identity();
      }
      _matrix = matrix;
      
      // Validate scale
      double scale = data.scale;
      if (!scale.isFinite || scale <= 0 || scale.isNaN) {
        print('[_loadCanvasData] Scale invalid, resetting to 1.0');
        scale = 1.0;
      }
      _scale = scale;
      
      print('[_loadCanvasData] Final matrix: ${_matrix.getTranslation()}, scale: $_scale');
      
      // Create new lists to avoid reference sharing
      _strokes = data.strokes.map((s) => Stroke(List.from(s.points), color: s.color)).toList();
      _textElements = data.textElements.map((te) => TextElement(te.position, te.text)).toList();
      _currentStroke = null;
      _undoStack.clear();
      _redoStack.clear();
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
    print('[_saveCurrentData] Saving canvas data, matrix: ${_matrix.getTranslation()}, scale: $_scale');
    widget.onDataChanged(NoteCanvasData(
      strokes: _strokes,
      textElements: _textElements,
      matrix: _matrix,
      scale: _scale,
    ));
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
      textPainter.text = _markdownToTextSpan(textElement.text, textColor, baseFontSize: 16);
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
    // Transform screen corners to canvas coordinates
    final topLeft = _transformToLocal(Offset.zero);
    final topRight = _transformToLocal(Offset(screenSize.width, 0));
    final bottomLeft = _transformToLocal(Offset(0, screenSize.height));
    final bottomRight = _transformToLocal(Offset(screenSize.width, screenSize.height));
    
    final minX = [topLeft.dx, topRight.dx, bottomLeft.dx, bottomRight.dx].reduce((a, b) => a < b ? a : b);
    final minY = [topLeft.dy, topRight.dy, bottomLeft.dy, bottomRight.dy].reduce((a, b) => a < b ? a : b);
    final maxX = [topLeft.dx, topRight.dx, bottomLeft.dx, bottomRight.dx].reduce((a, b) => a > b ? a : b);
    final maxY = [topLeft.dy, topRight.dy, bottomLeft.dy, bottomRight.dy].reduce((a, b) => a > b ? a : b);
    
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
          onPointerDown: (e) => setState(() => _pointerCount++),
          onPointerUp: (e) => setState(() => _pointerCount = (_pointerCount - 1).clamp(0, 10)),
          onPointerSignal: (event) {
            // Handle mouse wheel scrolling
            print('[onPointerSignal] kind: ${event.kind}');
            // Check if it's a scroll event by checking the kind
            if (event.kind == ui.PointerDeviceKind.mouse) {
              // Try to access scrollDelta if available
              try {
                final scrollDelta = (event as dynamic).scrollDelta as Offset?;
                print('[onPointerSignal] scrollDelta: $scrollDelta');
                if (scrollDelta != null) {
                  print('[onPointerSignal] Scrolling: matrix before: ${_matrix.getTranslation()}');
                  setState(() {
                    _matrix = _matrix..translateByDouble(-scrollDelta.dx, -scrollDelta.dy, 0, 0);
                    print('[onPointerSignal] Scrolling: matrix after: ${_matrix.getTranslation()}');
                    _saveCurrentData();
                  });
                }
              } catch (e) {
                print('[onPointerSignal] Error accessing scrollDelta: $e');
                // If scrollDelta is not available, ignore
              }
            }
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (details) => _lastFocalPoint = details.focalPoint,
                  onScaleUpdate: (details) {
              if (details.pointerCount >= 2) {
                setState(() {
                  final dx = details.focalPoint.dx - _lastFocalPoint.dx;
                  final dy = details.focalPoint.dy - _lastFocalPoint.dy;
                  _matrix = _matrix..translateByDouble(dx, dy, 0, 0);

                  final newScale = details.scale;
                  final scaleFactor = newScale / _scale;
                  _scale = newScale;

                  final focal = _transformToLocal(details.focalPoint);
                  _matrix = _matrix..translateByDouble(focal.dx, focal.dy, 0, 0)..scaleByDouble(scaleFactor, scaleFactor, scaleFactor, 1)..translateByDouble(-focal.dx, -focal.dy, 0, 0);

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
                ),
                child: SizedBox(width: 20000, height: 20000),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Listener(
            onPointerDown: (event) {
              // Don't intercept if text field is active
              if (_activeTextElement != null) return;
              
              final isStylus = event.kind == ui.PointerDeviceKind.stylus || event.kind == ui.PointerDeviceKind.invertedStylus;
              final isMouse = event.kind == ui.PointerDeviceKind.mouse;
              final isTouch = event.kind == ui.PointerDeviceKind.touch;
              
              print('[onPointerDown] kind: ${event.kind}, buttons: ${event.buttons}, position: ${event.localPosition}');
              print('[onPointerDown] isMouse: $isMouse, isTouch: $isTouch, _pointerCount: $_pointerCount, _textMode: $_textMode, _currentStroke: ${_currentStroke != null}');
              
              // Check for right-click panning FIRST (before drawing)
              // Note: buttons might not be set on onPointerDown, so we'll also check in onPointerMove
              // But we can prevent stroke creation here if buttons is available
              if (isMouse && event.buttons == 2) {
                // Right-click panning - prevent drawing
                print('[onPointerDown] Right-click detected (buttons=2), starting panning');
                setState(() {
                  _isPanning = true;
                  _panStartPosition = event.localPosition;
                  _lastPanPosition = event.localPosition; // Initialize last position
                  // Cancel any active stroke
                  if (_currentStroke != null) {
                    print('[onPointerDown] Cancelling active stroke for panning');
                    // Remove the stroke from strokes list if it was just added
                    if (_strokes.isNotEmpty && _strokes.last == _currentStroke) {
                      _strokes.removeLast();
                    }
                    _currentStroke = null;
                  }
                });
                return;
              }
              
              // For touch, check for single-finger panning (only if not in text mode and no stroke active)
              if (isTouch && _pointerCount == 1 && !_textMode && _currentStroke == null) {
                // Single-finger touch panning
                print('[onPointerDown] Starting touch panning');
                setState(() {
                  _isPanning = true;
                  _panStartPosition = event.localPosition;
                  _lastPanPosition = event.localPosition; // Initialize last position
                });
                return;
              }
              
              // Don't start drawing if we're panning
              if (_isPanning) {
                print('[onPointerDown] Skipping drawing because panning is active');
                return;
              }
              
              if (isStylus || (isMouse && !_textMode)) {
                // Double-check we're not panning (buttons might not have been set on down)
                if (isMouse && event.buttons == 2) {
                  print('[onPointerDown] Right-click detected during drawing check, starting panning instead');
                  setState(() {
                    _isPanning = true;
                    _panStartPosition = event.localPosition;
                    _lastPanPosition = event.localPosition; // Initialize last position
                    _currentStroke = null;
                  });
                  return;
                }
                
                final local = _transformToLocal(event.localPosition);
                setState(() {
                  if (_eraserMode) {
                    _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
                    _strokes.removeWhere((s) => s.hitTest(local));
                    _redoStack.clear();
                    _saveCurrentData();
                  } else {
                    final pressure = isStylus ? event.pressure : 0.5;
                    _currentStroke = Stroke([Point(local, pressure)], color: _eraserMode ? (isDark ? const Color(0xFF121212) : Colors.white) : _selectedColor);
                    _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
                    _strokes.add(_currentStroke!);
                    _redoStack.clear();
                    _saveCurrentData();
                  }
                });
              } else if (isMouse && _textMode) {
                // Click to place text cursor or edit existing text
                final local = _transformToLocal(event.localPosition);
                
                // Check if clicking on an existing text element
                int? clickedTextIndex;
                // Get text color from theme
                final brightness = Theme.of(context).brightness;
                final isDark = brightness == Brightness.dark;
                final textColor = isDark ? Colors.white : Colors.black;
                for (int i = _textElements.length - 1; i >= 0; i--) {
                  if (_textElements[i].hitTest(local, textColor: textColor)) {
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
                  // Request focus after a small delay to ensure the widget is built
                  Future.delayed(const Duration(milliseconds: 50), () {
                    if (mounted) {
                      _textFocusNode.requestFocus();
                      // Move cursor to end of text when editing
                      if (_editingTextElementIndex != null) {
                        _textController.selection = TextSelection.fromPosition(
                          TextPosition(offset: _textController.text.length),
                        );
                      }
                    }
                  });
                });
              }
            },
            onPointerMove: (event) {
              // Don't intercept if text field is active
              if (_activeTextElement != null) return;
              
              final isStylus = event.kind == ui.PointerDeviceKind.stylus || event.kind == ui.PointerDeviceKind.invertedStylus;
              final isMouse = event.kind == ui.PointerDeviceKind.mouse;
              final isTouch = event.kind == ui.PointerDeviceKind.touch;
              
              print('[onPointerMove] kind: ${event.kind}, buttons: ${event.buttons}, position: ${event.localPosition}');
              print('[onPointerMove] isMouse: $isMouse, _isPanning: $_isPanning, _currentStroke: ${_currentStroke != null}');
              
              // Check for right-click panning (buttons == 2 means right mouse button)
              if (isMouse && event.buttons == 2 && !_isPanning) {
                // Start right-click panning
                print('[onPointerMove] Starting right-click panning');
                setState(() {
                  _isPanning = true;
                  _panStartPosition = event.localPosition;
                  _lastPanPosition = event.localPosition; // Initialize last position
                  // Cancel any active stroke that might have been created
                  if (_currentStroke != null) {
                    print('[onPointerMove] Cancelling active stroke for panning');
                    // Remove the stroke from strokes list if it was just added
                    if (_strokes.isNotEmpty && _strokes.last == _currentStroke) {
                      _strokes.removeLast();
                    }
                    _currentStroke = null;
                  }
                });
                // Don't return - continue to panning handling below so first move is processed
              }
              
              // Handle panning (single finger touch or right-click mouse)
              // Use the same approach as two-finger panning: calculate delta from previous position
              if (_isPanning && _lastPanPosition != null) {
                // Calculate delta from the previous position (like two-finger panning does)
                final dx = event.localPosition.dx - _lastPanPosition!.dx;
                final dy = event.localPosition.dy - _lastPanPosition!.dy;
                final translationBefore = _matrix.getTranslation();
                print('[onPointerMove] Panning: delta=($dx, $dy), matrix translation before: $translationBefore');
                
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
                    print('[onPointerMove] Panning: matrix translation after: $translationAfter');
                    // Don't save on every move to avoid performance issues
                    // Save will happen on pointer up
                  });
                } else {
                  print('[onPointerMove] Invalid delta detected: ($dx, $dy), skipping panning');
                }
                return;
              }
              
              // If we were panning but buttons changed, stop panning
              if (_isPanning && isMouse && event.buttons != 2) {
                print('[onPointerMove] Stopping panning (buttons changed to ${event.buttons})');
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
              
              if (_currentStroke != null && (isStylus || (isMouse && !_textMode))) {
                final local = _transformToLocal(event.localPosition);
                final pressure = isStylus ? event.pressure : 0.5;
                // Add point and immediately trigger repaint for real-time drawing
                _currentStroke!.points.add(Point(local, pressure));
                
                // Call setState immediately for real-time drawing
                // Use a microtask to batch rapid updates slightly without visible delay
                if (mounted) {
                  setState(() {
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
              print('[onPointerUp] kind: ${event.kind}, buttons: ${event.buttons}, _isPanning: $_isPanning');
              
              // End panning if active
              if (_isPanning) {
                print('[onPointerUp] Ending panning');
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
                  _saveCurrentData();
                });
              }
            },
            behavior: HitTestBehavior.opaque,
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: Column(
            children: [
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
                color: Colors.grey[700],
                child: IconButton(
                  icon: Icon(_eraserMode ? Icons.brush : Icons.cleaning_services),
                  tooltip: 'Eraser',
                  onPressed: () => setState(() => _eraserMode = !_eraserMode),
                ),
              ),
              const SizedBox(height: 8),
              Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey[700],
                child: IconButton(
                  icon: Icon(_textMode ? Icons.brush : Icons.text_fields),
                  tooltip: _textMode ? 'Drawing Mode' : 'Text Mode',
                  onPressed: () => setState(() {
                    _textMode = !_textMode;
                    if (!_textMode) {
                      _textFocusNode.unfocus();
                      _activeTextElement = null;
                      _editingTextElementIndex = null;
                      _textController.clear();
                    }
                  }),
                ),
              ),
              const SizedBox(height: 8),
              Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                color: Colors.grey[700],
                child: IconButton(
                  icon: Icon(Icons.palette),
                  tooltip: 'Color Picker',
                  onPressed: () => setState(() => _showColorPicker = !_showColorPicker),
                ),
              ),
            ],
          ),
        ),
        // Color picker overlay
        if (_showColorPicker)
          Positioned(
            top: 16,
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
                  children: [
                    BlockPicker(
                      pickerColor: _selectedColor,
                      onColorChanged: (color) {
                        setState(() {
                          _selectedColor = color;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () => setState(() => _showColorPicker = false),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        // Text input overlay - placed last so it's on top
        if (_activeTextElement != null)
          Positioned.fill(
            child: GestureDetector(
                onTap: () {
                  // Click outside to dismiss
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
                    _textFocusNode.unfocus();
                  });
                },
              child: Container(color: Colors.transparent),
            ),
          ),
        if (_activeTextElement != null)
          Positioned(
            left: _transformToScreen(_activeTextElement!.position).dx.clamp(0.0, double.infinity),
            top: _transformToScreen(_activeTextElement!.position).dy.clamp(0.0, double.infinity),
            child: GestureDetector(
              onTap: () {}, // Prevent tap from propagating
              child: Builder(
                builder: (context) {
                  final brightness = Theme.of(context).brightness;
                  final isDark = brightness == Brightness.dark;
                  return Material(
                    elevation: 4,
                    borderRadius: BorderRadius.circular(4),
                    color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 200, maxWidth: 400),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                        border: Border.all(
                          color: isDark ? Colors.blue.shade300 : Colors.blue,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      child: Shortcuts(
                        shortcuts: {
                          // Enter key submits (without Shift)
                          const SingleActivator(LogicalKeyboardKey.enter): const _SubmitTextIntent(),
                        },
                        child: Actions(
                          actions: {
                            _SubmitTextIntent: CallbackAction<_SubmitTextIntent>(
                              onInvoke: (intent) {
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
                                  _textFocusNode.unfocus();
                                });
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
                              fontSize: 16,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                            decoration: InputDecoration(
                              border: InputBorder.none,
                              hintText: 'Type here... (Shift+Enter for new line)',
                              hintStyle: TextStyle(
                                color: isDark ? Colors.white70 : Colors.black54,
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
                    ),
                  );
                },
              ),
            ),
          ),
        // Minimap
        if (_showMinimap)
          Positioned(
            bottom: 16,
            right: 16,
            child: _MinimapWidget(
              strokes: _strokes,
              textElements: _textElements,
              contentBounds: _calculateContentBounds(),
              viewportBounds: _calculateViewportBounds(MediaQuery.of(context).size),
              isDark: isDark,
              onTap: (localPoint) {
                // Pan to the clicked location on the minimap
                final contentBounds = _calculateContentBounds();
                final minimapSize = const Size(200, 200);
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
                final screenSize = MediaQuery.of(context).size;
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
  Stroke(this.points, {Color? color}) : color = color ?? Colors.black;

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
    return Stroke(points, color: color);
  }
}

class TextElement {
  final Offset position;
  final String text;
  TextElement(this.position, this.text);

  /// Check if a point is within the bounds of this text element
  bool hitTest(Offset point, {double fontSize = 16.0, Color textColor = Colors.black}) {
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
  
  _CanvasPainter(this.strokes, this.textElements, this.isDark);

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
        final radius = 1.0 + point.pressure * 2.0;
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
      paint.strokeWidth = 1.0 + (totalPressure / points.length) * 3.0;
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
      textPainter.text = _markdownToTextSpan(textElement.text, textColor, baseFontSize: 16);
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
  final List<Stroke> strokes;
  final List<TextElement> textElements;
  final Rect contentBounds;
  final Rect viewportBounds;
  final bool isDark;
  final Function(Offset) onTap;
  
  const _MinimapWidget({
    required this.strokes,
    required this.textElements,
    required this.contentBounds,
    required this.viewportBounds,
    required this.isDark,
    required this.onTap,
  });
  
  @override
  Widget build(BuildContext context) {
    const minimapSize = Size(200, 200);
    final scaleX = minimapSize.width / contentBounds.width;
    final scaleY = minimapSize.height / contentBounds.height;
    final scale = scaleX < scaleY ? scaleX : scaleY;
    
    return GestureDetector(
      onTapDown: (details) {
        // Convert tap position to canvas coordinates
        final localPoint = details.localPosition;
        onTap(localPoint);
      },
      child: Container(
        width: minimapSize.width,
        height: minimapSize.height,
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
            ),
            size: minimapSize,
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
  
  _MinimapPainter({
    required this.strokes,
    required this.textElements,
    required this.contentBounds,
    required this.viewportBounds,
    required this.scale,
    required this.isDark,
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
      textPainter.text = _markdownToTextSpan(textElement.text, textColor, baseFontSize: 16);
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
    
    final viewportRect = Rect.fromLTWH(
      (viewportBounds.left - contentBounds.left) * scale + contentOffset.dx,
      (viewportBounds.top - contentBounds.top) * scale + contentOffset.dy,
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
            print('Sync: Error: Note data missing note or canvas: $noteData');
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
