# Statement of Work (SOW)
## Feather Notes - Feature Development

**Project:** Feather Notes - Cross-Platform Note-Taking Application  
**Date:** 2024  
**Version:** 1.3  
**Last Updated:** November 2025

---

## Executive Summary

This Statement of Work outlines the development of key features for Feather Notes, a cross-platform note-taking application with infinite canvas capabilities, drawing, and text input. The features are prioritized to enhance user experience, data persistence, and platform integration.

---

## 1. Dark Mode Support

### 1.1 Overview
Implement a comprehensive dark mode theme that adapts to system preferences and provides manual toggle capability.

### 1.2 Requirements
- **System Theme Detection**: Automatically detect and follow system dark/light mode preferences
- **Manual Toggle**: Provide user-controlled theme switching in settings
- **Theme Persistence**: Save user's theme preference locally
- **Complete UI Coverage**: All UI elements must support both themes:
  - AppBar, Drawer, FloatingActionButtons
  - Canvas background
  - Text elements (with appropriate contrast)
  - Drawing strokes (adjustable colors)
  - Settings page
  - Dialogs and overlays

### 1.3 Technical Implementation
- Use Flutter's `ThemeData` with `ColorScheme.fromSeed()` for both light and dark variants
- Implement `ThemeMode` (light, dark, system)
- Store preference using local storage (see NoSQL section)
- Ensure WCAG AA contrast ratios for accessibility
- Test on all supported platforms (Android, iOS, Linux, Windows, macOS, Web)

### 1.4 Deliverables
- Dark mode theme implementation
- Settings UI for theme selection
- Theme persistence
- Documentation for theme customization

### 1.5 Estimated Effort
**Development:** 8-12 hours  
**Testing:** 4-6 hours  
**Total:** 12-18 hours

---

## 2. SQLite Local Storage ✅ **COMPLETED**

### 2.1 Overview
✅ Implemented SQLite database for persistent storage of notes, drawings, and application state.

### 2.2 Requirements ✅ **ALL COMPLETED**
- ✅ **Data Model**: Stores complete note data including:
  - ✅ Note metadata (title, creation date, modification date)
  - ✅ Stroke data (points, pressure) - stored as JSON
  - ✅ Text elements (position, content) - stored in separate table
  - ✅ Canvas state (transform matrix, zoom level) - stored in canvas_state table
  - ✅ Foreign key constraints for data integrity
  
- ✅ **Database Selection**: SQLite (sqflite package)
  - ✅ Cross-platform support (mobile and desktop)
  - ✅ sqflite_common_ffi for desktop platforms (Linux, Windows, macOS)
  - ✅ Proper initialization in main() for desktop platforms
  
- ✅ **Performance Requirements**:
  - ✅ Notes load on app startup
  - ✅ Auto-save on canvas changes (drawing, text, pan/zoom)
  - ✅ Efficient batch operations for saving canvas data
  - ✅ Indexed tables for fast queries

### 2.3 Technical Implementation ✅ **COMPLETED**
- ✅ SQLite database with sqflite package
- ✅ Data models with JSON serialization for strokes
- ✅ DatabaseHelper singleton pattern for data access
- ✅ Schema with proper foreign key constraints
- ✅ Auto-save on canvas changes (drawing, text, pan/zoom, undo/redo)
- ✅ Export/import functionality via JSON

### 2.4 Data Schema ✅ **IMPLEMENTED**
```sql
-- Notes table
CREATE TABLE notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  modified_at INTEGER NOT NULL
)

-- Strokes table (JSON serialized)
CREATE TABLE strokes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id INTEGER NOT NULL,
  stroke_index INTEGER NOT NULL,
  data TEXT NOT NULL,
  FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
)

-- Text elements table
CREATE TABLE text_elements (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  note_id INTEGER NOT NULL,
  text_index INTEGER NOT NULL,
  position_x REAL NOT NULL,
  position_y REAL NOT NULL,
  text TEXT NOT NULL,
  FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
)

-- Canvas state table
CREATE TABLE canvas_state (
  note_id INTEGER PRIMARY KEY,
  matrix_data TEXT NOT NULL,
  scale REAL NOT NULL,
  FOREIGN KEY (note_id) REFERENCES notes (id) ON DELETE CASCADE
)
```

### 2.5 Deliverables ✅ **ALL DELIVERED**
- ✅ SQLite database integration
- ✅ Data models and JSON serialization
- ✅ DatabaseHelper class for data access
- ✅ Auto-save functionality (on drawing, text, pan/zoom, undo/redo)
- ✅ Export/import features (JSON format)
- ✅ Note deletion with proper cleanup
- ✅ Deep copying to prevent data reference sharing

### 2.6 Actual Effort
**Development:** ~12 hours  
**Testing:** ~4 hours  
**Total:** ~16 hours

### 2.7 Implementation Notes
- Database initialized in `main()` for desktop platforms
- Notes ordered by ID (creation order) to prevent reordering
- Canvas data saved without updating `modified_at` to maintain order
- Deep copying implemented to prevent reference sharing between notes
- Export/import available in Settings page

---

## 3. Cloud Sync

### 3.1 Overview
Implement cloud synchronization to enable multi-device access and backup of notes.

### 3.2 Requirements
- **Sync Providers**: Support multiple cloud providers:
  - **Nextcloud/WebDAV** (Recommended for self-hosted)
  - **Google Drive** (via Drive API)
  - **Dropbox** (via Dropbox API)
  - **iCloud** (iOS/macOS native)
  - **Custom server** (REST API)

- **Sync Features**:
  - Automatic background sync
  - Manual sync trigger
  - Conflict resolution (last-write-wins or manual merge)
  - Selective sync (choose which notes to sync)
  - Sync status indicators
  - Offline support with sync queue

- **Security**:
  - OAuth 2.0 authentication
  - Encrypted data transmission (HTTPS/TLS)
  - Optional end-to-end encryption for sensitive notes
  - Secure credential storage

### 3.3 Technical Implementation
- Abstract sync provider interface
- Implement provider-specific adapters
- Use background isolates for sync operations
- Implement sync queue for offline changes
- Add sync status UI indicators
- Handle network errors gracefully
- Implement retry logic with exponential backoff

### 3.4 Sync Strategy
- **Initial Sync**: Download all notes on first connection
- **Incremental Sync**: Only sync changed notes
- **Conflict Resolution**: 
  - Timestamp-based (last modified wins)
  - Manual merge option for conflicts
  - Version history (optional)

### 3.5 Deliverables
- Cloud sync infrastructure
- Multiple provider implementations
- Settings UI for sync configuration
- Sync status indicators
- Conflict resolution UI
- Documentation for adding new providers

### 3.6 Estimated Effort
**Development:** 40-60 hours  
**Testing:** 20-30 hours  
**Total:** 60-90 hours

---

## 4. Drawing Colors and Brush Settings ✅ **COMPLETED**

### 4.1 Overview
✅ Enhanced drawing capabilities with color selection, brush customization, and advanced drawing tools.

### 4.2 Requirements ✅ **ALL COMPLETED**
- ✅ **Color Selection**:
  - ✅ Color picker with block palette (BlockPicker from flutter_colorpicker)
  - ✅ Quick access to common colors via color picker
  - ✅ Theme-aware default colors (black for light mode, white for dark mode)
  - ✅ Visual color indicator on color picker button
  - ✅ Per-stroke color support
  
- ✅ **Brush Settings**:
  - ✅ Pressure sensitivity (for stylus) - already implemented
  - ✅ Variable stroke width based on pressure
  - ✅ Eraser mode with canvas background color matching
  
- ✅ **Drawing Tools**:
  - ✅ Eraser mode (uses canvas background color)
  - ✅ Drawing mode with customizable colors
  - ✅ Text mode (separate from drawing)

### 4.3 Technical Implementation ✅ **COMPLETED**
- ✅ Integrated `flutter_colorpicker` package (BlockPicker)
- ✅ Added color state (`_selectedColor`) to `_InfiniteCanvasState`
- ✅ Updated `Stroke` class to include `color` property
- ✅ Updated canvas painter to use per-stroke colors
- ✅ Implemented color picker UI with FloatingActionButton and overlay
- ✅ Updated database serialization to store stroke colors
- ✅ Color initialization based on theme in `didChangeDependencies()`
- ✅ Eraser mode uses canvas background color

### 4.4 UI/UX Design ✅ **IMPLEMENTED**
- ✅ Color picker overlay (Positioned widget with Material elevation)
- ✅ Color picker FloatingActionButton with current color indicator
- ✅ BlockPicker interface for color selection
- ✅ Tool icons with active state indication (eraser, text mode)
- ✅ Color persistence in database

### 4.5 Deliverables ✅ **ALL DELIVERED**
- ✅ Color picker implementation (BlockPicker)
- ✅ Enhanced drawing tools (color selection, eraser)
- ✅ Tool selection interface (FAB buttons)
- ✅ Color persistence in database
- ✅ Updated canvas rendering (per-stroke colors)

### 4.6 Actual Effort
**Development:** ~6 hours  
**Testing:** ~2 hours  
**Total:** ~8 hours

---

## 5. Additional Recommended Features

### 5.1 Note Organization
- **Tags System**: Add tags to notes for better organization
- **Folders/Categories**: Organize notes into folders
- **Search**: Full-text search across notes (titles, text content)
- **Sorting**: Sort by date, title, recently modified
- **Filtering**: Filter by tags, date range, etc.

**Estimated Effort:** 16-24 hours

### 5.2 Export/Import ✅ **PARTIALLY COMPLETED**
- ✅ **Export Formats**:
  - ✅ JSON (raw data for backup/import) - **COMPLETED**
  - PNG/JPEG (rasterized canvas) - **PENDING**
  - PDF (vector format, preserves quality) - **PENDING**
  - SVG (vector, editable) - **PENDING**
  
- ✅ **Import Formats**:
  - ✅ Import from JSON export files - **COMPLETED**
  - Import images as background - **PENDING**
  - Import PDF pages - **PENDING**
  - Import from other note apps (JSON) - **COMPLETED**

**Completed Effort:** ~4 hours  
**Remaining Effort:** 8-14 hours (for PNG/PDF/SVG export and image import)

### 5.3 Collaboration Features
- **Sharing**: Share notes via link or email
- **Real-time Collaboration**: Multiple users editing simultaneously (using WebSocket)
- **Comments**: Add comments to specific areas of canvas
- **Version History**: View and restore previous versions

**Estimated Effort:** 40-60 hours

### 5.4 Advanced Canvas Features
- **Layers**: Support multiple drawing layers
- **Background Images**: Add images as canvas background
- **Grid/Snap**: Show grid and snap-to-grid functionality
- **Rulers**: Display rulers for precise measurements
- **Zoom Controls**: UI controls for zoom (buttons, slider)
- **Canvas Templates**: Pre-defined canvas sizes (A4, Letter, etc.)

**Estimated Effort:** 24-36 hours

### 5.5 Performance Optimizations
- **Canvas Rendering**: Optimize for large canvases (viewport culling)
- **Stroke Simplification**: Reduce point count for smoother performance
- **Lazy Loading**: Load notes on-demand
- **Memory Management**: Efficient memory usage for large drawings
- **Background Processing**: Move heavy operations to isolates

**Estimated Effort:** 20-30 hours

### 5.6 Accessibility
- **Screen Reader Support**: Proper semantic labels
- **Keyboard Navigation**: Full keyboard support
- **High Contrast Mode**: Enhanced visibility options
- **Font Scaling**: Support system font scaling
- **Voice Input**: Dictation for text input

**Estimated Effort:** 16-24 hours

### 5.7 Platform-Specific Features
- **Android**:
  - Widget for quick note access
  - Share extension
  - Android Auto integration (voice notes)
  
- **iOS**:
  - Siri Shortcuts
  - Share extension
  - Apple Pencil optimizations
  - Handoff between devices
  
- **Desktop (Linux/Windows/macOS)**:
  - Keyboard shortcuts
  - Menu bar integration
  - File system integration
  - Multi-window support

**Estimated Effort:** 24-40 hours per platform

---

## 6. Implementation Priority

### Phase 0 (Foundation) - ✅ **COMPLETED**
1. ✅ Dark Mode Support
2. ✅ Mouse Drawing Support
3. ✅ Text Input System
4. ✅ Note Management (Multiple Notes)
5. ✅ Real-Time Drawing Performance

### Phase 1 (Core Features) - ✅ **COMPLETED**
1. ✅ Dark Mode Support
2. ✅ SQLite Local Storage
3. ✅ Import/Export (JSON format)
4. ✅ Drawing Colors and Brush Settings

### Phase 2 (Sync & Organization) - 4-6 weeks
4. Cloud Sync (basic implementation)
5. Note Organization (tags, search, folders)

### Phase 3 (Enhancement) - 3-4 weeks
6. Export/Import
7. Advanced Canvas Features
8. Performance Optimizations

### Phase 4 (Advanced) - Ongoing
9. Collaboration Features
10. Platform-Specific Features
11. Accessibility Enhancements

---

## 7. Technical Stack Recommendations

### Current Stack
- **Framework**: Flutter (Dart)
- **UI**: Material Design 3
- **Vector Math**: vector_math package
- **Theme Persistence**: shared_preferences package
- **Database**: SQLite (sqflite, sqflite_common_ffi)
- **File Operations**: path_provider, file_picker
- **Color Picker**: flutter_colorpicker
- **State Management**: StatefulWidget with setState
- **Canvas Rendering**: CustomPainter with optimized repaint logic

### Recommended Additions
- **Local Storage**: Hive or Isar
- **State Management**: Provider or Riverpod
- **Cloud Sync**: 
  - `http` package for REST APIs
  - `oauth2` package for authentication
  - `webdav` package for Nextcloud
- **Color Picker**: `flutter_colorpicker`
- **PDF Export**: `pdf` package
- **Image Processing**: `image` package
- **File Picker**: `file_picker` package

---

## 8. Testing Requirements

### Unit Testing
- Data model serialization/deserialization
- Repository layer logic
- Sync conflict resolution
- Color/brush calculations

### Widget Testing
- Theme switching
- Color picker interactions
- Settings UI
- Note list operations

### Integration Testing
- Full sync workflow
- Data persistence
- Export/import flows
- Multi-device scenarios

### Performance Testing
- Large canvas rendering (10,000+ strokes)
- Sync with large datasets
- Memory usage under load
- Battery impact

---

## 9. Documentation Requirements

- **User Documentation**:
  - Getting started guide
  - Feature tutorials
  - Sync setup instructions
  - Troubleshooting guide

- **Developer Documentation**:
  - Architecture overview
  - Data model documentation
  - API documentation
  - Contributing guidelines

---

## 10. Success Metrics

- **Performance**:
  - App launch time < 2 seconds
  - Note load time < 100ms
  - Smooth 60 FPS canvas rendering
  - Sync completes in < 30 seconds for typical notes

- **User Experience**:
  - Intuitive UI (user testing feedback)
  - < 5% crash rate
  - 4+ star rating on app stores
  - Positive user reviews

- **Data Reliability**:
  - 99.9% sync success rate
  - Zero data loss incidents
  - Successful recovery from corruption

---

## 11. Risk Assessment

### Technical Risks
- **Data Loss**: Mitigated by auto-save, cloud backup, and export features
- **Sync Conflicts**: Handled by conflict resolution strategies
- **Performance**: Addressed through optimization and testing
- **Platform Compatibility**: Tested on all target platforms

### Timeline Risks
- **Scope Creep**: Phased approach allows for prioritization
- **Third-party Dependencies**: Use stable, well-maintained packages
- **Platform Changes**: Stay updated with Flutter releases

---

## 12. Maintenance and Support

### Ongoing Maintenance
- Regular dependency updates
- Security patches
- Bug fixes
- Performance monitoring
- User feedback integration

### Support Channels
- GitHub Issues
- User documentation
- Community forum (optional)
- Email support (optional)

---

## Appendix: Feature Comparison Matrix

| Feature | Priority | Complexity | Estimated Hours | Dependencies |
|---------|----------|------------|-----------------|--------------|
| Dark Mode | High | Low | 12-18 | None |
| SQLite Storage | High | Medium | 16 (Actual) | sqflite |
| Cloud Sync | High | High | 60-90 | OAuth, HTTP |
| Drawing Colors | High | Medium | 8 (Actual) | flutter_colorpicker |
| Note Organization | Medium | Medium | 16-24 | None |
| Export/Import | Medium | Medium | 4 (Partial - JSON only) | file_picker |
| Collaboration | Low | High | 40-60 | WebSocket |
| Advanced Canvas | Medium | High | 24-36 | None |
| Performance | Medium | High | 20-30 | None |
| Accessibility | Medium | Medium | 16-24 | None |

---

**Document Status:** Active  
**Last Updated:** November 2025  
**Version:** 1.3  
**Next Review:** After Phase 2 completion

### Version History

#### Version 1.0 (2024)
- Initial SOW document
- Feature planning and prioritization

#### Version 1.1 (November 2025)
- ✅ Completed Dark Mode Support
- ✅ Completed Mouse Drawing Support
- ✅ Completed Text Input System
- ✅ Completed Note Management (Multiple Notes)
- ✅ Completed Real-Time Drawing Performance
- Updated implementation priority to reflect completed features
- Added completed features section
- Updated technical stack with implemented packages

#### Version 1.2 (November 2025)
- ✅ Completed SQLite Local Storage
- ✅ Completed Import/Export Functionality (JSON)
- ✅ Added Note Deletion Feature
- ✅ Fixed note content alignment issues
- ✅ Implemented deep copying to prevent data reference sharing
- ✅ Added proper UI updates on note create/delete
- ✅ Fixed note ordering (by ID instead of modified_at)
- Updated SOW to reflect SQLite implementation
- Updated technical stack with database packages

#### Version 1.3 (November 2025)
- ✅ Completed Drawing Colors and Brush Settings
- ✅ Added color picker with BlockPicker interface
- ✅ Implemented per-stroke color support
- ✅ Updated database to store stroke colors
- ✅ Fixed theme initialization in didChangeDependencies()
- ✅ Phase 1 (Core Features) completed
- Updated SOW to mark Phase 1 as complete

