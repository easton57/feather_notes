# Feather Notes iOS App

This is the native Swift iOS implementation of Feather Notes, built using SwiftUI and SQLite.

## Features

- ✅ Infinite canvas with drawing support
- ✅ Text input on canvas
- ✅ Note management (create, edit, delete)
- ✅ Tags system with filtering
- ✅ Search functionality
- ✅ Sorting options (by title, date created, date modified, creation order)
- ✅ Dark mode support
- ✅ SQLite database for local storage
- ✅ Undo/Redo functionality
- ✅ Color picker for drawing
- ✅ Pan and zoom gestures
- ✅ Folder organization (basic support)

## Building

This project uses `xtool` for building iOS apps on Linux. To build:

```bash
cd ios/feather_notes
xtool build
```

Or if you have access to a Mac with Xcode:

```bash
cd ios/feather_notes
swift build
```

## Project Structure

- `Models.swift` - Data models (Point, Stroke, TextElement, NoteCanvasData, Note, Folder)
- `DatabaseHelper.swift` - SQLite database operations
- `NotesListView.swift` - Main note list interface with search, sort, and filter
- `CanvasView.swift` - Infinite canvas with drawing and text input
- `SettingsView.swift` - App settings (theme, data management)
- `feather_notesApp.swift` - Main app entry point
- `ContentView.swift` - Root view

## Database Schema

The app uses SQLite with the same schema as the Flutter version:
- `notes` - Note metadata
- `strokes` - Drawing strokes (JSON serialized)
- `text_elements` - Text elements on canvas
- `canvas_state` - Canvas transform matrix and scale
- `note_tags` - Many-to-many relationship for tags
- `folders` - Folder organization

## Compatibility

- iOS 17.0+
- macOS 14.0+ (via xtool)

## Notes

- The database file is stored in the app's documents directory
- The app shares the same database schema as the Flutter version, so data can be shared between platforms (with manual database file transfer)
- Cloud sync functionality is not yet implemented in the Swift version

