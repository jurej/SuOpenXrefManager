require_relative "core"

module OpenXrefManager
  # --- Live Update Timer ---

  # Starts the background timer to check for changes in XRef lock files.
  def self.start_timer
    stop_timer # Ensure no duplicate timers
    interval = get_check_interval_setting
    @timer = UI.start_timer(interval, true) do
      check_for_status_changes
    end
  end

  # Stops the background timer.
  def self.stop_timer
    return unless @timer

    UI.stop_timer(@timer)
    @timer = nil
  end

  # Checks all XRefs for changes in their lock status and updates instance locks.
  def self.check_for_status_changes(show_notification: true)
    # Skip if monitoring is paused
    return if @monitoring_paused

    model = Sketchup.active_model
    return unless model&.valid?

    # Check if model GUID changed (e.g. Save As / Save Copy As)
    current_guid = model.guid
    if @last_model_guid && @last_model_guid != current_guid
      # GUID changed! Update our locks to point to the new GUID
      update_owned_lock_files(@last_model_guid, current_guid)
    end
    @last_model_guid = current_guid

    something_changed = false
    xref_definitions = get_xref_definitions

    # Early exit if no XRefs
    return if xref_definitions.empty?

    # OPTIMIZATION 1: Build a map of all XRef paths to batch file operations
    xref_paths = {}
    xref_definitions.each do |definition|
      # Skip unloaded XRefs - they don't need monitoring
      is_unloaded = definition.get_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
      next if is_unloaded

      path = resolve_xref_path(definition)
      xref_paths[definition.guid] = path if path
    end

    # OPTIMIZATION 2: Batch check all lock files at once
    lock_statuses = {}
    xref_paths.each do |guid, path|
      lock_path = "#{path}.lock"
      if File.exist?(lock_path)
        begin
          lock_statuses[guid] = File.read(lock_path).strip
        rescue StandardError
          lock_statuses[guid] = "unlocked"
        end
      else
        lock_statuses[guid] = "unlocked"
      end
    end

    # OPTIMIZATION 3: Batch check file mtimes at once (only for unlocked or mine)
    file_mtimes = {}
    xref_paths.each do |guid, path|
      file_mtimes[guid] = File.mtime(path).to_i if File.exist?(path)
    rescue StandardError
      # Skip files we can't access
    end

    # Now process each XRef with the batched data
    xref_definitions.each do |definition|
      # Skip unloaded XRefs
      is_unloaded = definition.get_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
      next if is_unloaded

      current_lock_content = lock_statuses[definition.guid] || "unlocked"

      # OPTIMIZATION 4: Lazy mtime checking - only check if not locked by others
      is_locked_by_file = current_lock_content != "unlocked"
      is_mine_in_this_window = false

      if is_locked_by_file
        lock_owner_name, lock_owner_guid, = current_lock_content.split("|")
        is_mine_in_this_window = lock_owner_name == @user_name && lock_owner_guid == model.guid
      end

      # Only check for updates if it's not locked by someone else (saves mtime checks)
      current_update_available = false
      if !is_locked_by_file || is_mine_in_this_window
        stored_timestamp = definition.get_attribute(XREF_DICT_NAME, XREF_TIMESTAMP_KEY)
        if stored_timestamp.nil?
          current_update_available = true
        elsif file_mtimes[definition.guid]
          current_update_available = (file_mtimes[definition.guid] > stored_timestamp)
        end
      end

      last_status = @last_xref_statuses[definition.guid]

      # Check if readonly checkout exists
      is_readonly = is_readonly_checkout?(definition)

      # Check if lock was released while readonly checkout exists
      lock_was_released = false
      if is_readonly && last_status && last_status[:lock_content] != "unlocked" && current_lock_content == "unlocked"
        lock_was_released = true
      end

      # Check if status changed
      next unless last_status.nil? ||
                  last_status[:lock_content] != current_lock_content ||
                  last_status[:update_available] != current_update_available

      something_changed = true
      @last_xref_statuses[definition.guid] =
        { lock_content: current_lock_content, update_available: current_update_available }

      # Notify if lock was released while readonly checkout exists
      if lock_was_released && show_notification
        UI.start_timer(0.1, false) do
          message = "The file '#{definition.name}' is now unlocked.\n\n"
          message += "You have this XRef in read-only checkout mode. "
          message += "You can now check it out normally to publish your changes."
          UI.messagebox(message)
        end
      end

      # We should lock instances if:
      # 1. It is locked by someone else (or us in another window)
      # 2. OR an update is available (force user to update before editing)
      # BUT: Don't lock if travel-through mode is enabled (allows entry to nested XRefs)
      # BUT: Don't lock if readonly checkout is active (allows editing)
      should_be_locked = ((is_locked_by_file && !is_mine_in_this_window) || current_update_available) && !is_travel_through_enabled?(definition) && !is_readonly

      lock_or_unlock_instances_for_definition(definition, should_be_locked)
    end

    # OPTIMIZATION 5: Only refresh dialog if it's actually visible
    return unless something_changed && @dialog&.visible?

    refresh_dialog_data
  end
end
