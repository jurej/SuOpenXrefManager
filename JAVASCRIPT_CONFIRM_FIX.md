# JavaScript Confirm Dialog Fix

## Root Cause Identified

The **actual issue** with the Unload button (and other confirmation dialogs) was that JavaScript `confirm()` dialogs in SketchUp's `HtmlDialog` **are unreliable**:

- They often don't appear at all
- They only work when browser DevTools are open
- They can be silently blocked by SketchUp's CEF (Chromium Embedded Framework)

This is a well-known limitation of SketchUp's HtmlDialog implementation.

## Solution

**Move all confirmation dialogs from JavaScript to Ruby**, where `UI.messagebox` is reliable and always works correctly in SketchUp.

## Changes Made

### 1. JavaScript Side (manager.html)

**Removed all `confirm()` calls** from these handlers:
- `handleUnlinkClick()` - Line 268-271
- `handleUnloadClick()` - Line 273-276
- `handleForceUnlockClick()` - Line 278-281
- `purgeButton.onclick` - Line 285-288

**Before:**
```javascript
function handleUnloadClick(name) {
  if (confirm(`Are you sure you want to unload "${name}"?...`)) {
    if (sketchup) { sketchup.unload_single_clicked(name); }
  }
}
```

**After:**
```javascript
function handleUnloadClick(name) {
  // Confirmation handled in Ruby for reliability
  if (sketchup) { sketchup.unload_single_clicked(name); }
}
```

### 2. Ruby Side (modules/xref_operations.rb)

**Added confirmation dialogs** to these methods:
- `purge_unused_xrefs()` - Lines 30-34
- `force_unlock_xref()` - Lines 184-189
- `unlink_single_xref()` - Lines 292-295
- `unload_single_xref()` - Lines 315-320

**Example implementation:**
```ruby
def self.unload_single_xref(component_name)
  # ... validation code ...

  # Confirmation dialog (moved from JavaScript for reliability)
  question = "Are you sure you want to unload '#{component_name}'?\n\n" +
             "This will remove it from the model to improve performance but keep the link so you can load it back at any time.\n\n" +
             "Any uncommitted changes will be lost."
  result = UI.messagebox(question, Core::MB_YESNO)
  return false unless result == Core::IDYES

  # ... proceed with operation ...
end
```

## Benefits

1. **Reliability**: Ruby's `UI.messagebox` always works in SketchUp
2. **Consistency**: Native SketchUp dialogs match the application's UI
3. **No DevTools Dependency**: Works whether DevTools are open or not
4. **Better User Experience**: Dialogs appear reliably every time
5. **Proper Integration**: Uses SketchUp's modal dialog system correctly

## Technical Details

### Why JavaScript confirm() Fails in SketchUp

SketchUp uses CEF (Chromium Embedded Framework) for HtmlDialog. CEF can block JavaScript modal dialogs (`alert`, `confirm`, `prompt`) because:
1. They can cause deadlocks in embedded browser contexts
2. CEF prioritizes the host application's message loop
3. Modal JS dialogs can conflict with native UI operations

### Why Ruby UI.messagebox Works

Ruby's `UI.messagebox` uses native SketchUp API:
1. Creates true OS-level modal dialogs
2. Properly integrates with SketchUp's event loop
3. No browser security restrictions
4. Consistent behavior across all platforms (Windows/Mac)

## Testing

Test each confirmation dialog:

1. **Unload**: Click unload button → Should show Ruby dialog immediately
2. **Unlink**: Click unlink button → Should show Ruby dialog immediately
3. **Force Unlock**: Click force unlock button → Should show Ruby dialog immediately
4. **Purge Unused**: Click purge button → Should show Ruby dialog immediately

All dialogs should:
- ✓ Appear instantly (no delays)
- ✓ Work with or without DevTools open
- ✓ Use native SketchUp dialog styling
- ✓ Properly block until user responds
- ✓ Respect user's Yes/No choice

## Files Modified

1. **OpenXrefManager/manager.html**
   - Removed 4 JavaScript `confirm()` calls
   - Added comments explaining Ruby handles confirmation

2. **OpenXrefManager/modules/xref_operations.rb**
   - Added 4 Ruby `UI.messagebox` confirmation dialogs
   - All use `Core::MB_YESNO` and check for `Core::IDYES`

## Verification

```bash
ruby -c OpenXrefManager/modules/xref_operations.rb
# Syntax OK
```

## Related Issues Fixed

This also fixes the "typo" in the JavaScript message: `ucommited` → `uncommitted` (fixed in Ruby version at line 318)

## Best Practice for SketchUp Plugins

**Always use Ruby for user confirmations in SketchUp plugins:**
- ✓ Use: `UI.messagebox(question, MB_YESNO)`
- ✗ Avoid: JavaScript `confirm()`, `alert()`, `prompt()`

This is now documented in the codebase to prevent future regressions.
