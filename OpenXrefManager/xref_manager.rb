require_relative 'core'

module OpenXrefManager

  # --- Core Xref Functions ---

  # Resolves the full, absolute path for an XRef definition, accounting for relative paths.
  def self.resolve_xref_path(definition)
    return nil unless definition
    path = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY)
    return nil unless path

    path_type = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")

    if path_type == "relative"
      model_path = definition.model.path
      if model_path.nil? || model_path.empty?
        # Cannot resolve relative path if model is unsaved
        return nil 
      end
      model_dir = File.dirname(model_path)
      begin
        absolute_path = File.expand_path(path, model_dir)
        return absolute_path
      rescue
        return nil
      end
    else
      return path
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

  # Checks if a given XRef definition has a newer version available on disk.
  def self._is_update_available?(definition)
    path = resolve_xref_path(definition)
    return false unless path && File.exist?(path)

    stored_timestamp = definition.get_attribute(XREF_DICT_NAME, XREF_TIMESTAMP_KEY)
    return true if stored_timestamp.nil? # If no timestamp, assume update needed (or just missing data)

    current_file_timestamp = File.mtime(path).to_i
    
    # If file on disk is newer than stored timestamp, update is available.
    return current_file_timestamp > stored_timestamp
  end

  # Reads the lock file for a given XRef and returns its content (owner|guid).
  # Returns "unlocked" if no lock file exists.
  def self.get_xref_lock_status(definition)
    path = resolve_xref_path(definition)
    return "unlocked" unless path
    
    lock_path = path + ".lock"
    if File.exist?(lock_path)
      begin
        content = File.read(lock_path).strip
        return content
      rescue
        return "unlocked" # Treat read errors as unlocked (or handle differently?)
      end
    else
      return "unlocked"
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
    if path && File.exist?(path)
      definition.set_attribute(XREF_DICT_NAME, XREF_TIMESTAMP_KEY, File.mtime(path).to_i)
    end
  end

  # Helper method to check if the user has any XRefs checked out.
  def self.has_uncommitted_changes?
    model = Sketchup.active_model
    return false unless model
    
    current_guid = model.guid
    
    get_xref_definitions.any? do |definition|
       lock_content = get_xref_lock_status(definition)
       next false if lock_content == "unlocked"
       lock_owner_name, lock_owner_guid = lock_content.split('|')
       lock_owner_name == @user_name && lock_owner_guid == current_guid
    end
  end

  # Helper method to check if a specific XRef has uncommitted changes (is checked out by current user in this model).
  def self.xref_has_uncommitted_changes?(definition)
    model = Sketchup.active_model
    current_guid = model.guid
    lock_content = get_xref_lock_status(definition)
    return false if lock_content == "unlocked"
    lock_owner_name, lock_owner_guid = lock_content.split('|')
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
        require 'pathname'
        abs_path = Pathname.new(current_path)
        base_path = Pathname.new(model_dir)
        rel_path = abs_path.relative_path_from(base_path).to_s
        
        definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, rel_path)
        definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "relative")
      rescue => e
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
    self.refresh_dialog_data
  end

  # Allows the user to select a new file path for an existing XRef.
  def self.relink_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    path = UI.openpanel("Relink XRef File", "", "*.skp")
    return unless path
    
    # Update path
    self._set_xref_path(definition, path, ask_user: true)
    
    # Update timestamp
    self._update_xref_timestamp(definition)
    
    # Check if the new file is valid and reload it
    if File.exist?(path)
       self.reload_single_xref_without_warning(component_name)
    else
       UI.messagebox("The selected file does not exist.")
    end
    
    self.refresh_dialog_data
  end

  # Internal helper to set the path attribute, with an option to ask the user about relative paths.
  def self._set_xref_path(definition, absolute_path, ask_user: true)
    model = definition.model
    model_path = model.path
    
    use_relative = false
    
    if ask_user && !model_path.nil? && !model_path.empty?
       # Check if on same drive/volume
       require 'pathname'
       begin
         Pathname.new(absolute_path).relative_path_from(Pathname.new(File.dirname(model_path)))
         # If successful, it's possible to use relative path
         result = UI.messagebox("Do you want to use a relative path for this XRef?\n(Best if you plan to move the project folder)", MB_YESNO)
         use_relative = (result == IDYES)
       rescue
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
    
    path = self.resolve_xref_path(definition)
    return unless path
    
    lock_path = path + ".lock"
    if File.exist?(lock_path)
      begin
        File.delete(lock_path)
        @last_xref_statuses[definition.guid] = { lock_content: "unlocked", update_available: _is_update_available?(definition) }
      rescue => e
        UI.messagebox("Failed to delete lock file: #{e.message}")
      end
    end
    self.refresh_dialog_data
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
        lock_owner_name, lock_owner_guid = lock_content.split('|')
        if lock_owner_name == @user_name && lock_owner_guid == model.guid
           path = self.resolve_xref_path(definition)
           lock_path = path + ".lock" if path
           File.delete(lock_path) if lock_path && File.exist?(lock_path)
        end
      end
      model.definitions.remove(definition)
      purged_count += 1
    end
    model.commit_operation
    UI.messagebox("Purged #{purged_count} unused XRef(s).")
    self.refresh_dialog_data
  end

  # Creates a .lock file for an XRef, marking it as "checked out" by the current user.
  def self.check_out_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    path = self.resolve_xref_path(definition)
    return unless path
    lock_path = path + ".lock"
    
    if File.exist?(path) && !File.exist?(lock_path)
      model.start_operation("Check Out XRef", true)
      begin
        model_path = model.path
        model_name = (model_path.nil? || model_path.empty?) ? "Untitled Model" : File.basename(model_path)
        model_path_str = model_path.nil? ? "" : model_path # Get the full path as a string
        lock_content = "#{@user_name}|#{model.guid}|#{model_name}|#{model_path_str}"

        File.write(lock_path, lock_content)
        # Clear the edited_without_lock flag when checking out
        definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)
        @last_xref_statuses[definition.guid] = { lock_content: lock_content, update_available: _is_update_available?(definition) }
        # Always unlock instances when checking out
        self.lock_or_unlock_instances_for_definition(definition, false)
      rescue => e
        UI.messagebox("Failed to create lock file:\n#{e.message}")
      end
      model.commit_operation
    else
      UI.beep # Can't check out if file doesn't exist or is already locked
    end
    self.refresh_dialog_data
  end
  
  # Internal helper to save a definition and optionally remove its lock file.
  # @param definition [Sketchup::ComponentDefinition] The XRef definition to save
  # @param keep_locked [Boolean] If true, keeps the lock file after saving (default: false)
  def self._silent_save_and_check_in(definition, keep_locked: false)
    path = self.resolve_xref_path(definition)
    return false unless path
    begin
      definition.save_as(path)
      self._update_xref_timestamp(definition)

      # Store last publisher info
      model = definition.model
      model_path = model.path
      model_name = (model_path.nil? || model_path.empty?) ? "Untitled Model" : File.basename(model_path)
      model_path_str = model_path.nil? ? "" : model_path
      
      definition.set_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_NAME_KEY, @user_name)
      definition.set_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_MODEL_KEY, model_name)
      definition.set_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_PATH_KEY, model_path_str)
      # Clear the edited_without_lock flag when saving and checking in
      definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)

      lock_path = path + ".lock"
      if keep_locked
        # Keep the lock file - XRef remains checked out, keep instances unlocked
        lock_content = File.exist?(lock_path) ? File.read(lock_path).strip : "unlocked"
        @last_xref_statuses[definition.guid] = { lock_content: lock_content, update_available: false }
      else
        # Remove the lock file - XRef is checked in, unlock instances
        File.delete(lock_path) if File.exist?(lock_path)
        @last_xref_statuses[definition.guid] = { lock_content: "unlocked", update_available: false }
        # Unlock the instances since the XRef is now checked in and available for editing
        self.lock_or_unlock_instances_for_definition(definition, false)
      end
      return true
    rescue => e
      UI.messagebox("Failed to save component '#{definition.name}'.\nError: #{e.message}")
      return false
    end
  end

  # Saves and optionally checks in all XRefs currently checked out by the user in this model.
  # @param keep_locked [Boolean] If true, keeps XRefs locked after saving (default: false)
  def self.save_and_check_in_all_my_xrefs(keep_locked: false)
    model = Sketchup.active_model
    current_guid = model.guid

    my_xrefs = self.get_xref_definitions.select do |definition|
      lock_content = self.get_xref_lock_status(definition)
      next false if lock_content == "unlocked"
      lock_owner_name, lock_owner_guid = lock_content.split('|')
      lock_owner_name == @user_name && lock_owner_guid == current_guid
    end

    if my_xrefs.empty?
      UI.messagebox("You have no XRefs checked out in this model.")
      return
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
      self._silent_save_and_check_in(definition, keep_locked: keep_locked)
    end
    model.close_active if was_editing_an_xref
    model.commit_operation

    self.check_for_status_changes(show_notification: false)
    self.refresh_dialog_data

  end
  
  # Saves and optionally checks in a single XRef.
  # @param component_name [String] Name of the component
  # @param keep_locked [Boolean] If true, keeps the XRef locked after saving (default: false)
  def self.save_and_check_in_xref(component_name, keep_locked: false)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    lock_content = self.get_xref_lock_status(definition)
    lock_owner_name, lock_owner_guid = lock_content.split('|')
    
    if lock_owner_name == @user_name && lock_owner_guid == model.guid
      operation_name = keep_locked ? "Save XRef" : "Save & Check In XRef"
      model.start_operation(operation_name, true)
      was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }
      self._silent_save_and_check_in(definition, keep_locked: keep_locked)
      model.close_active if was_editing
      model.commit_operation
      self.check_for_status_changes(show_notification: false)
    else
      UI.beep
    end
    self.refresh_dialog_data
  end

  # Forces a check-in, useful if an XRef is locked by the same user in another session.
  def self.force_check_in_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    lock_content = self.get_xref_lock_status(definition)
    lock_owner_name, _ = lock_content.split('|')

    if lock_owner_name == @user_name
      question = "This XRef appears to be checked out by you in another session or window.\n\n" +
                 "Forcing a check-in will overwrite the file with the version from THIS model.\n\n" +
                 "Are you sure you want to continue?"
      result = UI.messagebox(question, MB_YESNO)
      return unless result == IDYES

      model.start_operation("Force Check In XRef", true)
      self._silent_save_and_check_in(definition)
      model.commit_operation
      self.check_for_status_changes(show_notification: false)
    else
      UI.beep
    end
    self.refresh_dialog_data
  end

  # Imports a file as a new XRef and places it for the user to position.
  # Supports .skp files only
  def self.import_as_xref
    model = Sketchup.active_model
    path = UI.openpanel("Import XRef file", "", "SketchUp Files|*.skp||")
    return unless path
    
    model.start_operation("Import as XRef", true)
    begin
      new_definition = model.definitions.load(path)
      self._set_xref_path(new_definition, path, ask_user: true)
      self._update_xref_timestamp(new_definition)
      model.place_component(new_definition, true)
    rescue => e
      UI.messagebox("Failed to import XRef.\nError: #{e.message}")
    ensure
      model.commit_operation
    end
    self.refresh_dialog_data
  end

  # Imports a .skp file as a new XRef at the model origin.
  def self.import_as_xref_at_origin
    model = Sketchup.active_model
    path = UI.openpanel("Import XRef at Origin", "", "SketchUp Files|*.skp||")
    return unless path
    model.start_operation("Import XRef at Origin", true)
    begin
      new_definition = model.definitions.load(path)
      self._set_xref_path(new_definition, path, ask_user: true)
      self._update_xref_timestamp(new_definition)
      model.entities.add_instance(new_definition, Geom::Transformation.new)
    rescue => e
      UI.messagebox("Failed to import XRef.\nError: #{e.message}")
    ensure
      model.commit_operation
    end
    self.refresh_dialog_data
  end

  # Converts a regular component into an XRef by saving it to an external file.
  def self.create_xref_from_component
    model = Sketchup.active_model
    selection = model.selection
    
    if selection.length != 1 || !selection.first.is_a?(Sketchup::ComponentInstance)
      UI.messagebox("Please select exactly ONE component instance.")
      return
    end
    
    instance = selection.first
    definition = instance.definition
    
    return UI.messagebox("'#{definition.name}' is already an XRef.") if self.is_xref?(definition)

    path = UI.savepanel("Create and Link XRef File", "", "#{definition.name}.skp")
    return unless path
    
    model.start_operation("Create XRef from Component", true)
    begin
      definition.save_as(path)
      self._set_xref_path(definition, path, ask_user: true)
      self._update_xref_timestamp(definition)
    rescue => e
      UI.messagebox("Failed to save new XRef file.\nError: #{e.message}")
      model.abort_operation
      return
    end
    
    model.commit_operation
    self.refresh_dialog_data
  end

  # Reloads a single XRef after confirming with the user.
  def self.reload_single_xref(component_name, suppress_warning: false)
    if !suppress_warning
      question = "Reloading '#{component_name}' will discard any changes made to it in the current model.\n\n" +
                 "Are you sure you want to continue?"
      result = UI.messagebox(question, MB_YESNO)
      return unless result == IDYES
    end

    self.reload_single_xref_without_warning(component_name)
    self.refresh_dialog_data
  end

  # Removes the XRef link from a component, making it a regular, internal component.
  def self.unlink_single_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    
    # Check for uncommitted changes and ask if user wants to publish first
    return unless self.ask_publish_before_operation?(component_name, "unlink this XRef")
    
    # Check if the file is locked
    lock_content = self.get_xref_lock_status(definition)
    is_locked = lock_content != "unlocked"
    
    if is_locked
      lock_owner_name, lock_owner_guid, lock_model_name, lock_model_path = lock_content.split('|')
      lock_model_name ||= "Untitled Model"
      lock_model_path ||= ""
      
      # Check if locked by current user in this model
      is_mine_in_this_model = (lock_owner_name == @user_name && lock_owner_guid == model.guid)
      
      if is_mine_in_this_model
        # Locked by us in this model - remove the lock file
        path = self.resolve_xref_path(definition)
        if path
          lock_path = path + ".lock"
          if File.exist?(lock_path)
            begin
              File.delete(lock_path)
            rescue => e
              puts "Warning: Could not delete lock file #{lock_path}: #{e.message}"
            end
          end
        end
      else
        # Locked by someone else or in another session - warn the user
        question = "Warning: The XRef file '#{component_name}' is currently checked out.\n\n"
        if lock_owner_name == @user_name
          question += "It is checked out by you in another model:\n'#{lock_model_name}'\n\n"
        else
          question += "It is checked out by: #{lock_owner_name}\nIn model: '#{lock_model_name}'\n\n"
        end
        question += "The lock file will remain after unlinking. Do you want to check it out first?"
        result = UI.messagebox(question, MB_YESNO)
        
        if result == IDYES
          # User wants to check it out first - but we can't if it's locked by someone else
          if lock_owner_name != @user_name
            UI.messagebox("Cannot check out: The file is locked by another user (#{lock_owner_name}).\n\nYou may need to ask them to check it in, or use 'Force Unlock' if appropriate.")
            return
          else
            # It's ours elsewhere - we could force unlock, but for now just warn
            UI.messagebox("The file is checked out in another session. Please check it in from that session first, or use 'Force Unlock' if appropriate.")
            return
          end
        end
        # User chose to continue without checking out - proceed with unlink
      end
    end
    
    model.start_operation("Unlink XRef", true)
    was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }
    definition.attribute_dictionaries.delete(XREF_DICT_NAME)
    self.lock_or_unlock_instances_for_definition(definition, false)
    model.close_active if was_editing
    model.commit_operation
    self.check_for_status_changes(show_notification: false)
    self.refresh_dialog_data
  end

  # Unloads an XRef's geometry to improve performance.
  def self.unload_single_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    
    # Check for uncommitted changes and ask if user wants to publish first
    return unless self.ask_publish_before_operation?(component_name, "unload this XRef")
    
    lock_content = self.get_xref_lock_status(definition)
    
    # If it's locked by me, my local changes will be lost.
    # The lock must be removed to avoid conflicts.
    if lock_content != "unlocked"
      lock_owner_name, lock_owner_guid, _, _ = lock_content.split('|')
      if lock_owner_name == @user_name && lock_owner_guid == model.guid
        # Locked by me in this window. Remove the lock.
        lock_path = self.resolve_xref_path(definition)
        lock_path += ".lock" if lock_path
        File.delete(lock_path) if lock_path && File.exist?(lock_path)
        @last_xref_statuses[definition.guid] = { lock_content: "unlocked", update_available: _is_update_available?(definition) } # Update cache
      end
    end

    model.start_operation("Unload XRef", true)
    # Clear all geometry from the definition
    definition.entities.to_a.each { |e| e.erase! if e.valid? }
    placeholder_group = definition.entities.add_group
    placeholder_text = placeholder_group.definition.entities.add_text("XREF_PLACEHOLDER", [0,0,0])
    placeholder_text.hidden = true
    placeholder_group.hidden = true
    # Set the flag so we know it's unloaded
    definition.set_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, true)
    model.commit_operation
    
    # Refresh the UI
    self.refresh_dialog_data
  end

  # Reloads all XRefs in the model after confirmation.
  def self.reload_all_xrefs
    xref_definitions = self.get_xref_definitions
    return UI.messagebox("No XRefs to reload.") if xref_definitions.empty?

    question = "This will reload all linked XRefs, discarding any local changes.\n\n" +
               "Are you sure you want to continue?"
    result = UI.messagebox(question, MB_YESNO)
    return unless result == IDYES

    model = Sketchup.active_model
    model.start_operation("Reload All XRefs", true)
    reloaded_count = 0
    failed_names = []
    xref_definitions.each do |definition|
      if self.reload_single_xref_without_warning(definition.name, suppress_errors: true)
        reloaded_count += 1
      else
        failed_names << definition.name
      end
    end
    model.commit_operation
    
    message = "Reloaded #{reloaded_count} XRef(s)."
    unless failed_names.empty?
      message += "\n\nFailed to reload:\n" + failed_names.join("\n")
    end
    UI.messagebox(message)
    self.refresh_dialog_data
  end

  # The core logic for reloading an XRef from its file.
  def self.reload_single_xref_without_warning(component_name, suppress_errors: false)
    model = Sketchup.active_model
    # This is the original, "unloaded" definition (e.g., "Box")
    original_definition = model.definitions.find { |d| d.name == component_name }
    return false unless original_definition
    
    path = self.resolve_xref_path(original_definition)
    
    unless path && File.exist?(path)
      UI.messagebox("Cannot reload '#{component_name}'. File not found at:\n#{path}") unless suppress_errors
      return false
    end
    
    model.start_operation("Reload XRef: #{component_name}", true)
    
    success = false
    begin
      reloaded_definition = model.definitions.load(path)
      
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
        if dict
          dict.each_pair do |key, value|
            reloaded_definition.set_attribute(XREF_DICT_NAME, key, value)
          end
        end
        
        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
        # Clear the edited_without_lock flag when reloading
        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)
        
        # Remove XRef attributes from the OLD definition so it's
        # no longer tracked and can be purged.
        original_definition.attribute_dictionaries.delete(XREF_DICT_NAME)
                
        original_name = original_definition.name
        
        model.definitions.purge_unused
        
        if model.definitions[original_name].nil?
          reloaded_definition.name = original_name
        else
          # Purge failed (rare, but possible). We're stuck with 'Box#1'.
          puts "OpenXrefManager: Could not purge '#{original_name}'. " +
               "Reloaded XRef remains as '#{reloaded_definition.name}'."
        end
        self._update_xref_timestamp(reloaded_definition)
                
      elsif reloaded_definition && reloaded_definition == original_definition
        # This path happens if the definition was *already* purged.
        # In this case, just set the unloaded flag to false.
        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
        # Clear the edited_without_lock flag when reloading
        reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)
        self._update_xref_timestamp(reloaded_definition)
      end
      
      success = !reloaded_definition.nil?
      
    rescue => e
      UI.messagebox("Failed to reload #{component_name}.\nError: #{e.message}") unless suppress_errors
      success = false
    ensure
      model.commit_operation
    end

    self.refresh_dialog_data if success
    return success
  end
  
  # Finds all lock files owned by the current user with a specific (old) model GUID
  # and updates them with the new GUID. This is crucial for when a model is saved for the first time.
  def self.update_owned_lock_files(old_guid, new_guid)
    my_xrefs_to_update = self.get_xref_definitions.select do |definition|
      lock_content = self.get_xref_lock_status(definition)
      next false if lock_content == "unlocked"
      lock_owner_name, lock_owner_guid = lock_content.split('|')
      # Find files locked by this user with the old GUID
      lock_owner_name == @user_name && lock_owner_guid == old_guid
    end
    
    return if my_xrefs_to_update.empty?
    
    # This is a file system operation, not a model operation.
    my_xrefs_to_update.each do |definition|
      path = self.resolve_xref_path(definition)
      next unless path
      lock_path = path + ".lock"
      begin
        model_path = definition.model.path
        model_name = (model_path.nil? || model_path.empty?) ? "Untitled Model" : File.basename(model_path)
        model_path_str = model_path.nil? ? "" : model_path # Get the full path as a string
        lock_content = "#{@user_name}|#{new_guid}|#{model_name}|#{model_path_str}"

        File.write(lock_path, lock_content)
        @last_xref_statuses[definition.guid] = { lock_content: lock_content, update_available: _is_update_available?(definition) } # Update cache
      rescue => e
        puts "Could not update lock file #{lock_path}: #{e.message}"
      end
    end
  end

end
