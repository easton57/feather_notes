import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math_64.dart' as vm;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
  final List<String> notes = [
    'New Note',
  ];

  int selectedIndex = 0;
  int? _editingIndex;
  final Map<int, TextEditingController> _noteControllers = {};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).canvasColor,
      appBar: AppBar(
        title: Text(selectedIndex < notes.length ? notes[selectedIndex] : 'Infinite Notes'),
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
      ),
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
            Expanded(
              child: ListView.builder(
                itemCount: notes.length,
                itemBuilder: (context, i) {
                  if (_editingIndex == i) {
                    if (!_noteControllers.containsKey(i)) {
                      _noteControllers[i] = TextEditingController(text: notes[i]);
                    }
                    return ListTile(
                      title: TextField(
                        controller: _noteControllers[i],
                        autofocus: true,
                        style: const TextStyle(fontSize: 16),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onSubmitted: (value) {
                          setState(() {
                            if (value.trim().isNotEmpty) {
                              notes[i] = value.trim();
                            }
                            _editingIndex = null;
                            _noteControllers[i]?.dispose();
                            _noteControllers.remove(i);
                          });
                        },
                        onEditingComplete: () {
                          setState(() {
                            final value = _noteControllers[i]?.text.trim() ?? '';
                            if (value.isNotEmpty) {
                              notes[i] = value;
                            }
                            _editingIndex = null;
                            _noteControllers[i]?.dispose();
                            _noteControllers.remove(i);
                          });
                        },
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.check),
                        onPressed: () {
                          setState(() {
                            final value = _noteControllers[i]?.text.trim() ?? '';
                            if (value.isNotEmpty) {
                              notes[i] = value;
                            }
                            _editingIndex = null;
                            _noteControllers[i]?.dispose();
                            _noteControllers.remove(i);
                          });
                        },
                      ),
                    );
                  }
                  return ListTile(
                    title: Text(notes[i]),
                    selected: i == selectedIndex,
                    onTap: () {
                      setState(() {
                        selectedIndex = i;
                      });
                      Navigator.pop(context);
                    },
                    onLongPress: () {
                      setState(() {
                        _editingIndex = i;
                      });
                    },
                    trailing: IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () {
                        setState(() {
                          _editingIndex = i;
                        });
                      },
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
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
      body: InfiniteCanvas(),
      floatingActionButton: FloatingActionButton(
        heroTag: "add_note_fab",
        child: const Icon(Icons.add),
        onPressed: () {
          setState(() {
            notes.add('Note ${notes.length + 1}');
            selectedIndex = notes.length - 1;
          });
        },
      ),
    );
  }
  
  @override
  void dispose() {
    for (final controller in _noteControllers.values) {
      controller.dispose();
    }
    _noteControllers.clear();
    super.dispose();
  }
}

class InfiniteCanvas extends StatefulWidget {
  @override
  State<InfiniteCanvas> createState() => _InfiniteCanvasState();
}

class _InfiniteCanvasState extends State<InfiniteCanvas> {
  Matrix4 _matrix = Matrix4.identity();
  double _scale = 1.0;

  final List<Stroke> _strokes = [];
  Stroke? _currentStroke;
  final List<CanvasState> _undoStack = [];
  final List<CanvasState> _redoStack = [];
  bool _eraserMode = false;
  
  // Text mode
  bool _textMode = false;
  final List<TextElement> _textElements = [];
  TextElement? _activeTextElement;
  final FocusNode _textFocusNode = FocusNode();
  final TextEditingController _textController = TextEditingController();

  Offset _lastFocalPoint = Offset.zero;
  int _pointerCount = 0;
  
  // Store theme brightness to ensure it's always current
  Brightness? _lastBrightness;
  
  Offset _transformToScreen(Offset localPoint) {
    final v = vm.Vector4(localPoint.dx, localPoint.dy, 0, 1);
    final r = _matrix.transform(v);
    return Offset(r.x, r.y);
  }

  @override
  Widget build(BuildContext context) {
    // Get theme brightness directly from context and track changes
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    
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
                });
              }
            },
            onScaleEnd: (_) => _scale = 1.0,
            child: Transform(
              transform: _matrix,
              child: CustomPaint(
                // Key includes current stroke point count to force repaint during drawing
                key: ValueKey('canvas_${isDark}_${_strokes.length}_${_textElements.length}_${_currentStroke?.points.length ?? 0}'),
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
              
              if (isStylus || (isMouse && !_textMode)) {
                final local = _transformToLocal(event.localPosition);
                setState(() {
                  if (_eraserMode) {
                    _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
                    _strokes.removeWhere((s) => s.hitTest(local));
                    _redoStack.clear();
                  } else {
                    final pressure = isStylus ? event.pressure : 0.5;
                    _currentStroke = Stroke([Point(local, pressure)]);
                    _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
                    _strokes.add(_currentStroke!);
                    _redoStack.clear();
                  }
                });
              } else if (isMouse && _textMode) {
                // Click to place text cursor
                final local = _transformToLocal(event.localPosition);
                setState(() {
                  _activeTextElement = TextElement(local, '');
                  _textController.clear();
                  // Request focus after a small delay to ensure the widget is built
                  Future.delayed(const Duration(milliseconds: 50), () {
                    if (mounted) {
                      _textFocusNode.requestFocus();
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
                  });
                }
              }
            },
            onPointerUp: (event) {
              if (_activeTextElement == null) {
                // Always update on pointer up to ensure final point is drawn
                setState(() => _currentStroke = null);
              }
            },
            behavior: HitTestBehavior.opaque,
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text('Infinite Canvas', style: TextStyle(fontSize: 12)),
                  SizedBox(height: 4),
                  Text('Mouse/stylus to draw, two-finger to pan/zoom', style: TextStyle(fontSize: 10)),
                  SizedBox(height: 2),
                  Text('Click in text mode to add text', style: TextStyle(fontSize: 10)),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          top: 16,
          right: 16,
          child: Column(
            children: [
              FloatingActionButton(
                heroTag: "undo_fab",
                mini: true,
                tooltip: 'Undo',
                child: const Icon(Icons.undo),
                onPressed: undo,
              ),
              const SizedBox(height: 8),
              FloatingActionButton(
                heroTag: "redo_fab",
                mini: true,
                tooltip: 'Redo',
                child: const Icon(Icons.redo),
                onPressed: redo,
              ),
              const SizedBox(height: 8),
              FloatingActionButton(
                heroTag: "eraser_fab",
                mini: true,
                tooltip: 'Eraser',
                child: Icon(_eraserMode ? Icons.brush : Icons.cleaning_services),
                onPressed: () => setState(() => _eraserMode = !_eraserMode),
              ),
              const SizedBox(height: 8),
              FloatingActionButton(
                heroTag: "text_mode_fab",
                mini: true,
                tooltip: _textMode ? 'Drawing Mode' : 'Text Mode',
                child: Icon(_textMode ? Icons.brush : Icons.text_fields),
                onPressed: () => setState(() {
                  _textMode = !_textMode;
                  if (!_textMode) {
                    _textFocusNode.unfocus();
                    _activeTextElement = null;
                  }
                }),
              ),
            ],
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
                    _textElements.add(TextElement(_activeTextElement!.position, _textController.text));
                    _redoStack.clear();
                  }
                  _activeTextElement = null;
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
                      child: TextField(
                        controller: _textController,
                        focusNode: _textFocusNode,
                        autofocus: true,
                        keyboardType: TextInputType.text,
                        textInputAction: TextInputAction.done,
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: 'Type here...',
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
                        onSubmitted: (value) {
                          setState(() {
                            if (value.isNotEmpty && _activeTextElement != null) {
                              _undoStack.add(CanvasState(List.from(_strokes), List.from(_textElements)));
                              _textElements.add(TextElement(_activeTextElement!.position, value));
                              _redoStack.clear();
                            }
                            _activeTextElement = null;
                            _textController.clear();
                            _textFocusNode.unfocus();
                          });
                        },
                      ),
                    ),
                  );
                },
              ),
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
      });
    }
  }
}

class CanvasState {
  final List<Stroke> strokes;
  final List<TextElement> textElements;
  CanvasState(this.strokes, this.textElements);
}

class Point {
  final Offset position;
  final double pressure;
  Point(this.position, this.pressure);
}

class Stroke {
  final List<Point> points;
  Stroke(this.points);

  bool hitTest(Offset pos) {
    for (final p in points) {
      if ((p.position - pos).distance < 12) return true;
    }
    return false;
  }
}

class TextElement {
  final Offset position;
  final String text;
  TextElement(this.position, this.text);
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
    final strokeColor = isDark ? Colors.white : Colors.black;
    final textColor = isDark ? Colors.white : Colors.black;
    
    // Debug: Uncomment to see what values we're getting
    // print('Painter: isDark=$isDark, canvasColor=$canvasColor, strokeColor=$strokeColor, strokes=${strokes.length}');
    
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
    
    final paint = Paint()
      ..color = strokeColor
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Draw strokes - optimized for real-time drawing
    for (final stroke in strokes) {
      final points = stroke.points;
      
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
      textPainter.text = TextSpan(
        text: textElement.text,
        style: TextStyle(color: textColor, fontSize: 16),
      );
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

class SettingsPage extends StatefulWidget {
  final Future<void> Function(ThemeMode) onThemeModeChanged;
  
  const SettingsPage({super.key, required this.onThemeModeChanged});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ThemeMode _currentThemeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
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
          const ListTile(
            leading: Icon(Icons.cloud_sync),
            title: Text('Cloud Sync'),
            subtitle: Text('Configure sync provider and frequency'),
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
}
