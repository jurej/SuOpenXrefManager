# Unload Button Investigation

## Issue Report
User reports: "the ui button 'unload' which currently does not seem to do anything"

## Investigation Results

### 1. UI Button Configuration (manager.html:252)
```javascript
loadButton = `<button class="btn btn-sm" title="Unload XRef"
              onclick="handleUnloadClick('${xref.name}')">
              <i class="material-icons">visibility_off</i></button>`;
```

**ISSUE #1: Missing Color Class**
- Unload button: `class="btn btn-sm"` (NO color class)
- Other buttons have: `btn-info`, `btn-primary`, `btn-danger`, etc.
- This may make the button appear faded/disabled or hard to see

### 2. JavaScript Handler (manager.html:274-277)
```javascript
function handleUnloadClick(name) {
  if (confirm(`Are you sure you want to unload "${name}"?...`)) {
    if (sketchup) { sketchup.unload_single_clicked(name); }
  }
}
```
Status: ✓ Correct

### 3. Ruby Callback Registration (ui_manager.rb:195)
```ruby
Core.dialog.add_action_callback("unload_single_clicked") { |ctx, name|
  XrefOperations.unload_single_xref(name);
  self.check_for_status_changes(show_notification: false);
  self.refresh_dialog_data
}
```
Status: ✓ Correct - includes status check and refresh

### 4. Unload Operation (xref_operations.rb:301-331)
```ruby
def self.unload_single_xref(component_name)
  model = Sketchup.active_model
  definition = model.definitions.find { |d| d.name == component_name }
  return unless definition  # EARLY RETURN if not found

  # Remove lock if owned by current user
  lock_content = FileOperations.get_xref_lock_status(definition)
  if lock_content != "unlocked"
    lock_owner_name, lock_owner_guid, _, _ = lock_content.split('|')
    if lock_owner_name == Core.user_name && lock_owner_guid == model.guid
      lock_path = FileOperations.resolve_xref_path(definition)
      lock_path += ".lock" if lock_path
      File.delete(lock_path) if lock_path && File.exist?(lock_path)
      Core.last_xref_statuses[definition.guid] = "unlocked"
    end
  end

  model.start_operation("Unload XRef", true)
  definition.entities.to_a.each { |e| e.erase! if e.valid? }
  placeholder_group = definition.entities.add_group
  placeholder_text = placeholder_group.definition.entities.add_text("XREF_PLACEHOLDER", [0,0,0])
  placeholder_text.hidden = true
  placeholder_group.hidden = true
  definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_UNLOADED_KEY, true)
  model.commit_operation

  # NO explicit refresh here - relies on callback
end
```

**POTENTIAL ISSUE #2: No Explicit Refresh in Method**
- Original code had `self.check_for_status_changes(show_notification: false)` at the end
- Refactored code relies on callback to do this
- Should work, but if callback fails to execute, UI won't update

### 5. Comparison with Original Code
Original (backup):
```ruby
def self.unload_single_xref(component_name)
  # ... same logic ...
  model.commit_operation

  # Refresh the UI
  self.check_for_status_changes(show_notification: false)  # <-- THIS WAS HERE
end
```

Refactored:
```ruby
def self.unload_single_xref(component_name)
  # ... same logic ...
  model.commit_operation
  # NO refresh here
end
```

Callback handles refresh:
```ruby
XrefOperations.unload_single_xref(name);
self.check_for_status_changes(...);  # <-- MOVED HERE
self.refresh_dialog_data
```

## Potential Root Causes

### Theory #1: Button Not Visible (STYLING)
The button lacks a color class, making it blend with the background or appear disabled.

**Fix**: Add `btn-info` or `btn-secondary` class to the unload button

### Theory #2: Operation Fails Silently
The method returns early (line 304: `return unless definition`) if definition not found.
No error message shown to user.

**Fix**: Add error handling with user notification

### Theory #3: UI Doesn't Refresh
If the callback chain is broken or the method throws an exception after commit,
the UI won't reflect the change.

**Fix**: Ensure robust error handling and always call refresh

## Recommended Fixes

### Fix #1: Add Button Styling (CRITICAL)
```javascript
// Line 252 in manager.html
loadButton = `<button class="btn btn-info btn-sm" title="Unload XRef"
              onclick="handleUnloadClick('${xref.name}')">
              <i class="material-icons">visibility_off</i></button>`;
```

### Fix #2: Add Button Styling for Load Button Too
```javascript
// Line 250 in manager.html
loadButton = `<button class="btn btn-info btn-sm" title="Load XRef"
              onclick="sketchup.reload_single_clicked('${xref.name}')">
              <i class="material-icons">sync</i></button>`;
```

### Fix #3: Add Error Handling in Unload Method
```ruby
def self.unload_single_xref(component_name)
  model = Sketchup.active_model
  definition = model.definitions.find { |d| d.name == component_name }

  unless definition
    UI.messagebox("Cannot find XRef component '#{component_name}'")
    return false
  end

  # ... rest of method ...

  return true  # Success indicator
end
```

### Fix #4: Restore Explicit Refresh in Method (SAFEST)
```ruby
def self.unload_single_xref(component_name)
  # ... existing code ...
  model.commit_operation

  # Explicit refresh to ensure UI updates even if callback fails
  UIManager.check_for_status_changes(show_notification: false)
  UIManager.refresh_dialog_data

  return true
end
```

## Test Plan

1. Create a test XRef
2. Click Unload button
3. Verify:
   - Button is visible and clickable
   - Confirmation dialog appears
   - After confirming, geometry disappears from model
   - UI shows "Unloaded" status
   - Load button appears in place of Unload button
4. Click Load button
5. Verify geometry reappears and status returns to normal

## Conclusion

Most likely cause: **Button styling issue** - the unload button is missing a color class making it hard to see/click.

Secondary issue: Refactored code relies on callback for UI refresh instead of explicit call in method.

**Priority: HIGH** - This breaks a core feature of the plugin.
