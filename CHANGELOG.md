# Changelog

## [1.8.0] - 2026-02-17

### Added
- **Create XRef from component: store position relative to origin** — When converting a component to an XRef, you can optionally store its position for spatial reconstruction:
  - **Relative to current axes:** Stores transform relative to the current construction axes (saved in the XRef file).
  - **Relative to global origin:** Stores the global transformation (saved in the XRef file).
  - Stored data uses `origin_transform` and `origin_type` on the definition for future load/placement support.

## [1.7.0] - 2026-01-22

### Added
- **Read-Only Checkout:** New feature allowing users to check out XRefs even when locked by others, enabling local editing while preventing publishing. Changes are saved locally but cannot be published to the file until the lock is released.
  - Auto-prompt when entering locked XRefs offers read-only checkout option
  - Clear UI indicators show read-only checkout status
  - Publishing is blocked for read-only checkouts with informative messages
  - Context menu options for read-only checkout and cancellation
  - Status monitoring notifies when lock is released while read-only checkout exists

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
