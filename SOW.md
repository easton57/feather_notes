# Statement of Work (SOW)
## Feather Notes - Feature Development

**Project:** Feather Notes - Cross-Platform Note-Taking Application  
**Date:** 2024  
**Version:** 1.7  
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

## 3. Cloud Sync ✅ **COMPLETED**

### 3.1 Overview
✅ Implemented comprehensive cloud synchronization to enable multi-device access and backup of notes. Full sync infrastructure is complete with support for multiple providers, background sync, conflict resolution, selective sync, and offline queue management.

### 3.2 Requirements ✅ **COMPLETED**
- ✅ **Sync Providers**: Support multiple cloud providers:
  - ✅ **Nextcloud/WebDAV** (Recommended for self-hosted) - **COMPLETED & TESTED**
  - ✅ **Google Drive** (via Drive API) - **COMPLETED** (needs testing)
  - ⚠️ **Dropbox** (via Dropbox API) - **PENDING**
  - ✅ **iCloud Drive** (via WebDAV) - **COMPLETED** (needs testing)
  - ⚠️ **Custom server** (REST API) - **PENDING**

- ✅ **Sync Features**:
  - ✅ Automatic background sync - **COMPLETED**
  - ✅ Manual sync trigger - **COMPLETED**
  - ✅ Conflict resolution (last-write-wins or manual merge) - **COMPLETED**
  - ✅ Selective sync (choose which notes to sync) - **COMPLETED**
  - ✅ Sync status indicators - **COMPLETED**
  - ✅ Offline support with sync queue - **COMPLETED**

- ✅ **Security**:
  - ✅ OAuth 2.0 authentication (Google Drive) - **COMPLETED**
  - ✅ Encrypted data transmission (HTTPS/TLS) - **COMPLETED**
  - ⚠️ Optional end-to-end encryption for sensitive notes - **PENDING**
  - ✅ Secure credential storage (encrypted SharedPreferences) - **COMPLETED**

### 3.3 Technical Implementation ✅ **COMPLETED**
- ✅ Abstract sync provider interface (`SyncProvider`) - **COMPLETED**
- ✅ Implement provider-specific adapters (Nextcloud, iCloud, Google Drive) - **COMPLETED**
- ⚠️ Use background isolates for sync operations - **PENDING** (using Timer-based approach instead)
- ✅ Implement sync queue for offline changes - **COMPLETED**
- ✅ Add sync status UI indicators - **COMPLETED**
- ✅ Handle network errors gracefully - **COMPLETED**
- ✅ Implement retry logic (max 5 retries) - **COMPLETED**
- ✅ Background sync with configurable frequency (5 min to 12 hours) - **COMPLETED**
- ✅ Conflict resolution UI with manual selection (Use Local, Use Remote, Keep Both) - **COMPLETED**
- ✅ Selective sync UI for choosing which notes to sync - **COMPLETED**
- ✅ Password pre-filling in configuration dialog - **COMPLETED**
- ✅ Manual sync button in sync settings - **COMPLETED**

### 3.4 Sync Strategy ✅ **COMPLETED**
- ✅ **Initial Sync**: Download all notes on first connection - **COMPLETED**
- ✅ **Incremental Sync**: Only sync changed notes - **COMPLETED**
- ✅ **Conflict Resolution**: 
  - ✅ Timestamp-based (last modified wins) - **COMPLETED** (automatic)
  - ✅ Manual merge option for conflicts - **COMPLETED** (Use Local, Use Remote, Keep Both)
  - ⚠️ Version history (optional) - **PENDING**
- ✅ **Background Sync**: Configurable automatic sync (5 min to 12 hours) - **COMPLETED**
- ✅ **Offline Queue**: Operations queued when offline, processed when online - **COMPLETED**
- ✅ **Selective Sync**: Choose which notes to sync - **COMPLETED**

### 3.5 Deliverables ✅ **ALL DELIVERED**
- ✅ Cloud sync infrastructure - **COMPLETED**
- ✅ Multiple provider implementations (Nextcloud, iCloud, Google Drive) - **COMPLETED**
- ✅ Settings UI for sync configuration - **COMPLETED**
- ✅ Sync status indicators - **COMPLETED**
- ✅ Conflict resolution UI - **COMPLETED**
- ✅ Background sync with frequency selector - **COMPLETED**
- ✅ Manual sync button - **COMPLETED**
- ✅ Selective sync UI - **COMPLETED**
- ✅ Offline sync queue with retry logic - **COMPLETED**
- ✅ Password pre-filling in configuration dialog - **COMPLETED**
- ✅ Documentation for adding new providers (abstract interface) - **COMPLETED**

### 3.6 Actual Effort
**Development:** ~40 hours  
**Testing:** ~8 hours (Nextcloud tested, iCloud/Google Drive pending)  
**Total:** ~48 hours

**Note:** iCloud and Google Drive providers are implemented but need testing. All core sync features including background sync, conflict resolution, selective sync, and offline queue are complete.

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

### 5.1 Note Organization ✅ **COMPLETED**

#### 5.1.1 Overview
✅ Implemented comprehensive note organization features including tags, search, sorting, and filtering.

#### 5.1.2 Requirements ✅ **ALL COMPLETED**
- ✅ **Tags System**: 
  - ✅ Add tags to notes for better organization
  - ✅ Tag editor dialog with comma-separated input
  - ✅ Tags displayed as chips under note titles
  - ✅ Many-to-many relationship in database (note_tags table)
  - ✅ Tag management (get, set, retrieve all tags)
  
- ✅ **Search**: 
  - ✅ Full-text search across note titles
  - ✅ Real-time filtering as you type
  - ✅ Search bar in drawer with clear button
  
- ✅ **Sorting**: 
  - ✅ Sort by creation order (default)
  - ✅ Sort by title (A-Z)
  - ✅ Sort by date created
  - ✅ Sort by recently modified
  - ✅ Dropdown selector in drawer
  
- ✅ **Filtering**: 
  - ✅ Filter by tags using FilterChips
  - ✅ Multiple tag selection
  - ✅ Shows all available tags as filter options
  - ✅ Combined with search and sorting
  
- **Folders/Categories**: Organize notes into folders - **PENDING** (not implemented)

#### 5.1.3 Technical Implementation ✅ **COMPLETED**
- ✅ Database schema updated (version 2) with `note_tags` table
- ✅ Migration script for existing databases
- ✅ Search, sort, and filter integrated into `getAllNotes()` method
- ✅ UI components: search bar, sort dropdown, tag filter chips
- ✅ Tag editor dialog for adding/editing tags
- ✅ Real-time filter application

#### 5.1.4 UI/UX Design ✅ **IMPLEMENTED**
- ✅ Search bar with clear button in drawer
- ✅ Sort dropdown with 4 options
- ✅ Tag filter chips (FilterChip widgets)
- ✅ Tags displayed as chips under note titles
- ✅ Tag editor button (label icon) on each note
- ✅ Combined search, sort, and filter functionality

#### 5.1.5 Deliverables ✅ **ALL DELIVERED**
- ✅ Tags system with database support
- ✅ Search functionality
- ✅ Sorting options (4 different sorts)
- ✅ Tag-based filtering
- ✅ Tag editor UI
- ✅ Database migration for tags

#### 5.1.6 Actual Effort
**Development:** ~8 hours  
**Testing:** ~2 hours  
**Total:** ~10 hours

**Estimated Effort:** 16-24 hours (original estimate)

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

- ✅ **Sync Conflict Resolution UI** - **COMPLETED**
  - ✅ Manual conflict resolution dialog
  - ✅ Choose local vs remote version
  - ✅ Merge option for conflicts (Keep Both)
  - ⚠️ Conflict history and resolution tracking - **PENDING**
  - ⚠️ Visual comparison of conflicting versions - **PENDING**

**Completed Effort:** ~4 hours  
**Remaining Effort:** 10-16 hours (for PNG/PDF/SVG export, image import, and advanced conflict features)

### 5.2.1 Database Management ✅ **COMPLETED**
- ✅ **Database Wipe Feature**:
  - ✅ Wipe all data option in Settings page
  - ✅ Confirmation dialog to prevent accidental deletion
  - ✅ Deletes all notes, strokes, text elements, canvas state, and tags
  - ✅ Automatic note list refresh after wipe
  - ✅ Error handling and user feedback
  - ✅ Database connection reset for clean state

**Completed Effort:** ~1 hour

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
- ✅ **Zoom Controls**: UI controls for zoom (buttons, slider) - **PARTIALLY COMPLETED**
  - ✅ Minimap with viewport indicator - **COMPLETED** (viewport alignment being refined)
  - ✅ Mouse wheel zoom - **COMPLETED**
  - ✅ Two-finger pinch zoom - **COMPLETED**
  - ✅ Right-click drag panning - **COMPLETED**
  - ⚠️ Zoom UI controls (buttons, slider) - **PENDING**
- **Canvas Templates**: Pre-defined canvas sizes (A4, Letter, etc.)
- ✅ **Text Font Size Control**: Font size adjuster in text mode - **COMPLETED**
  - ✅ Font size slider (8-48px) - **COMPLETED**
  - ✅ Real-time font size preview - **COMPLETED**
  - ✅ Applied to all text elements - **COMPLETED**

**Estimated Effort:** 24-36 hours  
**Completed Effort:** ~6 hours (minimap, zoom controls, font size adjuster)

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

### Phase 2 (Sync & Organization) - ✅ **COMPLETED**
1. ✅ Cloud Sync (full implementation) - **COMPLETED**
   - ✅ Nextcloud/WebDAV provider - **COMPLETED & TESTED**
   - ✅ iCloud Drive provider - **COMPLETED** (needs testing)
   - ✅ Google Drive provider - **COMPLETED** (needs testing)
   - ✅ Sync configuration persistence with encrypted passwords
   - ✅ Bidirectional sync with timestamp-based conflict detection
   - ✅ Sync conflict resolution UI (Use Local, Use Remote, Keep Both) - **COMPLETED**
   - ✅ Background sync with configurable frequency (5 min to 12 hours) - **COMPLETED**
   - ✅ Manual sync button - **COMPLETED**
   - ✅ Selective sync (choose which notes to sync) - **COMPLETED**
   - ✅ Offline sync queue with retry logic (max 5 retries) - **COMPLETED**
   - ✅ Password pre-filling in configuration dialog - **COMPLETED**
2. ✅ Note Organization (tags, search, sorting, filtering) - **COMPLETED**

### Phase 3 (Enhancement) - 3-4 weeks
1. Export/Import Enhancements
   - ✅ JSON export/import - **COMPLETED**
   - PNG/JPEG export (rasterized canvas) - **PENDING**
   - PDF export (vector format) - **PENDING**
   - SVG export (vector, editable) - **PENDING**
   - Image import as background - **PENDING**
   - ⚠️ Conflict history and resolution tracking - **PENDING**
   - ⚠️ Visual comparison of conflicting versions - **PENDING**
2. Advanced Canvas Features
3. Performance Optimizations

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
| Cloud Sync (Full) | High | High | 48 (Actual) | OAuth, HTTP, googleapis |
| Drawing Colors | High | Medium | 8 (Actual) | flutter_colorpicker |
| Note Organization | Medium | Medium | 10 (Actual) | None |
| Export/Import | Medium | Medium | 4 (Partial - JSON only) | file_picker |
| Sync Conflict Resolution | Medium | Medium | 8 (Actual) | None |
| Collaboration | Low | High | 40-60 | WebSocket |
| Advanced Canvas | Medium | High | 24-36 | None |
| Performance | Medium | High | 20-30 | None |
| Accessibility | Medium | Medium | 16-24 | None |

---

**Document Status:** Active  
**Last Updated:** December 2025  
**Version:** 1.7  
**Next Review:** After Phase 3 completion

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

#### Version 1.4 (November 2025)
- ✅ Completed Note Organization (Phase 2)
- ✅ Implemented Tags System with database support
- ✅ Added Search functionality (title search)
- ✅ Added Sorting options (4 different sorts)
- ✅ Added Tag-based Filtering
- ✅ Added Tag Editor UI
- ✅ Database schema updated to version 2 with note_tags table
- ✅ Added Database Wipe feature in Settings
- ✅ Fixed note creation issues with filters
- ✅ Fixed infinite loading loop
- ✅ Fixed QueryRow read-only error
- Updated SOW to mark Note Organization as complete

#### Version 1.5 (November 2025)
- ✅ Completed Cloud Sync basic implementation (Phase 2)
- ✅ Implemented Nextcloud/WebDAV provider (tested)
- ✅ Implemented iCloud Drive provider (needs testing)
- ✅ Implemented Google Drive provider (needs testing)
- ✅ Added sync configuration persistence with encrypted passwords
- ✅ Implemented bidirectional sync with timestamp-based conflict detection
- ✅ Added sync status indicators in UI
- ✅ Phase 2 marked as complete
- ⚠️ Sync conflict resolution UI moved to Phase 3
- Updated SOW to reflect Phase 2 completion and Phase 3 planning

#### Version 1.6 (November 2025)
- ✅ Completed Cloud Sync full implementation (Phase 2)
- ✅ Implemented background sync with configurable frequency (5 min to 12 hours)
- ✅ Implemented conflict resolution UI (Use Local, Use Remote, Keep Both)
- ✅ Implemented selective sync (choose which notes to sync)
- ✅ Implemented offline sync queue with retry logic (max 5 retries)
- ✅ Added manual sync button in sync settings
- ✅ Added password pre-filling in configuration dialog
- ✅ Added sync frequency selector UI
- ✅ Phase 2 fully completed with all planned features
- Updated SOW to reflect complete Cloud Sync implementation

#### Version 1.7 (December 2025)
- ✅ Code cleanup and optimization
  - ✅ Removed all debug print statements (77 total)
  - ✅ Removed unused imports (sync_provider, nextcloud_provider, conflict_resolution_dialog, sync_settings_page)
  - ✅ Fixed code formatting and syntax issues
  - ✅ Improved code maintainability
- ✅ Enhanced UI/UX improvements
  - ✅ Added collapsible toolbox menu for right-side buttons
    - ✅ Menu toggle button with build icon
    - ✅ All tool buttons (Undo, Redo, Eraser, Text Mode, Color Picker) now in collapsible menu
    - ✅ Reduces UI clutter while maintaining full functionality
  - ✅ Added font size adjuster for text mode
    - ✅ Font size slider (8-48px range)
    - ✅ +/- buttons for fine adjustment
    - ✅ Real-time font size preview in text input
    - ✅ Font size applied to all text elements on canvas
    - ✅ Font size adjuster appears when text mode is active and toolbox menu is open
  - ✅ Improved minimap viewport indicator
    - ✅ Fixed viewport bounds calculation using corner transformation
    - ✅ Improved viewport rectangle positioning in minimap
    - ⚠️ Viewport alignment still being refined
- ✅ Technical improvements
  - ✅ Updated _CanvasPainter and _MinimapPainter to accept font size parameter
  - ✅ Improved state management for text editing
  - ✅ Enhanced coordinate transformation accuracy

