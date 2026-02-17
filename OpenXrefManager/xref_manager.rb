require_relative "core"

module OpenXrefManager
  # --- Core Xref Functions ---

  # Resolves the full, absolute path for an XRef definition, accounting for relative paths.
  def self.resolve_xref_path(definition)
    return nil unless definition

    path = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY)
    return nil unless path

    path_type = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")

    return path unless path_type == "relative"

    model_path = definition.model.path
    if model_path.nil? || model_path.empty?
      # Cannot resolve relative path if model is unsaved
      return nil
    end

    model_dir = File.dirname(model_path)
    begin
      File.expand_path(path, model_dir)
    rescue StandardError
      nil
    end
  end

  # Returns an array of all component definitions in the active model that are marked as XRefs.
  def self.get_xref_definitions
    model = Sketchup.active_model
    return [] unless model

    model.definitions.select { |d| is_xref?(d) }
  end

  # Checks if a given definition is an XRef by looking for the attribute dictionary.
  def self.is_xref?(definition)
    return false unless definition
    return false if definition.deleted?

    !definition.attribute_dictionary(XREF_DICT_NAME).nil?
  end

  # Recursively finds all XRef definitions nested inside a given definition.
  # @param definition [Sketchup::ComponentDefinition] The definition to search
  # @return [Array<Sketchup::ComponentDefinition>] Array of nested XRef definitions
  def self.find_nested_xrefs(definition)
    return [] unless definition&.valid?

    nested = []

    definition.entities.each do |entity|
      if entity.is_a?(Sketchup::ComponentInstance)
        child_def = entity.definition
        nested << child_def if is_xref?(child_def)
        # Recursively check nested components
        nested.concat(find_nested_xrefs(child_def))
      elsif entity.is_a?(Sketchup::Group)
        # Groups can contain components too - check the group's entities
        entity.entities.each do |group_entity|
          next unless group_entity.is_a?(Sketchup::ComponentInstance)

          child_def = group_entity.definition
          nested << child_def if is_xref?(child_def)
          nested.concat(find_nested_xrefs(child_def))
        end
      end
    end

    nested.uniq
  end

  # Finds all XRef definitions that contain the given child definition.
  # @param child_definition [Sketchup::ComponentDefinition] The child XRef to find parents for
  # @return [Array<Sketchup::ComponentDefinition>] Array of parent XRef definitions
  def self.find_parent_xrefs_containing(child_definition)
    return [] unless child_definition&.valid?
    return [] unless is_xref?(child_definition)

    model = child_definition.model
    return [] unless model

    parent_xrefs = []

    # Check all XRef definitions in the model
    get_xref_definitions.each do |parent_def|
      next if parent_def == child_definition

      # Check if this parent contains the child
      nested_xrefs = find_nested_xrefs(parent_def)
      parent_xrefs << parent_def if nested_xrefs.include?(child_definition)
    end

    parent_xrefs
  end

  # Checks if a given XRef definition has a newer version available on disk.
  def self._is_update_available?(definition)
    path = resolve_xref_path(definition)
    return false unless path && File.exist?(path)

    stored_timestamp = definition.get_attribute(XREF_DICT_NAME, XREF_TIMESTAMP_KEY)
    return true if stored_timestamp.nil? # If no timestamp, assume update needed (or just missing data)

    current_file_timestamp = File.mtime(path).to_i

    # If file on disk is newer than stored timestamp, update is available.
    return true if current_file_timestamp > stored_timestamp

    false
  end

  # Reads the lock file for a given XRef and returns its content (owner|guid).
  # Returns "unlocked" if no lock file exists.
  def self.get_xref_lock_status(definition)
    path = resolve_xref_path(definition)
    return "unlocked" unless path

    lock_path = "#{path}.lock"
    return "unlocked" unless File.exist?(lock_path)

    begin
      File.read(lock_path).strip
    rescue StandardError
      "unlocked" # Treat read errors as unlocked (or handle differently?)
    end
  end

  # Locks or unlocks all instances of a given definition.
  def self.lock_or_unlock_instances_for_definition(definition, should_be_locked)
    # OPTIMIZATION: Use to_a to avoid iterator invalidation and batch the operation
    instances = definition.instances.to_a
    return if instances.empty? # Early exit if no instances

    # Only update instances that need changing
    instances_to_update = instances.select { |inst| inst.valid? && inst.locked? != should_be_locked }
    return if instances_to_update.empty? # Early exit if nothing to change

    # Batch update all at once
    instances_to_update.each do |instance|
      instance.locked = should_be_locked
    end
  end

  # Helper to update the modification timestamp for an XRef.
  def self._update_xref_timestamp(definition)
    path = resolve_xref_path(definition)
    return unless path && File.exist?(path)

    definition.set_attribute(XREF_DICT_NAME, XREF_TIMESTAMP_KEY, File.mtime(path).to_i)
  end

  # Helper method to check if the user has any XRefs checked out.
  def self.has_uncommitted_changes?
    model = Sketchup.active_model
    return false unless model

    current_guid = model.guid

    get_xref_definitions.any? do |definition|
      lock_content = get_xref_lock_status(definition)
      next false if lock_content == "unlocked"

      lock_owner_name, lock_owner_guid = lock_content.split("|")
      lock_owner_name == @user_name && lock_owner_guid == current_guid
    end
  end

  # Helper method to check if a specific XRef has uncommitted changes (is checked out by current user in this model).
  def self.xref_has_uncommitted_changes?(definition)
    model = Sketchup.active_model
    current_guid = model.guid
    lock_content = get_xref_lock_status(definition)
    return false if lock_content == "unlocked"

    lock_owner_name, lock_owner_guid = lock_content.split("|")
    lock_owner_name == @user_name && lock_owner_guid == current_guid
  end

  # Toggles an XRef's path between absolute and relative.
  def self.toggle_path_type(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    current_type = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")
    current_path = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY)

    if current_type == "absolute"
      # Convert to relative
      model_path = model.path
      if model_path.nil? || model_path.empty?
        UI.messagebox("Please save the main model first to use relative paths.")
        return
      end

      model_dir = File.dirname(model_path)
      begin
        require "pathname"
        abs_path = Pathname.new(current_path)
        base_path = Pathname.new(model_dir)
        rel_path = abs_path.relative_path_from(base_path).to_s

        definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, rel_path)
        definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "relative")
      rescue StandardError => e
        UI.messagebox("Could not create relative path: #{e.message}")
      end
    else
      # Convert to absolute
      abs_path = resolve_xref_path(definition)
      if abs_path
        definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, abs_path)
        definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")
      else
        UI.messagebox("Could not resolve absolute path.")
      end
    end
    refresh_dialog_data
  end

  # Allows the user to select a new file path for an existing XRef.
  def self.relink_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    # Prevent relink if travel-through mode is enabled
    if is_travel_through_enabled?(definition)
      UI.messagebox("Cannot relink: Travel-through mode is active for '#{component_name}'. Disable travel-through mode first.\n\nRelinking would reload the XRef and break the travel-through workflow.")
      return
    end

    current_path = resolve_xref_path(definition)
    directory = ""
    filename = "SketchUp Files|*.skp||" # Default filter if no path

    if current_path
      # Standardize to backslashes for Windows UI consistency
      sys_path = current_path.gsub("/", "\\")
      directory = File.dirname(sys_path)
      name = File.basename(sys_path)
      # Use the specific filename if we have one
      filename = name unless name.empty?
    end

    path = UI.openpanel("Relink XRef File", directory, filename)
    return unless path

    # Update path
    _set_xref_path(definition, path, ask_user: true)

    # Update timestamp
    _update_xref_timestamp(definition)

    # Check if the new file is valid and reload it
    if File.exist?(path)
      reload_single_xref_without_warning(component_name)
    else
      UI.messagebox("The selected file does not exist.")
    end

    refresh_dialog_data
  end

  # Internal helper to set the path attribute, with an option to ask the user about relative paths.
  def self._set_xref_path(definition, absolute_path, ask_user: true)
    model = definition.model
    model_path = model.path

    use_relative = false

    if ask_user && !model_path.nil? && !model_path.empty?
      # Check if on same drive/volume
      require "pathname"
      begin
        Pathname.new(absolute_path).relative_path_from(Pathname.new(File.dirname(model_path)))
        # If successful, it's possible to use relative path
        result = UI.messagebox(
          "Do you want to use a relative path for this XRef?\n(Best if you plan to move the project folder)", MB_YESNO
        )
        use_relative = (result == IDYES)
      rescue StandardError
        # Different drives, must use absolute
      end
    end

    if use_relative
      model_dir = File.dirname(model_path)
      rel_path = Pathname.new(absolute_path).relative_path_from(Pathname.new(model_dir)).to_s
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, rel_path)
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "relative")
    else
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, absolute_path)
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")
    end
  end

  # Deletes the .lock file for a given XRef.
  def self.force_unlock_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    # Prevent force unlock if travel-through mode is enabled
    if is_travel_through_enabled?(definition)
      UI.messagebox("Cannot force unlock: Travel-through mode is active for '#{component_name}'. Disable travel-through mode first.")
      return
    end

    # Check if readonly checkout exists - offer to upgrade to full checkout
    if is_readonly_checkout?(definition)
      message = "'#{component_name}' is in read-only checkout mode.\n\n"
      message += "The file is now unlocked. Would you like to check it out normally so you can publish changes?"
      result = UI.messagebox(message, MB_YESNO)
      clear_readonly_checkout(definition)
      if result == IDYES
        # Clear readonly checkout and check out normally
        check_out_xref(component_name, readonly: false)
      else
        # Just clear readonly checkout
        @last_xref_statuses[definition.guid] =
          { lock_content: "unlocked", update_available: _is_update_available?(definition) }
        refresh_dialog_data
      end
      return
    end

    path = resolve_xref_path(definition)
    return unless path

    lock_path = "#{path}.lock"
    if File.exist?(lock_path)
      begin
        File.delete(lock_path)
        @last_xref_statuses[definition.guid] =
          { lock_content: "unlocked", update_available: _is_update_available?(definition) }
      rescue StandardError => e
        UI.messagebox("Failed to delete lock file: #{e.message}")
      end
    end
    refresh_dialog_data
  end

  # Purges all unused XRefs from the model.
  def self.purge_unused_xrefs
    model = Sketchup.active_model
    unused_xrefs = get_xref_definitions.select { |d| d.instances.empty? }

    if unused_xrefs.empty?
      UI.messagebox("No unused XRefs found to purge.")
      return
    end

    model.start_operation("Purge Unused XRefs", true)
    purged_count = 0
    unused_xrefs.each do |definition|
      # Also remove any lock files associated with the purged XRef if we own them
      lock_content = get_xref_lock_status(definition)
      if lock_content != "unlocked"
        lock_owner_name, lock_owner_guid = lock_content.split("|")
        if lock_owner_name == @user_name && lock_owner_guid == model.guid
          path = resolve_xref_path(definition)
          lock_path = "#{path}.lock" if path
          File.delete(lock_path) if lock_path && File.exist?(lock_path)
        end
      end
      model.definitions.remove(definition)
      purged_count += 1
    end
    model.commit_operation
    UI.messagebox("Purged #{purged_count} unused XRef(s).")
    refresh_dialog_data
  end

  # Creates a .lock file for an XRef, marking it as "checked out" by the current user.
  # @param component_name [String] Name of the component
  # @param readonly [Boolean] If true, allows editing but prevents publishing (no lock file created)
  def self.check_out_xref(component_name, readonly: false)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    path = resolve_xref_path(definition)
    return unless path

    lock_path = "#{path}.lock"

    if readonly
      # Read-only checkout: no lock file, just set attribute
      model.start_operation("Check Out XRef (Read-Only)", true)
      begin
        # Get lock info to show who has it locked
        lock_content = get_xref_lock_status(definition)
        lock_owner_name = ""
        lock_owner_name, = lock_content.split("|") if lock_content != "unlocked"

        # Set readonly checkout flag
        definition.set_attribute(XREF_DICT_NAME, XREF_READONLY_CHECKOUT_KEY, true)
        # Initialize readonly modified flag to false
        definition.set_attribute(XREF_DICT_NAME, XREF_READONLY_MODIFIED_KEY, false)
        # Clear the edited_without_lock flag when checking out
        definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)

        # Update status cache (keep existing lock_content since we don't own the lock)
        @last_xref_statuses[definition.guid] = {
          lock_content: lock_content,
          update_available: _is_update_available?(definition),
          readonly_checkout: true,
        }

        # Always unlock instances when checking out
        lock_or_unlock_instances_for_definition(definition, false)

        # Show message explaining readonly status
        message = "XRef '#{component_name}' is now checked out in read-only mode.\n\n"
        message += "The file is locked by: #{lock_owner_name}\n\n" if lock_owner_name && !lock_owner_name.empty?
        message += "You can edit this XRef locally, but changes cannot be published to the file until the lock is released.\n\n"
        message += "Your changes will be saved in this model file."
        UI.messagebox(message)
      rescue StandardError => e
        UI.messagebox("Failed to check out XRef in read-only mode:\n#{e.message}")
      end
      model.commit_operation
    elsif File.exist?(path) && !File.exist?(lock_path)
      # Normal checkout: create lock file
      model.start_operation("Check Out XRef", true)
      begin
        model_path = model.path
        model_name = model_path.nil? || model_path.empty? ? "Untitled Model" : File.basename(model_path)
        model_path_str = model_path.nil? ? "" : model_path # Get the full path as a string
        lock_content = "#{@user_name}|#{model.guid}|#{model_name}|#{model_path_str}"

        File.write(lock_path, lock_content)
        # Clear readonly checkout flag if it exists
        clear_readonly_checkout(definition)
        # Clear the edited_without_lock flag when checking out
        definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)
        @last_xref_statuses[definition.guid] =
          { lock_content: lock_content, update_available: _is_update_available?(definition) }
        # Always unlock instances when checking out
        lock_or_unlock_instances_for_definition(definition, false)
      rescue StandardError => e
        UI.messagebox("Failed to create lock file:\n#{e.message}")
      end
      model.commit_operation
    else
      UI.beep # Can't check out if file doesn't exist or is already locked
    end
    refresh_dialog_data
  end

  # Checks out an XRef in read-only mode (allows editing but prevents publishing).
  # @param component_name [String] Name of the component
  def self.check_out_xref_readonly(component_name)
    check_out_xref(component_name, readonly: true)
  end

  # Cancels a read-only checkout, removing the readonly flag.
  # @param component_name [String] Name of the component
  def self.cancel_readonly_checkout(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    unless is_readonly_checkout?(definition)
      UI.messagebox("'#{component_name}' is not in read-only checkout mode.")
      return
    end

    model.start_operation("Cancel Read-Only Checkout", true)
    clear_readonly_checkout(definition)
    # Clear readonly modified flag
    definition.delete_attribute(XREF_DICT_NAME, XREF_READONLY_MODIFIED_KEY)
    # Update status cache
    lock_content = get_xref_lock_status(definition)
    @last_xref_statuses[definition.guid] = {
      lock_content: lock_content,
      update_available: _is_update_available?(definition),
    }
    model.commit_operation

    refresh_dialog_data
    Sketchup.set_status_text("Read-only checkout cancelled for '#{component_name}'.")
  end

  # Internal helper to save a definition and optionally remove its lock file.
  # @param definition [Sketchup::ComponentDefinition] The XRef definition to save
  # @param keep_locked [Boolean] If true, keeps the lock file after saving (default: false)
  def self._silent_save_and_check_in(definition, keep_locked: false)
    path = resolve_xref_path(definition)
    return false unless path

    # Check if readonly checkout is active (prevent publishing)
    if is_readonly_checkout?(definition)
      lock_content = get_xref_lock_status(definition)
      lock_owner_name = ""
      lock_owner_name, = lock_content.split("|") if lock_content != "unlocked"
      message = "Cannot publish: '#{definition.name}' is checked out in read-only mode"
      message += " because it's locked by #{lock_owner_name}" if lock_owner_name && !lock_owner_name.empty?
      message += ".\n\nYour changes are saved locally but cannot be published to the file."
      UI.messagebox(message)
      return false
    end

    # Check if travel-through is active for this XRef (prevent saving parent in travel-through mode)
    travel_through_active = @travel_through_active || {}
    if travel_through_active[definition.guid]
      UI.messagebox("Cannot save '#{definition.name}': You are in travel-through mode. Only nested XRefs can be edited and saved.")
      return false
    end

    # Check if nested XRefs have updates before saving
    nested_xrefs = find_nested_xrefs(definition)
    updated_nested = []
    nested_xrefs.each do |nested_def|
      updated_nested << nested_def.name if _is_update_available?(nested_def)
    end

    unless updated_nested.empty?
      message = "Warning: '#{definition.name}' contains nested XRefs that have been updated:\n\n"
      message += updated_nested.join("\n")
      message += "\n\nSaving now will include the old versions. Reload the nested XRefs first?"
      result = UI.messagebox(message, MB_YESNO)
      if result == IDYES
        # User wants to reload first - abort save
        return false
      end
    end

    begin
      definition.save_as(path)
      _update_xref_timestamp(definition)

      # Store last publisher info
      model = definition.model
      model_path = model.path
      model_name = model_path.nil? || model_path.empty? ? "Untitled Model" : File.basename(model_path)
      model_path_str = model_path.nil? ? "" : model_path

      definition.set_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_NAME_KEY, @user_name)
      definition.set_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_MODEL_KEY, model_name)
      definition.set_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_PATH_KEY, model_path_str)
      # Clear the edited_without_lock flag when saving and checking in
      definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)

      lock_path = "#{path}.lock"
      if keep_locked
        # Keep the lock file - XRef remains checked out, keep instances unlocked
        lock_content = File.exist?(lock_path) ? File.read(lock_path).strip : "unlocked"
        @last_xref_statuses[definition.guid] = { lock_content: lock_content, update_available: false }
      else
        # Remove the lock file - XRef is checked in, unlock instances
        FileUtils.rm_f(lock_path)
        @last_xref_statuses[definition.guid] = { lock_content: "unlocked", update_available: false }
        # Unlock the instances since the XRef is now checked in and available for editing
        lock_or_unlock_instances_for_definition(definition, false)
      end
      true
    rescue StandardError => e
      UI.messagebox("Failed to save component '#{definition.name}'.\nError: #{e.message}")
      false
    end
  end

  # Saves and optionally checks in all XRefs currently checked out by the user in this model.
  # @param keep_locked [Boolean] If true, keeps XRefs locked after saving (default: false)
  def self.save_and_check_in_all_my_xrefs(keep_locked: false)
    model = Sketchup.active_model
    current_guid = model.guid

    my_xrefs = get_xref_definitions.select do |definition|
      lock_content = get_xref_lock_status(definition)
      next false if lock_content == "unlocked"

      lock_owner_name, lock_owner_guid = lock_content.split("|")
      lock_owner_name == @user_name && lock_owner_guid == current_guid
    end

    # Separate readonly checkouts
    readonly_xrefs = get_xref_definitions.select { |d| is_readonly_checkout?(d) }

    # Filter out readonly checkouts from my_xrefs
    my_xrefs = my_xrefs.reject { |d| is_readonly_checkout?(d) }

    if my_xrefs.empty? && readonly_xrefs.empty?
      UI.messagebox("You have no XRefs checked out in this model.")
      return
    end

    if my_xrefs.empty? && !readonly_xrefs.empty?
      message = "You have #{readonly_xrefs.length} XRef(s) in read-only checkout mode.\n\n"
      message += "Read-only checkouts cannot be published. Please check out normally to publish changes."
      UI.messagebox(message)
      return
    end

    # Show warning if there are readonly checkouts
    unless readonly_xrefs.empty?
      readonly_names = readonly_xrefs.map(&:name).join(", ")
      message = "Warning: #{readonly_xrefs.length} XRef(s) in read-only checkout mode will be skipped:\n\n"
      message += readonly_names
      message += "\n\nThese cannot be published. Continue with the remaining XRefs?"
      result = UI.messagebox(message, MB_YESNO)
      return unless result == IDYES
    end

    operation_name = keep_locked ? "Save All My XRefs" : "Save & Check In All My XRefs"
    model.start_operation(operation_name, true)

    # Check if we are currently editing any of the XRefs being saved.
    was_editing_an_xref = false
    if model.active_path
      was_editing_an_xref = model.active_path.any? do |instance|
        my_xrefs.include?(instance.definition)
      end
    end

    my_xrefs.each do |definition|
      _silent_save_and_check_in(definition, keep_locked: keep_locked)
    end
    model.close_active if was_editing_an_xref
    model.commit_operation

    check_for_status_changes(show_notification: false)
    refresh_dialog_data
  end

  # Saves and optionally checks in a single XRef.
  # @param component_name [String] Name of the component
  # @param keep_locked [Boolean] If true, keeps the XRef locked after saving (default: false)
  def self.save_and_check_in_xref(component_name, keep_locked: false)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    # Early check for readonly checkout
    if is_readonly_checkout?(definition)
      lock_content = get_xref_lock_status(definition)
      lock_owner_name = ""
      lock_owner_name, = lock_content.split("|") if lock_content != "unlocked"
      message = "Cannot publish: '#{component_name}' is checked out in read-only mode"
      message += " because it's locked by #{lock_owner_name}" if lock_owner_name && !lock_owner_name.empty?
      message += ".\n\nYour changes are saved locally but cannot be published to the file."
      UI.messagebox(message)
      return
    end

    lock_content = get_xref_lock_status(definition)
    lock_owner_name, lock_owner_guid = lock_content.split("|")

    if lock_owner_name == @user_name && lock_owner_guid == model.guid
      operation_name = keep_locked ? "Save XRef" : "Save & Check In XRef"
      model.start_operation(operation_name, true)
      was_editing = model.active_path&.any? { |instance| instance.definition == definition }
      success = _silent_save_and_check_in(definition, keep_locked: keep_locked)

      if success
        # After saving a nested XRef, mark parent XRefs as needing update
        parent_xrefs = find_parent_xrefs_containing(definition)
        parent_xrefs.each do |parent_def|
          # Invalidate the parent's status cache so it will be re-checked
          @last_xref_statuses.delete(parent_def.guid)

          # Check if parent file itself has been updated (decoupled from nested XRef updates
          # to prevent infinite loops - parent only shows "update available" if its own
          # file timestamp changed, not based on nested XRef content)
          update_available = _is_update_available?(parent_def)
          lock_content = get_xref_lock_status(parent_def)

          # Update the status cache
          @last_xref_statuses[parent_def.guid] = {
            lock_content: lock_content,
            update_available: update_available,
          }

          # Lock instances if update is available (unless travel-through is enabled)
          if update_available && !is_travel_through_enabled?(parent_def)
            lock_or_unlock_instances_for_definition(parent_def, true)
          end
        end

        unless parent_xrefs.empty?
          parent_names = parent_xrefs.map(&:name).join(", ")
          Sketchup.set_status_text("'#{component_name}' saved. Parent XRef(s) '#{parent_names}' need to be reloaded.")
        end

        # Refresh status to show parent updates
        check_for_status_changes(show_notification: false)
      end

      model.close_active if was_editing
      model.commit_operation
      check_for_status_changes(show_notification: false)
    else
      UI.beep
    end
    refresh_dialog_data
  end

  # Forces a check-in, useful if an XRef is locked by the same user in another session.
  def self.force_check_in_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    # Prevent force check-in if travel-through mode is enabled
    if is_travel_through_enabled?(definition)
      UI.messagebox("Cannot force check-in: Travel-through mode is active for '#{component_name}'. Disable travel-through mode first.")
      return
    end

    lock_content = get_xref_lock_status(definition)

    # Check if locked by another user - prevent force check-in
    if lock_content == "unlocked"
      UI.messagebox("'#{component_name}' is not checked out. No need to force check-in.")
      return
    end

    lock_owner_name, _, lock_model_name, = lock_content.split("|")
    lock_model_name ||= "an unsaved model"

    if lock_owner_name == @user_name
      question = "This XRef appears to be checked out by you in another session or window.\n\n" \
                 "Forcing a check-in will overwrite the file with the version from THIS model.\n\n" \
                 "Are you sure you want to continue?"
      result = UI.messagebox(question, MB_YESNO)
      return unless result == IDYES

      model.start_operation("Force Check In XRef", true)
      _silent_save_and_check_in(definition)
      model.commit_operation
      check_for_status_changes(show_notification: false)
    else
      # Another user has it locked - cannot force check-in
      UI.messagebox("Cannot force check-in: '#{component_name}' is checked out by #{lock_owner_name} in '#{lock_model_name}'.\n\nOnly the user who has it checked out can check it in.")
    end
    refresh_dialog_data
  end

  # Imports a file as a new XRef and places it for the user to position.
  # Supports .skp files only
  def self.import_as_xref
    model = Sketchup.active_model
    path = UI.openpanel("Import XRef file", "", "SketchUp Files|*.skp||")
    return unless path

    model.start_operation("Import as XRef", true)
    begin
      new_definition = model.definitions.load(path, allow_newer: true)
      _set_xref_path(new_definition, path, ask_user: true)
      _update_xref_timestamp(new_definition)
      model.place_component(new_definition, true)
    rescue StandardError => e
      UI.messagebox("Failed to import XRef.\nError: #{e.message}")
    ensure
      model.commit_operation
    end
    refresh_dialog_data
  end

  # Imports a .skp file as a new XRef. User can choose to place at current axis
  # (construction axes at model root, or local origin when inside a group) or at default global origin.
  def self.import_as_xref_at_origin
    model = Sketchup.active_model
    path = UI.openpanel("Import XRef at Origin", "", "SketchUp Files|*.skp||")
    return unless path

    result = UI.messagebox(
      "Place XRef at current axis (Yes) or at default global origin (No)? Cancel to abort.",
      MB_YESNOCANCEL
    )
    return if result == IDCANCEL

    use_current_axis = (result == IDYES)

    model.start_operation("Import XRef at Origin", true)
    begin
      new_definition = model.definitions.load(path, allow_newer: true)
      _set_xref_path(new_definition, path, ask_user: true)
      _update_xref_timestamp(new_definition)

      # No = default global origin: use stored origin_transform in world space (relative to global axes)
      # Yes = current axis: use stored origin_transform relative to current construction axes when present
      placement = _get_stored_placement_transform(new_definition, model, relative_to_global: !use_current_axis)
      if placement
        if model.active_path && !model.active_path.empty?
          model.active_entities.add_instance(new_definition, placement)
        else
          model.entities.add_instance(new_definition, placement)
        end
      elsif use_current_axis
        if model.active_path && !model.active_path.empty?
          model.active_entities.add_instance(new_definition, Geom::Transformation.new)
        else
          model.entities.add_instance(new_definition, model.axes.transformation)
        end
      else
        model.entities.add_instance(new_definition, Geom::Transformation.new)
      end
    rescue StandardError => e
      UI.messagebox("Failed to import XRef.\nError: #{e.message}")
    ensure
      model.commit_operation
    end
    refresh_dialog_data
  end

  # Finds the Group or ComponentInstance whose entities contain the given instance.
  def self._find_container(entities, instance)
    return nil unless entities && instance

    entities.each do |e|
      next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
      child_entities = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
      return e if child_entities == instance.owner
      found = _find_container(child_entities, instance)
      return found if found
    end
    nil
  end

  # Returns the global (model-space) transformation of an instance, including nested containers.
  def self._get_global_transformation(instance)
    model = instance.model
    return instance.transformation.clone if model.entities.include?(instance)

    container = _find_container(model.entities, instance)
    return instance.transformation.clone unless container

    _get_global_transformation(container) * instance.transformation
  end

  # Returns the placement transformation for an XRef definition that has origin_transform stored,
  # or nil if not present. relative_to_global: when true, use stored transform in world space (default
  # global origin axes); when false, use relative to current construction axes when origin_type was "current_axes".
  def self._get_stored_placement_transform(definition, model, relative_to_global: false)
    return nil unless definition
    arr = definition.get_attribute(XREF_DICT_NAME, XREF_ORIGIN_TRANSFORM_KEY)
    return nil unless arr.is_a?(Array) && arr.length == 16

    stored_trans = Geom::Transformation.new(arr)
    return stored_trans if relative_to_global

    origin_type = definition.get_attribute(XREF_DICT_NAME, XREF_ORIGIN_TYPE_KEY, "global")
    if origin_type == "current_axes"
      model.axes.transformation * stored_trans
    else
      stored_trans
    end
  end

  # Converts a regular component into an XRef by saving it to an external file.
  # Optionally stores the instance position relative to current axes or global origin for spatial reconstruction.
  def self.create_xref_from_component
    model = Sketchup.active_model
    selection = model.selection

    if selection.length != 1 || !selection.first.is_a?(Sketchup::ComponentInstance)
      UI.messagebox("Please select exactly ONE component instance.")
      return
    end

    instance = selection.first
    definition = instance.definition

    return UI.messagebox("'#{definition.name}' is already an XRef.") if is_xref?(definition)

    path = UI.savepanel("Create and Link XRef File", "", "#{definition.name}.skp")
    return unless path

    instance_global = _get_global_transformation(instance)
    result = UI.messagebox(
      "Store XRef position relative to origin for spatial reconstruction?\n\nYes = relative to current axes\nNo = relative to global origin\nCancel = don't store position",
      MB_YESNOCANCEL
    )

    store_origin_current = (result == IDYES)
    store_origin_global = (result == IDNO)

    model.start_operation("Create XRef from Component", true)
    begin
      # Set origin position on definition before save_as so the .skp file embeds it for correct placement on load
      if store_origin_current
        ref_trans = model.axes.transformation.inverse * instance_global
        definition.set_attribute(XREF_DICT_NAME, XREF_ORIGIN_TRANSFORM_KEY, ref_trans.to_a)
        definition.set_attribute(XREF_DICT_NAME, XREF_ORIGIN_TYPE_KEY, "current_axes")
      elsif store_origin_global
        definition.set_attribute(XREF_DICT_NAME, XREF_ORIGIN_TRANSFORM_KEY, instance_global.to_a)
        definition.set_attribute(XREF_DICT_NAME, XREF_ORIGIN_TYPE_KEY, "global")
      end

      definition.save_as(path)
      _set_xref_path(definition, path, ask_user: true)
      _update_xref_timestamp(definition)
    rescue StandardError => e
      UI.messagebox("Failed to save new XRef file.\nError: #{e.message}")
      model.abort_operation
      return
    end

    model.commit_operation
    refresh_dialog_data
  end

  # Reloads a single XRef after confirming with the user.
  def self.reload_single_xref(component_name, suppress_warning: false)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }

    # Prevent reload if travel-through mode is enabled
    if definition && is_travel_through_enabled?(definition)
      UI.messagebox("Cannot reload: Travel-through mode is active for '#{component_name}'. Disable travel-through mode first.\n\nReloading would replace the XRef and break the travel-through workflow.")
      return
    end

    # Check if readonly checkout with modifications
    readonly_modified = definition&.get_attribute(XREF_DICT_NAME, XREF_READONLY_MODIFIED_KEY, false)

    unless suppress_warning
      question = if readonly_modified
                   "Reloading '#{component_name}' will discard your local changes and reload from the published version.\n\n" \
                     "Your changes are saved in this model but will not be in the reloaded XRef.\n\n" \
                     "Are you sure you want to continue?"
                 else
                   "Reloading '#{component_name}' will discard any changes made to it in the current model.\n\n" \
                     "Are you sure you want to continue?"
                 end
      result = UI.messagebox(question, MB_YESNO)
      return unless result == IDYES
    end

    success = reload_single_xref_without_warning(component_name)

    if success && readonly_modified
      Sketchup.set_status_text("Local changes discarded. '#{component_name}' reloaded from published version.")
    end

    refresh_dialog_data
  end

  # Removes the XRef link from a component, making it a regular, internal component.
  def self.unlink_single_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    # Prevent unlink if travel-through mode is enabled
    if is_travel_through_enabled?(definition)
      UI.messagebox("Cannot unlink: Travel-through mode is active for '#{component_name}'. Disable travel-through mode first.\n\nUnlinking would break the XRef hierarchy and make nested XRefs inaccessible.")
      return
    end

    # Check for uncommitted changes and ask if user wants to publish first
    return unless ask_publish_before_operation?(component_name, "unlink this XRef")

    # Check if the file is locked
    lock_content = get_xref_lock_status(definition)
    is_locked = lock_content != "unlocked"

    if is_locked
      lock_owner_name, lock_owner_guid, lock_model_name, lock_model_path = lock_content.split("|")
      lock_model_name ||= "Untitled Model"
      lock_model_path ||= ""

      # Check if locked by current user in this model
      is_mine_in_this_model = lock_owner_name == @user_name && lock_owner_guid == model.guid

      if is_mine_in_this_model
        # Locked by us in this model - remove the lock file
        path = resolve_xref_path(definition)
        if path
          lock_path = "#{path}.lock"
          if File.exist?(lock_path)
            begin
              File.delete(lock_path)
            rescue StandardError => e
              puts "Warning: Could not delete lock file #{lock_path}: #{e.message}"
            end
          end
        end
      else
        # Locked by someone else or in another session - warn the user
        question = "Warning: The XRef file '#{component_name}' is currently checked out.\n\n"
        question += if lock_owner_name == @user_name
                      "It is checked out by you in another model:\n'#{lock_model_name}'\n\n"
                    else
                      "It is checked out by: #{lock_owner_name}\nIn model: '#{lock_model_name}'\n\n"
                    end
        question += "The lock file will remain after unlinking. Do you want to check it out first?"
        result = UI.messagebox(question, MB_YESNO)

        if result == IDYES
          # User wants to check it out first - but we can't if it's locked by someone else
          if lock_owner_name == @user_name
            # It's ours elsewhere - we could force unlock, but for now just warn
            UI.messagebox("The file is checked out in another session. Please check it in from that session first, or use 'Force Unlock' if appropriate.")
          else
            UI.messagebox("Cannot check out: The file is locked by another user (#{lock_owner_name}).\n\nYou may need to ask them to check it in, or use 'Force Unlock' if appropriate.")
          end
          return
        end
        # User chose to continue without checking out - proceed with unlink
      end
    end

    model.start_operation("Unlink XRef", true)
    was_editing = model.active_path&.any? { |instance| instance.definition == definition }
    definition.attribute_dictionaries.delete(XREF_DICT_NAME)
    lock_or_unlock_instances_for_definition(definition, false)
    model.close_active if was_editing
    model.commit_operation
    check_for_status_changes(show_notification: false)
    refresh_dialog_data
  end

  # Unloads an XRef's geometry to improve performance.
  def self.unload_single_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    # Prevent unload if travel-through mode is enabled
    if is_travel_through_enabled?(definition)
      UI.messagebox("Cannot unload: Travel-through mode is active for '#{component_name}'. Disable travel-through mode first.\n\nUnloading would remove nested XRefs and break the travel-through workflow.")
      return
    end

    # Check for uncommitted changes and ask if user wants to publish first
    return unless ask_publish_before_operation?(component_name, "unload this XRef")

    lock_content = get_xref_lock_status(definition)

    # If it's locked by me, my local changes will be lost.
    # The lock must be removed to avoid conflicts.
    if lock_content != "unlocked"
      lock_owner_name, lock_owner_guid, = lock_content.split("|")
      if lock_owner_name == @user_name && lock_owner_guid == model.guid
        # Locked by me in this window. Remove the lock.
        lock_path = resolve_xref_path(definition)
        lock_path += ".lock" if lock_path
        File.delete(lock_path) if lock_path && File.exist?(lock_path)
        @last_xref_statuses[definition.guid] = { lock_content: "unlocked", update_available: _is_update_available?(definition) } # Update cache
      end
    end

    model.start_operation("Unload XRef", true)
    # Clear all geometry from the definition
    definition.entities.to_a.each { |e| e.erase! if e.valid? }
    placeholder_group = definition.entities.add_group
    placeholder_text = placeholder_group.definition.entities.add_text("XREF_PLACEHOLDER", [0, 0, 0])
    placeholder_text.hidden = true
    placeholder_group.hidden = true
    # Set the flag so we know it's unloaded
    definition.set_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, true)
    # Clear readonly checkout when unloading
    clear_readonly_checkout(definition)
    model.commit_operation

    # Refresh the UI
    refresh_dialog_data
  end

  # Reloads all XRefs in the model after confirmation.
  def self.reload_all_xrefs
    xref_definitions = get_xref_definitions
    return UI.messagebox("No XRefs to reload.") if xref_definitions.empty?

    question = "This will reload all linked XRefs, discarding any local changes.\n\n" \
               "Are you sure you want to continue?"
    result = UI.messagebox(question, MB_YESNO)
    return unless result == IDYES

    model = Sketchup.active_model
    model.start_operation("Reload All XRefs", true)
    reloaded_count = 0
    failed_names = []
    xref_definitions.each do |definition|
      if reload_single_xref_without_warning(definition.name, suppress_errors: true)
        reloaded_count += 1
      else
        failed_names << definition.name
      end
    end
    model.commit_operation

    message = "Reloaded #{reloaded_count} XRef(s)."
    message += "\n\nFailed to reload:\n#{failed_names.join("\n")}" unless failed_names.empty?
    UI.messagebox(message)
    refresh_dialog_data
  end

  # The core logic for reloading an XRef from its file.
  def self.reload_single_xref_without_warning(component_name, suppress_errors: false)
    model = Sketchup.active_model
    # This is the original, "unloaded" definition (e.g., "Box")
    original_definition = model.definitions.find { |d| d.name == component_name }
    return false unless original_definition

    path = resolve_xref_path(original_definition)

    unless path && File.exist?(path)
      UI.messagebox("Cannot reload '#{component_name}'. File not found at:\n#{path}") unless suppress_errors
      return false
    end

    model.start_operation("Reload XRef: #{component_name}", true)

    success = false
    begin
      # Before reloading, identify and store current nested XRef definitions
      # so we can preserve them after reload (don't overwrite with versions from parent file)
      nested_xrefs_before = find_nested_xrefs(original_definition)
      nested_xref_map = {} # Map of child XRef path => current definition reference
      nested_xrefs_before.each do |nested_def|
        nested_path = resolve_xref_path(nested_def)
        nested_xref_map[nested_path] = nested_def if nested_path
      end

      reloaded_definition = model.definitions.load(path, allow_newer: true)

      if reloaded_definition && reloaded_definition != original_definition

        # Get all instances of the original (unloaded) definition.
        # We use .to_a to make a copy before changing them.
        instances = original_definition.instances.to_a

        # Point all instances to the newly loaded definition.
        instances.each do |instance|
          instance.definition = reloaded_definition if instance.valid?
        end

        # Copy XRef attributes from the old shell to the new definition.
        dict = original_definition.attribute_dictionary(XREF_DICT_NAME)
        dict&.each_pair do |key, value|
          reloaded_definition.set_attribute(XREF_DICT_NAME, key, value)
        end

        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
        # Clear the edited_without_lock flag when reloading
        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)
        # Clear readonly modified flag when reloading (but keep readonly checkout active)
        reloaded_definition.delete_attribute(XREF_DICT_NAME, XREF_READONLY_MODIFIED_KEY)
        # NOTE: We keep readonly checkout active after reload (don't clear it)
        # This allows user to continue editing after discarding local changes

        # Preserve nested XRef definitions - don't overwrite with versions from parent file
        unless nested_xref_map.empty?
          # Find nested XRefs that came from the reloaded parent file
          nested_xrefs_after = find_nested_xrefs(reloaded_definition)

          nested_xrefs_after.each do |nested_from_file|
            # Match by XRef path (not GUID, since loaded definitions have different GUIDs)
            nested_path_from_file = resolve_xref_path(nested_from_file)
            current_nested = nested_path_from_file ? nested_xref_map[nested_path_from_file] : nil

            next unless current_nested&.valid? && is_xref?(current_nested)

            # We have a current version - replace the one from the file with the current one
            # Update all instances in the reloaded parent to point to the current child definition
            reloaded_definition.entities.each do |entity|
              if entity.is_a?(Sketchup::ComponentInstance) && entity.definition == nested_from_file
                entity.definition = current_nested
              elsif entity.is_a?(Sketchup::Group)
                # Check groups too - recursively
                entity.entities.each do |group_entity|
                  if group_entity.is_a?(Sketchup::ComponentInstance) && group_entity.definition == nested_from_file
                    group_entity.definition = current_nested
                  elsif group_entity.is_a?(Sketchup::Group)
                    # Handle nested groups
                    group_entity.entities.each do |nested_group_entity|
                      if nested_group_entity.is_a?(Sketchup::ComponentInstance) && nested_group_entity.definition == nested_from_file
                        nested_group_entity.definition = current_nested
                      end
                    end
                  end
                end
              end
            end

            # The nested definition from the file will be purged if unused
          end
        end

        # Remove XRef attributes from the OLD definition so it's
        # no longer tracked and can be purged.
        original_definition.attribute_dictionaries.delete(XREF_DICT_NAME)

        original_name = original_definition.name

        model.definitions.purge_unused

        if model.definitions[original_name].nil?
          reloaded_definition.name = original_name
        else
          # Purge failed (rare, but possible). We're stuck with 'Box#1'.
          puts "OpenXrefManager: Could not purge '#{original_name}'. " \
               "Reloaded XRef remains as '#{reloaded_definition.name}'."
        end
        _update_xref_timestamp(reloaded_definition)

      elsif reloaded_definition && reloaded_definition == original_definition
        # This path happens if the definition was *already* purged.
        # In this case, just set the unloaded flag to false.
        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
        # Clear the edited_without_lock flag when reloading
        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)
        # Clear readonly modified flag when reloading
        reloaded_definition.delete_attribute(XREF_DICT_NAME, XREF_READONLY_MODIFIED_KEY)
        # NOTE: We keep readonly checkout active after reload (don't clear it)
        _update_xref_timestamp(reloaded_definition)
      end

      success = !reloaded_definition.nil?
    rescue StandardError => e
      UI.messagebox("Failed to reload #{component_name}.\nError: #{e.message}") unless suppress_errors
      success = false
    ensure
      model.commit_operation
    end

    refresh_dialog_data if success
    success
  end

  # Finds all lock files owned by the current user with a specific (old) model GUID
  # and updates them with the new GUID. This is crucial for when a model is saved for the first time.
  # Finds all lock files owned by the current user with a specific (old) model GUID
  # and updates them with the new GUID. This is crucial for when a model is saved for the first time.
  def self.update_owned_lock_files(old_guid, new_guid)
    my_xrefs_to_update = get_xref_definitions.select do |definition|
      lock_content = get_xref_lock_status(definition)
      next false if lock_content == "unlocked"

      lock_owner_name, lock_owner_guid = lock_content.split("|")
      # Find files locked by this user with the old GUID
      lock_owner_name == @user_name && lock_owner_guid == old_guid
    end

    return if my_xrefs_to_update.empty?

    # This is a file system operation, not a model operation.
    my_xrefs_to_update.each do |definition|
      path = resolve_xref_path(definition)
      next unless path

      lock_path = "#{path}.lock"
      begin
        model_path = definition.model.path
        model_name = model_path.nil? || model_path.empty? ? "Untitled Model" : File.basename(model_path)
        model_path_str = model_path.nil? ? "" : model_path # Get the full path as a string
        lock_content = "#{@user_name}|#{new_guid}|#{model_name}|#{model_path_str}"

        File.write(lock_path, lock_content)
        @last_xref_statuses[definition.guid] = { lock_content: lock_content, update_available: _is_update_available?(definition) } # Update cache
      rescue StandardError => e
        puts "Could not update lock file #{lock_path}: #{e.message}"
      end
    end
  end

  # --- Travel-Through Mode Functions ---

  # Enables travel-through mode for a given XRef, allowing entry into locked XRefs to reach nested XRefs.
  # @param component_name [String] Name of the component
  def self.enable_travel_through(component_name)
    model = Sketchup.active_model
    return unless model

    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition && is_xref?(definition)

    # Check if there are nested XRefs
    nested_xrefs = find_nested_xrefs(definition)
    if nested_xrefs.empty?
      UI.messagebox("'#{component_name}' does not contain any nested XRefs.")
      return
    end

    # Store travel-through state in model attributes
    # SketchUp attributes need to store simple types, so we'll use JSON for the nested hash
    require "json"
    travel_through_json = model.get_attribute(SETTINGS_DICT_NAME, SETTINGS_TRAVEL_THROUGH_XREFS_KEY)
    travel_through = {}
    if travel_through_json && !travel_through_json.empty?
      begin
        travel_through = JSON.parse(travel_through_json)
      rescue StandardError
        travel_through = {}
      end
    end

    # Use definition name as key because GUID changes when component content is modified (e.g. nested edit)
    key = definition.name
    travel_through[key] = {
      "user" => @user_name,
      "model_guid" => model.guid.to_s,
      "enabled_at" => Time.now.to_i,
    }
    model.set_attribute(SETTINGS_DICT_NAME, SETTINGS_TRAVEL_THROUGH_XREFS_KEY, travel_through.to_json)

    # Unlock instances to allow entry (even though XRef is locked by someone else)
    lock_or_unlock_instances_for_definition(definition, false)

    refresh_dialog_data
    Sketchup.set_status_text("Travel-through mode enabled for '#{component_name}'. You can now enter to edit nested XRefs.")
  end

  # Disables travel-through mode for a given XRef.
  # @param component_name [String] Name of the component
  def self.disable_travel_through(component_name)
    model = Sketchup.active_model
    return unless model

    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    require "json"
    travel_through_json = model.get_attribute(SETTINGS_DICT_NAME, SETTINGS_TRAVEL_THROUGH_XREFS_KEY)
    travel_through = {}
    if travel_through_json && !travel_through_json.empty?
      begin
        travel_through = JSON.parse(travel_through_json)
      rescue StandardError
        travel_through = {}
      end
    end

    # Use definition name as key
    key = definition.name
    travel_through.delete(key)
    model.set_attribute(SETTINGS_DICT_NAME, SETTINGS_TRAVEL_THROUGH_XREFS_KEY, travel_through.to_json)

    # Clear active travel-through state
    @travel_through_active&.delete(definition.name)

    # Re-lock instances if XRef is still locked by someone else
    lock_content = get_xref_lock_status(definition)
    is_locked = lock_content != "unlocked"
    if is_locked
      lock_owner_name, lock_owner_guid, = lock_content.split("|")
      is_mine_in_this_window = lock_owner_name == @user_name && lock_owner_guid == model.guid
      unless is_mine_in_this_window
        # Locked by someone else - re-lock instances
        lock_or_unlock_instances_for_definition(definition, true)
      end
    end

    refresh_dialog_data
    Sketchup.set_status_text("Travel-through mode disabled for '#{component_name}'.")
  end

  # Checks if travel-through mode is enabled for a given XRef in the current model.
  # @param definition [Sketchup::ComponentDefinition] The XRef definition to check
  # @return [Boolean] True if travel-through is enabled for this user in this model
  def self.is_travel_through_enabled?(definition)
    return false unless definition&.valid?

    model = definition.model
    return false unless model

    require "json"
    travel_through_json = model.get_attribute(SETTINGS_DICT_NAME, SETTINGS_TRAVEL_THROUGH_XREFS_KEY)
    return false unless travel_through_json && !travel_through_json.empty?

    begin
      travel_through = JSON.parse(travel_through_json)
    rescue StandardError
      return false
    end

    # Use definition name as key
    key = definition.name
    travel_through_info = travel_through[key]
    return false unless travel_through_info

    # Check if it's enabled for this user in this model
    travel_through_info["user"] == @user_name && travel_through_info["model_guid"] == model.guid.to_s
  end

  # Updates the model_guid in travel-through settings after a model save.
  # This ensures the permission remains valid even though the model GUID changed.
  def self.update_travel_through_guids(old_guid, new_guid)
    model = Sketchup.active_model
    return unless model

    travel_through_json = model.get_attribute(SETTINGS_DICT_NAME, SETTINGS_TRAVEL_THROUGH_XREFS_KEY)
    return unless travel_through_json && !travel_through_json.empty?

    begin
      travel_through = JSON.parse(travel_through_json)
      updated = false

      travel_through.each_value do |info|
        if info["user"] == @user_name && info["model_guid"] == old_guid
          info["model_guid"] = new_guid
          updated = true
        end
      end

      model.set_attribute(SETTINGS_DICT_NAME, SETTINGS_TRAVEL_THROUGH_XREFS_KEY, travel_through.to_json) if updated
    rescue StandardError => e
      puts "OpenXrefManager: Failed to update travel-through GUIDs: #{e.message}"
    end
  end
end
