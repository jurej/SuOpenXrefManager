# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Open XRef Manager is a SketchUp plugin that provides an external reference (XRef) system for collaborative workflows. It allows teams to work on different parts of a project in separate files while maintaining live, synchronized links between them.

**License:** GNU GPL v3
**Current Version:** 1.3.2
**Language:** Ruby (for SketchUp plugin development)
**UI:** HTML/JavaScript with Modus CSS framework

## Architecture

### Plugin Structure

The plugin follows SketchUp's standard extension architecture with a modular design:

```
OpenXrefManager.rb                    # Extension registration file
OpenXrefManager/
  ├── OpenXrefManager_main.rb         # Entry point - loads all modules
  ├── modules/                        # Modular code organization
  │   ├── core.rb                     # Constants, state, basic helpers
  │   ├── file_operations.rb          # Path resolution, lock file I/O
  │   ├── xref_operations.rb          # Check-out, check-in, reload, etc.
  │   ├── ui_manager.rb               # Dialog management, background timer
  │   ├── menu_toolbar.rb             # Menu and toolbar setup
  │   └── observers/                  # Observer classes
  │       ├── app_observer.rb         # Application lifecycle events
  │       ├── model_observer.rb       # Model-level events
  │       └── entities_observer.rb    # Entity modification events
  ├── manager.html                    # XRef Manager UI dialog
  ├── icons/                          # Toolbar icons
  └── modus/                          # Modus CSS framework for UI styling
```

### Core Components

1. **Core Module (`OpenXrefManager::Core`)**: Defines constants, manages state, provides basic helper methods
2. **File Operations (`OpenXrefManager::FileOperations`)**: Handles path resolution, lock file I/O, and file system operations
3. **XRef Operations (`OpenXrefManager::XrefOperations`)**: Implements all XRef CRUD operations (check-out, check-in, reload, etc.)
4. **UI Manager (`OpenXrefManager::UIManager`)**: Manages dialog, background timer, and status monitoring
5. **Observers (`OpenXrefManager::Observers`)**: Three observer classes monitor application, model, and entity events
6. **Menu/Toolbar (`OpenXrefManager::MenuToolbar`)**: Sets up UI elements and registers commands
7. **Lock System**: File-based locking mechanism using `.lock` files to coordinate multi-user access

### Key Design Patterns

**Attribute Storage**: XRef metadata is stored in SketchUp's attribute dictionaries on component definitions:
- `XREF_DICT_NAME = "OpenXrefManager::Xref"`
- Stores: path, path_type (absolute/relative), is_unloaded flag, timestamp

**File Locking Protocol**: Lock files (`.skp.lock`) contain pipe-delimited data:
```
username|model_guid|model_name|model_path
```

**Observer Architecture**:
- `OpenXrefManager::Observers::AppObserver`: Manages model lifecycle events (new/open/quit)
- `OpenXrefManager::Observers::ModelObserver`: Handles model events (save, undo, component edit, save-as)
- `OpenXrefManager::Observers::EntitiesObserver`: Prevents unauthorized unlocking of checked-out XRefs

**Background Monitoring**: Timer-based polling (5-second intervals) checks for lock file changes and updates instance lock states automatically

**Module Loading**: Uses `Sketchup.require` (not `require_relative`) to load modules in dependency order:
1. Core (constants and state)
2. FileOperations (depends on Core)
3. XrefOperations (depends on Core, FileOperations)
4. UIManager (depends on all above)
5. Observers (depend on all above)
6. MenuToolbar (initialization, depends on all above)

## Development Commands

This is a SketchUp Ruby plugin - there are no build, test, or lint commands. Development involves:

1. **Manual Installation**: Copy files to SketchUp's Plugins folder:
   - Windows: `%APPDATA%\SketchUp\SketchUp 20XX\SketchUp\Plugins\`
   - macOS: `~/Library/Application Support/SketchUp 20XX/SketchUp/Plugins/`

2. **Testing**: Manual testing within SketchUp after reloading the plugin

3. **Debugging**: Use Ruby `puts` statements that output to SketchUp's Ruby Console

## Key Implementation Details

### Path Resolution

The system supports both absolute and relative paths. When resolving paths:
```ruby
OpenXrefManager::FileOperations.resolve_xref_path(definition)
```
- For relative paths: joins the stored relative path with the parent model's directory
- For absolute paths: returns the stored path directly
- Always use `FileOperations.resolve_xref_path` when accessing XRef files to get the correct absolute path

### Status Determination

XRef status is computed dynamically based on multiple factors:
1. File existence
2. Lock file state (unlocked, locked by user, locked by others)
3. Timestamp comparison (for update detection)
4. Unloaded flag

Status keys: `ok`, `not_found`, `mine`, `mine_elsewhere`, `locked`, `unloaded`, `update_available`

### Critical Operations

**Check-out Flow**:
1. Create `.lock` file with user info and current model GUID
2. Unlock component instances in current model
3. Allow editing

**Check-in Flow**:
1. Save component definition to external file
2. Update timestamp attribute
3. Delete `.lock` file
4. Close edit context if currently editing

**Reload Flow**:
1. Load new definition from file using `model.definitions.load(path)`
2. Reassign all instances from old definition to new definition
3. Copy XRef attributes to new definition
4. Remove attributes from old definition and purge
5. Rename new definition to original name

**GUID Update on Save**: When a model is saved for the first time, its GUID changes. The `onSaveModel` observer updates all lock files owned by the current user to reference the new GUID.

### Observer Event Handling

Most observer methods use `UI.start_timer(0.1, false)` to defer UI operations, avoiding conflicts when SketchUp is processing other events.

### Background Timer

The timer runs continuously while a model is open, checking for:
- Lock file changes (other users checking in/out)
- File timestamp changes (update detection)
- Automatic instance locking when status changes

Disable during operations that don't need live updates; re-enable when complete.

## UI Communication

The HTML dialog communicates with Ruby via callbacks:
```javascript
sketchup.callback_name(arg1, arg2, ...)
```

Ruby sends data to UI via script execution:
```ruby
@dialog.execute_script("updateTable(#{json_data})")
```

All XRef data is serialized to JSON in `get_xref_data_as_json` for UI consumption.

## Important Conventions

1. **Always use model operations**: Wrap changes in `model.start_operation` / `model.commit_operation` for undo support
2. **Close edit context when needed**: If modifying a component being edited, call `model.close_active`
3. **Instance locking**: XRefs locked by others or with updates available should have locked instances
4. **Lock file ownership**: Only modify/delete lock files you own (same username + GUID) unless using force operations
5. **Timestamp updates**: Call `Core.update_xref_timestamp` after saving or reloading to track modifications
6. **Dialog refresh**: Call `UIManager.refresh_dialog_data` after any operation that changes XRef state
7. **Module access**: All modules are under `OpenXrefManager::` namespace - use fully qualified names when calling across modules

## Common Pitfalls

- **Don't modify lock files directly without checking ownership**
- **Always resolve paths using `resolve_xref_path`** - don't use stored paths directly for file operations
- **Component reload requires careful instance reassignment** - see `reload_single_xref_without_warning` for the pattern
- **GUID changes on first save** - the `update_owned_lock_files` method handles this critical edge case
- **Observer garbage collection** - observers must be stored in class variables (`@@`) or instance variables at module level to prevent GC

## File Organization

- **Modular structure**: Code split into logical modules for maintainability
- **Dependency order**: Modules loaded via `Sketchup.require` in dependency order (see OpenXrefManager_main.rb)
- **Observer isolation**: Each observer class in separate file under `modules/observers/`
- **Clear separation**: Core (state), FileOps (I/O), XrefOps (business logic), UIManager (presentation) clearly separated
- **HTML UI**: Self-contained with inline JavaScript in `manager.html`
- **Dependencies**: No external Ruby gems - only SketchUp API and standard library (`pathname`)
- **Backup**: Original monolithic code saved as `OpenXrefManager_main.rb.backup`

## Module Responsibilities

### Core (`modules/core.rb`)
- Constants (XREF_DICT_NAME, timer intervals, etc.)
- Module state variables (dialog, user_name, timer, last_xref_statuses)
- State accessors
- Basic helper methods (get_xref_definitions, is_xref?, update_xref_timestamp, etc.)

### FileOperations (`modules/file_operations.rb`)
- Path resolution (resolve_xref_path)
- Lock file I/O (get_xref_lock_status)
- Update detection (is_update_available?)
- Path type management (set_xref_path, toggle_path_type)
- Lock file updates (update_owned_lock_files)

### XrefOperations (`modules/xref_operations.rb`)
- Check-out/Check-in operations
- Import/Export XRefs
- Reload operations
- Unload/Unlink operations
- Component to XRef conversion

### UIManager (`modules/ui_manager.rb`)
- Background timer management
- Status change monitoring
- Dialog creation and management
- Data serialization for UI (get_xref_data_as_json)
- UI refresh

### Observers (`modules/observers/`)
- **AppObserver**: Model lifecycle (new/open/quit), observer attachment
- **ModelObserver**: Save events, undo, active path changes, component save-as
- **EntitiesObserver**: Prevents unauthorized unlocking

### MenuToolbar (`modules/menu_toolbar.rb`)
- Toolbar creation
- Menu setup
- Context menu handlers
- Command registration
- Observer initialization
