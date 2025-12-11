# Changelog

## [1.6.1] - 2025-12-11

### Fixed
- **Save As Status Issue:** Fixed a bug where using "Save As" on the main model caused XRefs to report "Checked out (You, elsewhere)" due to lock files being associated with the old model GUID.
- **Newer Version Loading:** Added `allow_newer: true` to XRef loading to support importing and reloading components saved in newer SketchUp versions.

## [1.6.0] - 2025-12-07

### Fixed
- **Recursive Update Loop:** Fixed an issue where updating a nested XRef caused an infinite loop of "Update Available" notifications for the parent XRef. Updates are now decoupled.
- **Nested XRef Locking:** Resolved a critical bug where navigating into a nested XRef from a parent bypassed the lock check system, allowing unintended edits to locked files.
- **Travel-Through Stability:**
    - Permissions now persist correctly after saving the model (ID mismatch fix).
    - Permissions now persist after editing nested components (Definition ID mismatch fix).
    - Fixed a crash (`NilClass` error) when initializing travel-through state in certain nested contexts.
- **Auto-Checkout Prompt:** Fixed a "phantom lock" scenario where users were not prompted to check out nested XRefs when navigating in Travel-Through mode.
- **UI Visibility:** Fixed a logic trap where the "Travel-Through" toggle button disappeared if the parent file was unlocked, preventing users from disabling the mode.

### Changed
- **Relink Dialog:** The "Relink XRef" file dialog now correctly opens in the XRef's current directory with the filename pre-selected.
