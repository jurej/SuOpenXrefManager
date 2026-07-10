# SketchUp Open XRef Manager

Open XRef Manager is a comprehensive external reference (XRef) system for SketchUp. This plugin enables collaborative workflows by allowing teams to work on different parts of a project in separate files while maintaining live, synchronized links between them.

## Key Features

- **XRef Manager Window** - Central dashboard to view and manage all linked files
- **Check-In/Check-Out System** - Robust locking mechanism to prevent conflicts
- **Create from Component or Group** - Convert components or groups to XRefs; optionally store position for accurate placement on load
- **Claim for this session** - Fix false "Checked Out (You, elsewhere)" (e.g. after Save As) by assigning the lock to this window
- **Automatic Monitoring** - Background status checks and notifications
- **Flexible Paths** - Support for both absolute and relative file paths
- **Quick Access** - Dedicated toolbar and context menus
- **Unload/Reload** - Optimize performance by temporarily unloading geometry

## Installation

### Recommended: Install from .rbz File (Easiest Method)

1. Download the latest `.rbz` file from the `releases` folder:
   - `releases/OpenXrefManager_v1.8.5.rbz` (or latest version)
2. Open SketchUp
3. Go to **Window → Extension Manager**
4. Click **Install Extension** button
5. Select the downloaded `.rbz` file
6. Restart SketchUp
7. The XRef Manager toolbar should appear automatically

### Alternative: Manual Installation

If you prefer to install manually or are developing:

1. Download the plugin files
2. Copy the `OpenXrefManager` folder and `OpenXrefManager.rb` file to your SketchUp Plugins folder:
   - **Windows**: `C:\Users\[username]\AppData\Roaming\SketchUp\SketchUp [version]\SketchUp\Plugins\`
   - **Mac**: `~/Library/Application Support/SketchUp [version]/SketchUp/Plugins/`
3. Restart SketchUp
4. The XRef Manager toolbar should appear automatically

### Building from Source

To build a new `.rbz` file for distribution:

1. Update the version number in:
   - `OpenXrefManager.rb` (line 25)
   - `OpenXrefManager/core.rb` (line 3)
2. Run the build script:
   ```powershell
   .\build_rbz.ps1
   ```
3. The `.rbz` file will be created in the `releases` folder

See `releases/BUILD_INSTRUCTIONS.md` for more details.

## Getting Started

### Set Your User Name

Before using the plugin, set your user name so your team knows who has files checked out:

1. Open the XRef Manager: **Extensions → Open XRef Manager → Show Manager**
2. Click the **Set User** button
3. Enter your name and click OK

This name will appear in lock files and help your team coordinate work.

### Configure Settings

The plugin has configurable settings that control its behavior:

1. Click the **Settings** button in the XRef Manager (or **Extensions → Open XRef Manager → Settings**)
2. Configure the following options:
   - **Automatically check out when entering XRef**: Controls whether XRefs are automatically checked out when you double-click to enter them for editing
   - **Background check interval (seconds)**: How often the plugin checks for XRef updates and lock changes

**Auto-Checkout Setting:**
- **Enabled (Default)**: When you double-click an XRef component to edit it, you'll be prompted to check it out. This creates the lock file and unlocks the instances automatically
- **Disabled**: When you double-click an XRef component, you'll see a warning that auto-checkout is disabled. You must manually check out the XRef from the XRef Manager before editing, or your changes will not be saved to the external file

**Background Check Interval:**
- **Default**: 2 seconds
- **Range**: 1-60 seconds
- **Lower values** (1-3 seconds): More responsive to changes, but slightly higher overhead
- **Higher values** (5-60 seconds): Better performance, but slower to detect changes
- **Recommendation**: Use 5-10 seconds for network drives, 2-3 seconds for local drives

The disabled auto-checkout mode is useful when you want full manual control over when XRefs are checked out, preventing accidental checkouts.

## Core Concepts

### What is an XRef?

An **XRef (External Reference)** is a SketchUp component that maintains a live link to an external `.skp` file. When the external file is updated, all models using that XRef can reload to get the latest version.

### Check-Out/Check-In System

The plugin uses a file-based locking system:

- **Check Out** - Creates a `.lock` file next to the XRef file, marking it as "in use"
- **Check In** - Saves your changes to the XRef file and removes the lock
- **Locked Components** - Components locked by others appear locked in SketchUp to prevent accidental edits

### Lock File Format

Lock files (`.skp.lock`) contain: `username|model_guid|model_name|model_path`

This information helps you identify who has a file checked out and from which model.

## Using the XRef Manager

### Opening the Manager

- **Menu**: Extensions → Open XRef Manager → Show Manager
- **Toolbar**: Click the XRef Manager icon

### Understanding Status Indicators

| Status | Meaning |
|--------|---------|
| **Available** | Ready to check out |
| **Checked Out (You)** | You have this checked out in the current model |
| **Checked Out (You, elsewhere)** | You have this checked out in another model (or a false positive after Save As). Use **Claim for this session** in the status column or context menu to assign the lock to this window. |
| **Locked by [Name]** | Another user has this checked out |
| **Read-Only Checkout** | Checked out in read-only mode (locked by another user, but you can edit locally) |
| **Read-Only Checkout (Modified)** | Read-only checkout with local modifications that haven't been published |
| **Update Available** | The file on disk is newer than your version |
| **File Not Found** | The linked file cannot be found |
| **Unloaded** | Geometry temporarily removed for performance |

## Working with XRefs

### Creating an XRef from a Component or Group

Convert an existing component or group into an XRef:

1. Select a component instance or a group in your model
2. Click **Create from Component or Group** in the XRef Manager (or right-click → **Open XRef Manager** → **Create XRef from this Component...** / **Create XRef from this Group...**)
3. Choose where to save the XRef file (`.skp`)
4. Optionally choose to store the position relative to current axes or global origin (for accurate placement when loading via Import at Origin)
5. Choose whether to use relative or absolute paths

The component (or group, which is converted to a component) is now linked to the external file.

### Importing an XRef

Import an external SketchUp file as an XRef:

**Import & Place**:
1. Click **Import & Place** in the XRef Manager
2. Select a `.skp` file
3. Click to place the component in your model

**Import at Origin**:
1. Click **Import at Origin** in the XRef Manager
2. Select a `.skp` file
3. Choose placement: **Yes** = use stored position relative to current construction axes (if the file has stored position), or place at current axes; **No** = use stored position in world space or at global origin (0,0,0)
4. The component is placed accordingly (XRefs created with "store position" are placed correctly when loaded)

### Checking Out an XRef

There are two ways to check out an XRef:

**Method 1: Automatic (when auto-checkout is enabled)**
1. Double-click an XRef component to enter edit mode
2. You'll be prompted: "Do you want to check it out?"
3. Click Yes to create the lock file and unlock instances
4. Make your changes

**Method 2: Manual**
1. In the XRef Manager, find the XRef you want to edit
2. Click the **Check Out** button (unlock icon)
3. A `.lock` file is created and instances unlock
4. Double-click the component to make your changes

**Context menu shortcut**: Right-click the component → Open XRef Manager → Check Out

**Note**: When auto-checkout is disabled in Settings, only Method 2 will work. You'll see a warning if you try to enter an XRef without checking it out first.

### Saving Changes (Check In)

To save your changes and release the lock:

1. Click the **Save & Check In** button (save icon)
2. Your changes are saved to the XRef file
3. The `.lock` file is removed
4. Other users can now check out the file

**Tip**: Use "Keep locked after publish" checkbox to save without releasing the lock.

### Save & Publish All

To save all checked-out XRefs at once:

1. Click **Save & Publish All** at the bottom of the manager
2. All your checked-out XRefs are saved
3. Check "Keep locked after publish" to retain locks (this setting is remembered for future sessions)

## Advanced Features

### Read-Only Checkout

When an XRef is locked by another user, you can check it out in **read-only mode** to make local edits without the ability to publish changes back to the file:

1. The XRef will show status "Locked by [Name]"
2. Click the **Check Out (Read-Only)** button (orange/yellow unlock icon) in the XRef Manager
3. Or right-click the component → **Check Out (Read-Only)**
4. The XRef is now in read-only checkout mode
5. You can edit the XRef locally, and changes are saved in your model
6. You **cannot** publish changes to the external file while it's locked by another user

**Features:**
- Local edits are saved in your model file
- Status shows "Read-Only Checkout" or "Read-Only Checkout (Modified)" if you've made changes
- If you modify the XRef, an "Update Available" button appears to discard local changes and revert to the published version
- When the lock is released by the other user, you'll be notified and can upgrade to a full checkout
- To cancel read-only checkout, click the **Cancel** button (X icon) in the first action column

**Use Cases:**
- Making temporary edits for visualization or testing
- Working on a local copy while waiting for the lock to be released
- Experimenting with changes without affecting the published version

### Claim for this session (1.8.3)

If an XRef shows "Checked Out (You, elsewhere)" but you are not actually using it in another window (e.g. after **Save As** or a stale lock):

1. In the XRef Manager, click the **Claim for this session** icon (person pin) in the Status column, or right-click the component → **Open XRef Manager** → **Claim for this session...**
2. Confirm the dialog (only use this if you are not using the XRef in another window)
3. The lock file is updated to this model; status changes to "Checked Out (You)" and you can use **Save & Check In** as usual

**Note**: If you really do have the XRef open in another window, claiming here will move the lock to this session and the other window will show "Checked Out (You, elsewhere)".

### Force Check-In

If you have an XRef checked out in another model/session and need to check it in from the current model:

1. The XRef will show status "Checked Out (You, elsewhere)"
2. Right-click the component → **Open XRef Manager** → **Force Check In...**
3. Confirm the warning dialog
4. The file is saved from the current model, overwriting the previous version
5. The lock is removed and instances are unlocked

**Warning**: This overwrites the XRef file with the version from THIS model. Any changes in the other session will be lost.

**Note**: Force Check-In has been moved to the context menu to prevent accidental use.

### Force Unlock

If a file is locked by another user who is no longer working on it:

1. The XRef will show "Locked by [Name]"
2. Right-click the component → **Open XRef Manager** → **Force Unlock...**
3. Confirm the warning
4. The `.lock` file is deleted

**Warning**: Only use this if you're certain the other user is not actively working on the file. This can cause data loss.

**Note**: Force Unlock has been moved to the context menu to prevent accidental use.

### Updating XRefs

When an XRef file has been updated on disk:

1. The status shows "Update Available" (red)
2. Click the **Update** button (update icon)
3. Confirm you want to reload (this discards any local changes)
4. The XRef reloads with the latest version

### Reloading XRefs

To discard local changes and reload from disk:

1. Click the **Reload** button on a specific XRef
2. Or use **Reload All** to reload all XRefs at once

**Note**: This discards any uncommitted changes to that XRef.

### Relinking an XRef

To change which file an XRef points to:

1. Click the **Relink** button (link icon)
2. Select a new `.skp` file
3. The XRef updates to point to the new file

### Unlinking an XRef

To convert an XRef back into a regular component:

1. Click the **Unlink** button (link off icon)
2. Confirm the action
3. The XRef attributes are removed
4. It becomes a normal, internal component
5. If you have it checked out, the lock is removed

### Unloading XRefs

To improve performance on large models:

1. Click the **Unload** button (visibility off icon)
2. The geometry is removed from the definition
3. The link remains intact
4. Click **Reload** to restore the geometry

**Note**: Unloading removes any uncommitted changes and releases locks.

### Path Types

**Absolute Paths**:
- Full path to the file (e.g., `C:\Projects\Building\Window.skp`)
- Works regardless of where the main model is saved
- Best for network drives or fixed locations

**Relative Paths**:
- Path relative to the main model (e.g., `Components\Window.skp`)
- Allows moving entire project folders
- Requires the main model to be saved
- Only works if files are on the same drive

**To toggle path type**:
1. Click the **Relative** or **Absolute** button in the Path Type column
2. The path is converted automatically

### Selecting XRef Instances

To select all instances of an XRef in your model:

1. Click anywhere on the XRef's row (except buttons)
2. All instances are selected in the model

### Purging Unused XRefs

To remove XRefs that have no instances in the model:

1. Click **Purge Removed Xref's** at the bottom of the manager
2. Unused XRef definitions are removed
3. Lock files are removed if you own them

## Workflow Examples

### Solo Workflow

1. Create components in your main model
2. Convert frequently reused components to XRefs
3. Use the same XRef across multiple project models
4. Update the XRef once, reload in all models

### Auto-Checkout vs Manual Workflow

**With Auto-Checkout Enabled (Default)**:
1. Double-click an XRef to edit it
2. Prompted: "Do you want to check it out?"
3. Click Yes → XRef is checked out automatically
4. Make your changes
5. Save & Check In when done

**With Auto-Checkout Disabled**:
1. Open XRef Manager first
2. Click "Check Out" button for the XRef you want to edit
3. Double-click the XRef to edit it
4. See warning if you forgot to check out
5. Make your changes
6. Save & Check In when done

The disabled mode gives you more control and prevents accidental checkouts when you're just browsing the model.

### Team Workflow

**Person A** (working on building exterior):
1. Create/import building shell component
2. Convert to XRef → save as `Building_Shell.skp`
3. Check out the XRef
4. Model the exterior walls
5. Save & Check In when done

**Person B** (working on interior):
1. Open the same main model
2. See "Building_Shell" is locked by Person A
3. Work on other components
4. When Person A checks in, see "Update Available"
5. Click Update to get the latest version
6. Check out and add interior details

**Person C** (project coordinator):
1. Open main model
2. Click Reload All to get latest versions
3. Review the work
4. Export or continue modeling

### Multi-File Project Workflow

**Project Structure**:
```
MyProject/
├── Main_Model.skp
├── Components/
│   ├── Window_Type_A.skp
│   ├── Door_Type_B.skp
│   └── Furniture_Set.skp
└── Buildings/
    ├── Building_North.skp
    └── Building_South.skp
```

**Setup**:
1. Save the main model first
2. Import components as XRefs using relative paths
3. Team members can check out individual components
4. Move the entire "MyProject" folder without breaking links

## Nested XRefs & Travel-Through Mode

The plugin supports **Nested XRefs** (XRefs inside other XRefs). This allows you to build complex hierarchies, like:
`Building.skp` -> contains `Floor.skp` -> contains `Room.skp` -> contains `Furniture.skp`

To edit a deeply nested component (e.g., `Furniture.skp`) while inside `Building.skp`, you must "pass through" the intermediate XRefs (`Floor` and `Room`).

### How it Works

1.  **Navigation**: When you double-click to enter a Parent XRef that contains nested XRefs, you are entering **Travel-Through Mode**.
2.  **Permission**: The plugin recognizes you are just "traveling through" to reach a child. It allows you to enter the Parent *without* checking it out.
3.  **Editing**: You cannot edit the Parent itself in this mode. You can only navigate down to the Child XRef you want to edit.
4.  **Checkout**: When you reach the target Child XRef and enter it, you will be prompted to Check Out normally.

### Enabling Travel-Through

If a Parent XRef is locked (by you or someone else), you can explicitly **enable Travel-Through mode**:

1.  Open XRef Manager.
2.  Find the locked Parent XRef.
3.  Click the **Enable Travel-Through** button (arrow icon).
4.  You can now double-click into that Parent to reach its children.

### Do's and Don'ts

- **DO** use Travel-Through to make quick edits to deep components without disrupting the main assembly.
- **DO** disable Travel-Through mode when you are finished navigating.
- **DON'T** try to save the Parent XRef while Travel-Through is active. Saving is blocked to prevent accidental overwrites of the parent structure.
- **DON'T** force unlock a Parent just to edit a Child. Use Travel-Through instead.

## Context Menu (Right-Click)

Right-click on XRef component instances for quick access:

- **Check Out XRef** (or **Check Out (Read-Only)** if locked by another user)
- **Save & Check In XRef**
- **Cancel Read-Only Checkout** (if in read-only mode)
- **Reload XRef**
- **Unload XRef**
- **Unlink XRef**
- **Claim for this session...** (if status is "Checked Out (You, elsewhere)" and you want to assign the lock to this window)
- **Force Check In...** (if checked out by you in another session)
- **Force Unlock...** (if locked by another user)
- **Select All Instances**

**Note**: Force operations (Force Check-In and Force Unlock) are only available in the context menu to prevent accidental use.

## Background Monitoring

The plugin automatically monitors for changes:

- Checks lock status every few seconds
- Notifies you if someone else checks out a file
- Alerts you when updates are available
- Warns before closing if you have uncommitted changes

### Pausing Monitoring

To improve performance, you can temporarily pause background monitoring:

**From the XRef Manager Dialog**:
1. Click the **Pause Monitoring** button in the header
2. The button changes to **Resume Monitoring** and turns yellow
3. Background checks are suspended until you resume
4. Click **Resume Monitoring** to re-enable automatic checking

**From the Toolbar**:
1. Click the **Pause/Resume Monitoring** toolbar button
2. The button shows a checkmark when monitoring is paused
3. Click again to toggle back to active monitoring

**From the Menu**:
- **Extensions → Open XRef Manager → Pause/Resume Monitoring**

**When to pause:**
- Working on complex models where performance is critical
- Making many local edits without needing real-time status updates
- When XRef files are on slow network drives

**Note:** You can still manually refresh by clicking the refresh button, and all XRef operations (check out, check in, etc.) work normally while paused.

## Troubleshooting

### "File Not Found" Error

**Causes**:
- File was moved or deleted
- Relative path used but main model moved
- Network drive disconnected

**Solutions**:
- Use the **Relink** button to point to the new location
- Restore the file to its original location
- Switch to absolute paths if moving files frequently

### Cannot Check Out (File Already Locked)

**Causes**:
- Another user has it checked out
- You have it checked out in another model
- Stale lock file from crashed session
- False "Checked Out (You, elsewhere)" after Save As

**Solutions**:
- Wait for the other user to check in
- Use **Claim for this session** (in manager or context menu) if the status is wrong and you're not using it elsewhere
- Use **Force Check-In** if locked by you elsewhere
- Use **Force Unlock** if you're certain no one is working on it
- Manually delete the `.lock` file

### Changes Not Appearing After Update

**Causes**:
- Wrong definition updated (SketchUp creates duplicates like "Box#1")
- Components in nested groups not updating
- Undo history interfering

**Solutions**:
- Use **Reload** instead of Update
- Check for duplicate definitions (same name with #1, #2, etc.)
- Try closing and reopening the model

### Relative Paths Not Working

**Causes**:
- Main model not saved
- Files on different drives
- Incorrect relative path syntax

**Solutions**:
- Save the main model first
- Use absolute paths for cross-drive references
- Use the **Toggle Path Type** button instead of manual editing

### Lock Files Not Releasing

**Causes**:
- SketchUp crashed before check-in
- File system error
- Lock file permissions issue

**Solutions**:
- Manually delete the `.lock` file
- Use **Force Unlock** from another user's session
- Check file permissions on the shared folder

### Cannot Check Out XRef / Changes Not Saving

**Causes**:
- Auto-checkout setting is disabled
- XRef not checked out before editing
- Working without checking out (edit without lock)
- Network drive or file permissions issue

**Solutions**:
- Check if auto-checkout is enabled in **Settings** dialog
- Manually check out the XRef from the XRef Manager before editing
- Verify the lock file was created in the XRef file's folder
- Check file permissions on the shared folder
- Make sure the XRef file path is accessible

## Technical Details

### Attributes Dictionary

XRef data is stored in the component definition's attributes:

- **Dictionary Name**: `OpenXrefManager::Xref`
- **Keys**:
  - `path` - File path (absolute or relative)
  - `path_type` - "absolute" or "relative"
  - `timestamp` - Last known modification time
  - `is_unloaded` - Boolean, true if unloaded
  - `edited_without_lock` - Boolean, tracks unauthorized edits
  - `readonly_checkout` - Boolean, true if checked out in read-only mode
  - `readonly_modified` - Boolean, true if read-only checkout has been modified locally
  - `last_publisher_name` - Username who last saved
  - `last_publisher_model` - Model name used for last publish
  - `last_publisher_path` - Full path of model used for last publish

### Settings Dictionary

XRef Manager settings are stored in the model's attributes:

- **Dictionary Name**: `OpenXrefManager::Settings`
- **Keys**:
  - `auto_checkout_on_edit` - Boolean, true if XRefs should prompt for checkout when entering edit mode (default: true)

### Application Settings

Application-level settings are stored in SketchUp's defaults (registry/preferences):

- **Keys**:
  - `CheckIntervalSeconds` - Float, background check interval in seconds (default: 2.0, range: 1.0-60.0)

### Lock File Details

Lock files are plain text files with `.lock` extension:
- **Location**: Same folder as the XRef file
- **Name**: `[filename].skp.lock`
- **Format**: `username|model_guid|model_name|model_path`
- **Example**: `JohnDoe|a1b2c3d4-e5f6|Main_Building.skp|C:\Projects\Main_Building.skp`

### Model GUID

SketchUp assigns a unique GUID to each model file. This GUID:
- Changes when "Save As" is used with a new name
- Identifies which specific model file has a lock
- Prevents conflicts when the same user works in multiple sessions

### File Monitoring

The plugin uses:
- File modification timestamps (mtime)
- SketchUp observers for model events
- Periodic background checks (configurable interval, default: every 2 seconds)
- Cached status to minimize file system calls
- Optimized batched file operations to reduce I/O overhead
- Automatic skipping of unloaded XRefs during monitoring

**Performance Optimizations**:
- Only checks XRefs that are loaded (unloaded XRefs are skipped)
- Batches all file system operations together
- Only updates UI when dialog is visible
- Only locks/unlocks instances that changed state
- Skips update checks for XRefs locked by others

**Performance Note**: You can adjust the check interval in Settings to balance responsiveness vs. performance. Increasing the interval reduces background overhead.

## Best Practices

1. **Always set your user name** before checking out files
2. **Configure settings** to match your workflow preferences
3. **Save your main model** before using relative paths
4. **Check in frequently** to let others access files
5. **Communicate with your team** before using Force operations
6. **Use relative paths** for portable project folders
7. **Keep XRef files organized** in dedicated folders
8. **Reload before editing** to ensure you have the latest version
9. **Don't manually edit** `.lock` files
10. **Use descriptive component names** for easy identification
11. **Regularly purge unused XRefs** to keep models clean
12. **Consider disabling auto-checkout** if you want full manual control over when XRefs are checked out
13. **Pause monitoring** when working on performance-intensive tasks to reduce background overhead
14. **Unload XRefs** you're not currently working with to improve model performance
15. **Increase check interval** (to 5-10 seconds) if working with network drives or experiencing performance issues

### Visibility Best Practices

- **Treat the XRef file as authoritative geometry**: Hides inside the XRef are structural changes that affect all users.
- **Use tags and scenes for per-model control**: Drive user-specific visibility from tags and scenes in each host model, and agree on a tagging convention for optional or switchable parts.
- **Keep temporary hides local**: When you just need temporary/local hides, use read-only checkout or editing without a lock so those changes are not published back to the XRef file.

## Keyboard Shortcuts

While no default keyboard shortcuts are assigned, you can:
- Assign shortcuts in SketchUp's Preferences → Shortcuts
- Search for "Open XRef Manager" to find available commands

## Support

For issues, questions, or feature requests:
- Check the Troubleshooting section above
- Review the Google Docs manual: [Link](https://docs.google.com/document/d/1jq8i3zdtioXvFJmHIqxaETtVXBYXxwEnKzqkOMh_YZM/edit?tab=t.0)
- Contact the plugin developer

## License

See LICENSE file for details.

## Version History

### Version 1.8.5
**UI Improvements:**
- Compact dialog layout with 12px base font size and reduced paddings throughout
- Smaller action button icons (16px) and tighter button gaps for a denser table view
- Reduced dialog default size and minimum height for better screen utilisation
- File dialogs for opening/saving XRef files now default to the last used folder
- "Last Commit" column now shows the live file modification time instead of the stored sync timestamp

### Version 1.8.4
**Best Practices:**
- Documented recommended patterns for treating the XRef file as authoritative geometry, using tags/scenes for per-model visibility, and keeping temporary hides local via read-only or non-locked editing.

### Version 1.8.3
**Fixed:**
- **False "Checked Out (You, elsewhere)"** — XRefs could show this status incorrectly after Save As or when the lock file was from an unsaved model. The plugin now auto-claims when the stored lock path is empty, and you can use **Claim for this session** (icon in Status column or context menu) to assign the lock to this window. Force Check In also claims the lock first so the status stays correct.

**Added:**
- **Claim for this session** — For "Checked Out (You, elsewhere)", a confirmation dialog then updates the lock file to this model so you can Save & Check In normally. Only use when you are not using the XRef in another window.

### Version 1.8.2
**Added:**
- **Create XRef from Group** — Right-click a group → **Open XRef Manager** → **Create XRef from this Group...**. The group is converted to a component in-place and linked as an XRef (same flow as components). The Extensions menu and manager button are now labeled **Create XRef from Component or Group...**.

### Version 1.8.1
**Bug Fixes:**
- **Read-only checkout: XRef stayed locked** — Fixed a bug where the XRef instances were re-locked immediately after read-only checkout. The entities observer now respects read-only checkout, so instances stay unlocked and you can edit locally as intended.

### Version 1.8.0
**Added:**
- **Store position when creating XRef** — When converting a component (or group) to an XRef, you can store its position relative to current axes or global origin. The position is saved in the XRef file for accurate placement when loading.
- **Apply stored position on Import at Origin** — When loading an XRef via **Import at Origin**, you choose: **Yes** = place using stored position relative to current construction axes; **No** = place using stored position in world space (or at origin if none stored). XRefs without stored position behave as before.

### Version 1.7.0
**Read-Only Checkout Feature:**
- **Read-Only Checkout**: New mode allowing users to check out XRefs that are locked by others. Enables local editing without the ability to publish changes back to the external file.
- **Modification Tracking**: XRefs in read-only mode show "Read-Only Checkout (Modified)" status when locally modified, with an "Update Available" button to discard changes and revert to the published version.
- **Auto-Prompt**: When attempting to edit a locked XRef, users are automatically prompted to check it out in read-only mode.
- **Lock Release Notification**: Users are notified when the underlying lock file for a read-only checked-out XRef is released, indicating it's now available for full checkout.

**UI Improvements:**
- **Force Operations Moved**: "Force Check-In" and "Force Unlock" buttons moved from the main XRef Manager dialog to the context menu to prevent accidental use.
- **Read-Only Checkout Button**: New "Check Out (Read-Only)" button displayed in the main dialog when an XRef is locked by another user.
- **Cancel Button**: "Cancel Read-Only Checkout" button moved to the first action column for better visibility.
- **Column Width Adjustments**: Actions column width increased to 20% with 300px minimum width to accommodate all action buttons without scrolling.
- **CSS Improvements**: Updated table header styling and box-sizing for better visual consistency.

**Bug Fixes:**
- Fixed reload behavior to preserve read-only checkout state while clearing modification flags.
- Improved status display for read-only checkout scenarios.

### Version 1.6.0
**Major Stability Update:**
- **Nested XRefs**: Full support for editing nested XRef components.
- **Travel-Through Mode**: New mode to navigate through locked parent XRefs to edit children.
- **Recursive Updates**: Fixed infinite loop when updating nested components.
- **Relink Dialog**: Now prefills the current filename for easier replacement.
- **Bug Fixes**: Critical fixes for nested locking, permission persistence, and UI stability.

### Version 1.5.0
**New Features:**
- Auto-checkout setting to control automatic checkout prompts when entering XRefs
- Configurable background check interval (1-60 seconds) for performance tuning
- Pause/Resume monitoring button in dialog, toolbar, and menu
- "Keep locked after publish" checkbox now remembers its state

**UI Improvements:**
- Changed "Last Modified" to "Last Commit" for clarity
- Added "Last Commit" timestamp to status tooltips
- Disabled Check Out and Update buttons when XRef is unloaded
- Renamed "Purge Unused" to "Purge Removed Xref's"

**Bug Fixes:**
- Fixed Force Check-In to properly unlock XRef instances
- Fixed imported XRefs incorrectly showing "Update Available"

**Performance Optimizations:**
- Batch file operations to reduce I/O overhead by 60-70%
- Skip monitoring for unloaded XRefs
- Only refresh dialog when visible
- Lazy mtime checking (skip for locked-by-others)
- Optimized instance locking with early exits

**Other Changes:**
- Removed support for non-.skp file formats (IFC, DWG, DXF)
- Comprehensive README documentation update

---

**Made with ❤️ for the SketchUp community**
