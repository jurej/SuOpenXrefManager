# v1.3.2
# Copyright (c) 2025 Your Name or Company Name
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

require 'pathname' # Required for relative path calculations

module OpenXrefManager

  # --- Constants ---
  XREF_DICT_NAME = "OpenXrefManager::Xref"
  XREF_PATH_KEY = "path"
  XREF_PATH_TYPE_KEY = "path_type" # "absolute" or "relative"
  XREF_UNLOADED_KEY = "is_unloaded" # true or false
  TIMER_INTERVAL = 5 # Seconds between background checks
  
  # Messagebox Result Constants
  MB_YESNO = 4
  IDYES = 6
  IDNO = 7
  IDCANCEL = 2

  # --- Module State ---
  @dialog = nil
  @user_name = ENV['USERNAME'] || ENV['USER'] || 'Unknown'
  @timer = nil
  @last_xref_statuses = {}
  
  # Using a class variable to hold observer instances to ensure they are not garbage collected.
  @@app_observer = nil

  # --- Helper Methods ---
  
  # Resolves the full, absolute path for an XRef definition, accounting for relative paths.
  def self.resolve_xref_path(definition)
    model = definition.model
    path = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY)
    path_type = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY)
    return nil unless path && !path.empty?

    # If the path is relative and the model has been saved, construct the absolute path.
    if path_type == "relative" && model.path && !model.path.empty?
      model_dir = File.dirname(model.path)
      return File.expand_path(File.join(model_dir, path))
    else
      # Otherwise, assume it's an absolute path.
      return path
    end
  end

  # Returns an array of all component definitions in the active model that are marked as XRefs.
  def self.get_xref_definitions
    model = Sketchup.active_model
    return [] unless model && model.valid?
    model.definitions.select { |d| is_xref?(d) }
  end

  # Checks if a given definition is an XRef by looking for the attribute dictionary.
  def self.is_xref?(definition)
    return false unless definition && definition.valid?
    !definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY).nil?
  end
  
  # Reads the lock file for a given XRef and returns its content (owner|guid).
  def self.get_xref_lock_status(definition)
    path = self.resolve_xref_path(definition)
    return "unlocked" unless path
    lock_path = path + ".lock"
    return "unlocked" unless File.exist?(lock_path)
    
    begin
      return File.read(lock_path).strip
    rescue => e
      puts "Error reading lock file #{lock_path}: #{e.message}"
      return "unlocked" # Treat as unlocked if lock file is unreadable
    end
  end

  # Locks or unlocks all instances of a given definition.
  def self.lock_or_unlock_instances_for_definition(definition, should_be_locked)
    return unless definition && definition.valid?
    definition.instances.each do |instance|
      instance.locked = should_be_locked if instance.valid? && instance.locked? != should_be_locked
    end
  end

  # Compiles all XRef data into a JSON string for the UI dialog.
  def self.get_xref_data_as_json
    model = Sketchup.active_model
    return [].to_json unless model && model.valid?
    current_guid = model.guid

    data = get_xref_definitions.map do |definition|
      absolute_path = self.resolve_xref_path(definition)
      stored_path = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY)
      file_found = absolute_path && File.exist?(absolute_path)
      path_type = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY) || "absolute"
      can_be_relative = model.path && !model.path.empty?
      is_unloaded = definition.get_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY) == true
      
      lock_content = self.get_xref_lock_status(definition)
      is_locked = lock_content != "unlocked"
      lock_model_name = nil
      lock_model_path = nil
      
      status_text = "Available"
      status_key = "ok"
      
      if is_unloaded
        status_text = "Unloaded"
        status_key = "unloaded"
      elsif !file_found
        status_text = "File Not Found"
        status_key = "not_found"
      elsif is_locked
        lock_owner_name, lock_owner_guid, lock_model_name, lock_model_path = lock_content.split('|')
        lock_model_name ||= "Untitled Model" # Fallback for old lock files
        lock_model_path ||= "" # Fallback

        if lock_owner_name == @user_name
          status_key = (lock_owner_guid == current_guid) ? "mine" : "mine_elsewhere"
          status_text = "Checked Out by You" + (status_key == "mine_elsewhere" ? " (in another model)" : "")
        else
          status_text = "Locked by #{lock_owner_name}"
          status_key = "locked"
        end
      end
      
      { 
        name: definition.name, 
        path: absolute_path, 
        stored_path: stored_path,
        status: status_text, 
        status_key: status_key, 
        found: file_found,
        path_type: path_type,
        can_be_relative: can_be_relative,
        lock_model: lock_model_name,
        lock_model_path: lock_model_path,
        is_unloaded: is_unloaded
      }
    end
    return data.to_json
  end

  # --- Live Update Timer ---
  
  # Starts the background timer to check for changes in XRef lock files.
  def self.start_timer
    self.stop_timer # Ensure no duplicate timers are running
    #puts "Open XRef background monitor is running..."
    self.check_for_status_changes(show_notification: false) # Initial check
    @timer = UI.start_timer(TIMER_INTERVAL, true) do
      self.check_for_status_changes
    end
  end
  
  # Stops the background timer.
  def self.stop_timer
    if @timer
      UI.stop_timer(@timer)
      @timer = nil
      puts "Stopping Open XRef background monitor."
    end
  end
  
  # Checks all XRefs for changes in their lock status and updates instance locks.
  def self.check_for_status_changes(show_notification: true)
    model = Sketchup.active_model
    return unless model && model.valid?
    current_guid = model.guid
    something_changed = false

    get_xref_definitions.each do |definition|
      current_lock_content = self.get_xref_lock_status(definition)
      is_locked = current_lock_content != "unlocked"
      is_mine_in_this_window = false
      
      if is_locked
        lock_owner_name, lock_owner_guid, _, _ = current_lock_content.split('|')
        is_mine_in_this_window = (lock_owner_name == @user_name && lock_owner_guid == current_guid)
      end
      
      # Lock instances if the XRef is locked by someone else.
      self.lock_or_unlock_instances_for_definition(definition, is_locked && !is_mine_in_this_window)

      # Compare with last known status to see if a notification is needed.
      last_lock_content = @last_xref_statuses[definition.guid] || "unlocked"
      if current_lock_content != last_lock_content
        something_changed = true
        if show_notification
          if !is_locked
            Sketchup.set_status_text("XRef Status: '#{definition.name}' was checked in.")
          else
            lock_owner_name, _, lock_model_name, _ = current_lock_content.split('|')
            lock_model_name ||= "an unsaved model"
            Sketchup.set_status_text("XRef Status: '#{definition.name}' was checked out by #{lock_owner_name} in '#{lock_model_name}'.")
          end
        end
      end
      @last_xref_statuses[definition.guid] = current_lock_content
    end
    
    # Refresh the dialog if something changed
    self.refresh_dialog_data if something_changed
  end

  # --- UI Functions ---
  
  # Creates and shows the main XRef Manager dialog.
  def self.show_manager_dialog
    if @dialog && @dialog.visible?
      @dialog.bring_to_front
      return
    end
    
    @dialog = UI::HtmlDialog.new({
      dialog_title: "Open XRef Manager",
      preferences_key: "com.openxref.manager",
      scrollable: true,
      resizable: true,
      width: 850,
      height: 450,
      style: UI::HtmlDialog::STYLE_DIALOG
    })
    
    html_file = File.join(__dir__, 'manager.html')
    @dialog.set_file(html_file)
    
    # Register callbacks for actions triggered from the JavaScript UI.
    @dialog.add_action_callback("refresh_data") { |ctx| self.refresh_dialog_data }
    @dialog.add_action_callback("publish_all_clicked") { |ctx| self.save_and_check_in_all_my_xrefs }
    @dialog.add_action_callback("reload_single_clicked") { |ctx, name| self.reload_single_xref(name) }
    @dialog.add_action_callback("unlink_single_clicked") { |ctx, name| self.unlink_single_xref(name) }
    @dialog.add_action_callback("check_out_clicked") { |ctx, name| self.check_out_xref(name) }
    @dialog.add_action_callback("save_and_check_in_clicked") { |ctx, name| self.save_and_check_in_xref(name) }
    @dialog.add_action_callback("force_check_in_clicked") { |ctx, name| self.force_check_in_xref(name) }
    @dialog.add_action_callback("force_unlock_clicked") { |ctx, name| self.force_unlock_xref(name) }
    @dialog.add_action_callback("purge_unused_clicked") { |ctx| self.purge_unused_xrefs }
    @dialog.add_action_callback("relink_clicked") { |ctx, name| self.relink_xref(name) }
    @dialog.add_action_callback("unload_single_clicked") { |ctx, name| self.unload_single_xref(name) }
    @dialog.add_action_callback("toggle_path_type_clicked") { |ctx, name| self.toggle_path_type(name) }
    @dialog.add_action_callback("select_component_clicked") { |ctx, name| self.select_component_instances(name) }
    @dialog.add_action_callback("close_dialog") { |ctx| @dialog.close }
    
    @dialog.set_on_closed { @dialog = nil }
    @dialog.show
  end
  
  # Sends the latest XRef data to the HTML Dialog.
  def self.refresh_dialog_data
    return unless @dialog && @dialog.visible?
    json_data = self.get_xref_data_as_json
    @dialog.execute_script("updateTable(#{json_data})")
    nil
  end
  
  # Selects all instances of a given component definition in the model.
  def self.select_component_instances(component_name)
    model = Sketchup.active_model
    return unless model && model.valid?
    
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    
    # Only proceed if there are instances to select.
    return if definition.instances.empty?
    
    model.selection.clear
    model.selection.add(definition.instances)
    
    # Bring SketchUp to the front to show the selection.
    Sketchup.focus
    
    # Zoom to the new selection.
    view = model.active_view
    view.zoom_extents if model.selection.length > 0
  end

  # Prompts the user to set their name for locking.
  def self.set_user_name
    prompts = ["Enter your name for XRef locking:"]
    defaults = [@user_name]
    input = UI.inputbox(prompts, defaults, "Set XRef User Name")
    @user_name = input[0].strip if input && input[0]
  end

  # --- Core Xref Functions ---
  
  # Toggles an XRef's path between absolute and relative.
  def self.toggle_path_type(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    current_path = self.resolve_xref_path(definition) # Use resolved path
    current_type = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY) || "absolute"

    model.start_operation("Toggle XRef Path Type", true)

    if current_type == "absolute"
      if model.path && !model.path.empty?
        model_dir = Pathname.new(File.dirname(model.path))
        xref_path = Pathname.new(current_path)
        begin
          relative_path = xref_path.relative_path_from(model_dir).to_s
          definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, relative_path)
          definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "relative")
        rescue ArgumentError # Happens if paths are on different drives on Windows
          UI.messagebox("Cannot create a relative path. The XRef file appears to be on a different drive than the model file.")
        end
      else
        UI.messagebox("The main model must be saved to create a relative path.")
      end
    else # "relative"
      absolute_path = self.resolve_xref_path(definition)
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, absolute_path)
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")
    end

    model.commit_operation
    self.refresh_dialog_data
  end

  # Allows the user to select a new file path for an existing XRef.
  def self.relink_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    
    path_to_relink = UI.openpanel("Select new file for '#{component_name}'", "", "*.skp")
    return unless path_to_relink

    model.start_operation("Relink XRef", true)
    
    self._set_xref_path(definition, path_to_relink, ask_user: true) # Ask about relative/absolute
    
    question = "Relink successful.\n\nDo you want to reload '#{component_name}' from the new location now?"
    result = UI.messagebox(question, MB_YESNO)
    if result == IDYES
      self.reload_single_xref_without_warning(component_name)
    end
    
    model.commit_operation
    self.refresh_dialog_data
  end
  
  # Internal helper to set the path attribute, with an option to ask the user about relative paths.
  def self._set_xref_path(definition, absolute_path, ask_user: true)
    model = definition.model
    use_relative = false
    
    if ask_user && model.path && !model.path.empty?
      question = "Would you like to save this XRef with a relative path?\n\n" +
                 "Relative paths are recommended for projects where the main file and XRefs are stored together and might be moved."
      result = UI.messagebox(question, MB_YESNO)
      use_relative = (result == IDYES)
    end
    
    if use_relative
      model_dir = Pathname.new(File.dirname(model.path))
      xref_path = Pathname.new(absolute_path)
      relative_path = xref_path.relative_path_from(model_dir).to_s
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, relative_path)
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "relative")
    else
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_KEY, absolute_path)
      definition.set_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")
    end
    self.refresh_dialog_data
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
      model.start_operation("Force Unlock XRef", true)
      begin
        was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }        
        File.delete(lock_path)
        model.close_active if was_editing
      rescue => e
        UI.messagebox("Could not delete lock file:\n#{e.message}")
      end
      model.commit_operation
      self.check_for_status_changes(show_notification: false)
    else
      UI.beep
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
        @last_xref_statuses[definition.guid] = lock_content
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
  
  # Internal helper to save a definition and remove its lock file.
  def self._silent_save_and_check_in(definition)
    path = self.resolve_xref_path(definition)
    return false unless path
    begin
      definition.save_as(path)
      lock_path = path + ".lock"
      File.delete(lock_path) if File.exist?(lock_path)
      @last_xref_statuses[definition.guid] = "unlocked"
      return true
    rescue => e
      UI.messagebox("Failed to save component '#{definition.name}'.\nError: #{e.message}")
      return false
    end
    self.refresh_dialog_data
  end

  # Saves and checks in all XRefs currently checked out by the user in this model.
  def self.save_and_check_in_all_my_xrefs
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

    model.start_operation("Save & Check In All My XRefs", true)

    # Check if we are currently editing any of the XRefs being checked in.
    was_editing_an_xref = false
    if model.active_path
      was_editing_an_xref = model.active_path.any? do |instance|
        my_xrefs.include?(instance.definition)
      end
    end

    my_xrefs.each do |definition|
      self._silent_save_and_check_in(definition)
    end
    model.close_active if was_editing_an_xref
    model.commit_operation

    self.check_for_status_changes(show_notification: false)
    self.refresh_dialog_data

  end
  
  # Saves and checks in a single XRef.
  def self.save_and_check_in_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition

    lock_content = self.get_xref_lock_status(definition)
    lock_owner_name, lock_owner_guid = lock_content.split('|')
    
    if lock_owner_name == @user_name && lock_owner_guid == model.guid
      model.start_operation("Save & Check In XRef", true)
      was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }
      self._silent_save_and_check_in(definition)
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

  # Imports a .skp file as a new XRef and places it for the user to position.
  def self.import_as_xref
    model = Sketchup.active_model
    path = UI.openpanel("Import XRef file", "", "*.skp")
    return unless path
    
    model.start_operation("Import as XRef", true)
    begin
      new_definition = model.definitions.load(path)
      self._set_xref_path(new_definition, path, ask_user: true)
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
    path = UI.openpanel("Import XRef at Origin", "", "*.skp")
    return unless path
    model.start_operation("Import XRef at Origin", true)
    begin
      new_definition = model.definitions.load(path)
      self._set_xref_path(new_definition, path, ask_user: true)
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
    rescue => e
      UI.messagebox("Failed to save new XRef file.\nError: #{e.message}")
      model.abort_operation
      return
    end
    
    model.commit_operation
    self.refresh_dialog_data
  end

  # Reloads a single XRef after confirming with the user.
  def self.reload_single_xref(component_name)
    question = "Reloading '#{component_name}' will discard any changes made to it in the current model.\n\n" +
               "Are you sure you want to continue?"
    result = UI.messagebox(question, MB_YESNO)
    return unless result == IDYES

    self.reload_single_xref_without_warning(component_name)
    self.refresh_dialog_data
  end

  # Removes the XRef link from a component, making it a regular, internal component.
  def self.unlink_single_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    
    model.start_operation("Unlink XRef", true)
    was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }
    definition.attribute_dictionaries.delete(XREF_DICT_NAME)
    self.lock_or_unlock_instances_for_definition(definition, false)
    model.close_active if was_editing
    model.commit_operation
    self.refresh_dialog_data
  end

  # Unloads an XRef's geometry to improve performance.
  def self.unload_single_xref(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    
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
        @last_xref_statuses[definition.guid] = "unlocked" # Update cache
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
    self.check_for_status_changes(show_notification: false)
  end

  # Reloads all XRefs in the model after confirmation.
  def self.reload_all_xrefs
    xref_definitions = self.get_xref_definitions
    return UI.messagebox("No XRefs to reload.") if xref_definitions.empty?

    question = "This will reload all linked XRefs, discarding any local changes.\n\n" +
               "Are you sure you want to continue?"
    result = UI.messagebox(question, MB_YESNO)
    return unless result == IDYES

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
                
      elsif reloaded_definition && reloaded_definition == original_definition
         # This path happens if the definition was *already* purged.
         # In this case, just set the unloaded flag to false.
         reloaded_definition.set_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
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
        @last_xref_statuses[definition.guid] = lock_content # Update cache
      rescue => e
        puts "Could not update lock file #{lock_path}: #{e.message}"
      end
    end
  end


  # --- Observers ---
  
  # Observes entity modifications to prevent unlocking of checked-out XRefs.
  class OpenXrefEntitiesObserver < Sketchup::EntitiesObserver
    def onElementModified(entities, entity)
      # We only care about instances that have been unlocked.
      return unless entity.is_a?(Sketchup::ComponentInstance) && !entity.locked?
      
      definition = entity.definition
      return unless OpenXrefManager.is_xref?(definition)

      lock_content = OpenXrefManager.get_xref_lock_status(definition)
      return if lock_content == "unlocked"

      lock_owner_name, lock_owner_guid, lock_model_name, _ = lock_content.split('|')
      lock_model_name ||= "an unsaved model"
      is_mine_in_this_window = (lock_owner_name == OpenXrefManager.instance_variable_get(:@user_name) && lock_owner_guid == entities.model.guid)
      
      # If the instance was unlocked, but shouldn't have been, re-lock it immediately.
      unless is_mine_in_this_window
        # Use a short timer to avoid issues with modifying the model during a notification.
        UI.start_timer(0.01, false) do
          entity.locked = true if entity.valid?
          Sketchup.set_status_text("Cannot unlock: '#{definition.name}' is checked out by #{lock_owner_name} in '#{lock_model_name}'.")        end
      end
    end
  end

  # Observes model-level events.
  class OpenXrefModelObserver < Sketchup::ModelObserver
    def initialize
      @definition_to_relink = nil
      @guid_before_save = Sketchup.active_model.guid
    end

    # Re-check status after an undo operation.
    def onTransactionUndo(model)
      UI.start_timer(0.1, false) { OpenXrefManager.check_for_status_changes(show_notification: false) }
    end

    # Add an observer for when the model is saved.
    def onSaveModel(model)
      new_guid = model.guid
      # If the GUID changed after saving,
      # find all lock files owned by this user from the previous session state and update them.
      if @guid_before_save != new_guid
        OpenXrefManager.update_owned_lock_files(@guid_before_save, new_guid)
        @guid_before_save = new_guid # Update the stored GUID for the next save.
      end

      # Run a status check after a save to refresh the UI.
      UI.start_timer(0.1, false) { OpenXrefManager.check_for_status_changes(show_notification: false) }
    end
    
    # Handles auto-checkout when a user starts editing an XRef.
    def onActivePathChanged(model)
      return unless model.active_path # Path is nil when exiting to top level.
      instance = model.active_path.last
      return unless instance.is_a?(Sketchup::ComponentInstance)
      
      definition = instance.definition
      return unless OpenXrefManager.is_xref?(definition)
      
      lock_content = OpenXrefManager.get_xref_lock_status(definition)
      is_unlocked = lock_content == "unlocked"
      
      # Check if it's locked by this user, but in a different SketchUp window/model.
      is_mine_elsewhere = false
      if !is_unlocked
        lock_owner_name, lock_owner_guid, _, _ = lock_content.split('|')
        is_mine_elsewhere = (lock_owner_name == OpenXrefManager.instance_variable_get(:@user_name) && lock_owner_guid != model.guid)
      end

      # If the component is available or locked by us elsewhere, prompt to check it out.
      return unless is_unlocked || is_mine_elsewhere

      UI.start_timer(0.1, false) do
        message = "You are about to edit the '#{definition.name}' XRef component.\n\n"
        message += is_mine_elsewhere ? "Taking ownership from your other session...\n\n" : ""
        message += "The component will be checked out to you automatically."
        UI.messagebox(message)

        # Force unlock if it was ours elsewhere, then check it out here.
        OpenXrefManager.force_unlock_xref(definition.name) if is_mine_elsewhere
        OpenXrefManager.check_out_xref(definition.name)
      end
    end

    # This method is called BEFORE SketchUp shows the 'Save As' dialog.
    def onBeforeComponentSaveAs(instance)
      definition = instance.definition
      return true unless OpenXrefManager.is_xref?(definition)

      question = "Warning: You are using SketchUp's native 'Save As' on a linked XRef ('#{definition.name}').\n\n" +
                 "This will create a new, separate component file. The XRef link will be updated to point to the new file.\n\n" +
                 "Do you want to continue?"
      result = UI.messagebox(question, MB_YESNO)
      
      if result == IDYES
        @definition_to_relink = definition
        return true # Allow the save operation.
      else
        return false # Prevent the save operation.
      end
    end

    # This method is called AFTER the 'Save As' operation completes.
    def onAfterComponentSaveAs(instance)
      return unless @definition_to_relink && @definition_to_relink.valid?
      
      definition = @definition_to_relink
      @definition_to_relink = nil 

      new_path = definition.path
      OpenXrefManager._set_xref_path(definition, new_path, ask_user: true)
      
      OpenXrefManager.refresh_dialog_data
      Sketchup.set_status_text("XRef '#{definition.name}' link updated to new file.")
    end
    
  end

  # Observes application-level events like opening new models.
  class OpenXrefAppObserver < Sketchup::AppObserver
    def initialize
      @model_observers = {}
      @entities_observers = {}
    end

    def onNewModel(model)
      attach_observers(model)
      OpenXrefManager.refresh_dialog_data
    end
    def onOpenModel(model)
      attach_observers(model)
      OpenXrefManager.refresh_dialog_data
    end
    def onQuit()
      OpenXrefManager.stop_timer
    end
    
    # Attaches model and entities observers to a given model.
    def attach_observers(model)
      detach_observers(model) # Ensure no old observers are lingering
      
      OpenXrefManager.instance_variable_set(:@last_xref_statuses, {})
      
      model_observer = OpenXrefModelObserver.new
      model.add_observer(model_observer)
      @model_observers[model.guid] = model_observer
      
      entities_observer = OpenXrefEntitiesObserver.new
      model.entities.add_observer(entities_observer)
      @entities_observers[model.guid] = entities_observer
      
      OpenXrefManager.start_timer
    end

    # Detaches observers to prevent memory leaks when models are closed.
    def detach_observers(model)
      if (observer = @model_observers[model.guid])
         model.remove_observer(observer)
         @model_observers.delete(model.guid)
      end
      if (observer = @entities_observers[model.guid])
         model.entities.remove_observer(observer)
         @entities_observers.delete(model.guid)
      end
    end
  end

  # --- Menu and Toolbar Setup ---
  unless file_loaded?(__FILE__)
    
    @@app_observer = OpenXrefAppObserver.new
    Sketchup.add_observer(@@app_observer)

    if Sketchup.active_model
      @@app_observer.attach_observers(Sketchup.active_model)
    end
    
    # --- Toolbar ---
    toolbar = UI::Toolbar.new("Open XRef")

    cmd_manager = UI::Command.new("XRef Manager") { self.show_manager_dialog }
    cmd_manager.tooltip = "Open the XRef Manager"
    cmd_manager.small_icon = File.join(__dir__, "icons", "manager_icon.png")
    cmd_manager.large_icon = File.join(__dir__, "icons", "manager_icon.png")
    toolbar.add_item(cmd_manager)

    cmd_insert = UI::Command.new("Insert XRef at Origin") { self.import_as_xref_at_origin }
    cmd_insert.tooltip = "Insert an XRef at the Model Origin"
    cmd_insert.small_icon = File.join(__dir__, "icons", "insert_icon.png")
    cmd_insert.large_icon = File.join(__dir__, "icons", "insert_icon.png")
    toolbar.add_item(cmd_insert)

    cmd_publish = UI::Command.new("Save & Check In All") { self.save_and_check_in_all_my_xrefs }
    cmd_publish.tooltip = "Save & Check In all XRefs you have checked out in this model"
    cmd_publish.small_icon = File.join(__dir__, "icons", "publish_icon.png")
    cmd_publish.large_icon = File.join(__dir__, "icons", "publish_icon.png")
    toolbar.add_item(cmd_publish)
    
    toolbar.restore

    # --- Menus ---
    menu = UI.menu("Extensions").add_submenu("Open XRef")
    menu.add_item(cmd_manager)
    menu.add_item(cmd_publish)
    menu.add_item("Set User Name...") { self.set_user_name }
    menu.add_separator
    menu.add_item("Import XRef at Origin...") { self.import_as_xref_at_origin }
    menu.add_item("Import XRef (Place)...") { self.import_as_xref }
    menu.add_separator
    menu.add_item("Create XRef from Component...") { self.create_xref_from_component }
    menu.add_item("Reload All XRefs") { self.reload_all_xrefs }

    # --- Context Menu ---
    UI.add_context_menu_handler do |context_menu|
      model = Sketchup.active_model
      return unless model && model.valid?
      selection = model.selection
      
      submenu = context_menu.add_submenu("Open XRef")
      
      if selection.length == 1 && selection.first.is_a?(Sketchup::ComponentInstance)
        instance = selection.first
        definition = instance.definition
        
        if self.is_xref?(definition)
          submenu.add_item("Reload XRef") { self.reload_single_xref(definition.name) }
          
          lock_content = self.get_xref_lock_status(definition)
          is_locked = lock_content != "unlocked"

          if is_locked
            lock_owner_name, lock_owner_guid = lock_content.split('|')
            if lock_owner_name == @user_name && lock_owner_guid == model.guid
              submenu.add_item("Save & Check In XRef") { self.save_and_check_in_xref(definition.name) }
            else
              item = submenu.add_item("Locked by #{lock_owner_name}")
              item.set_validation_proc { MF_GRAYED }
            end
          else
            submenu.add_item("Check Out XRef") { self.check_out_xref(definition.name) }
          end
          
          submenu.add_separator
          submenu.add_item("Unlink XRef") { self.unlink_single_xref(definition.name) }
        else
          submenu.add_item("Create XRef from this Component...") { self.create_xref_from_component }
        end
      else
        submenu.add_item("Import XRef...") { self.import_as_xref }
      end
    end
    
    file_loaded(__FILE__)
  end

end

