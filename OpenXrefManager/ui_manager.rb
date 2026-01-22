require 'json'
require_relative 'core'
require_relative 'xref_manager'

module OpenXrefManager

  # --- UI Functions ---

  # Compiles all XRef data into a JSON string for the UI dialog.
  def self.get_xref_data_as_json
    model = Sketchup.active_model
    return "[]" unless model
    
    xref_definitions = get_xref_definitions.sort_by { |d| d.name.downcase }
    
    data = xref_definitions.map do |definition|
      path = resolve_xref_path(definition)
      stored_path = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY)
      path_type = definition.get_attribute(XREF_DICT_NAME, XREF_PATH_TYPE_KEY, "absolute")
      is_unloaded = definition.get_attribute(XREF_DICT_NAME, XREF_UNLOADED_KEY, false)
      
      lock_content = get_xref_lock_status(definition)
      is_locked = lock_content != "unlocked"
      lock_owner_name = ""
      lock_model = ""
      lock_model_path = ""
      
      if is_locked
        lock_owner_name, lock_owner_guid, lock_model, lock_model_path = lock_content.split('|')
      end
      
      update_available = _is_update_available?(definition)
      
      # Check for readonly checkout
      is_readonly = is_readonly_checkout?(definition)
      readonly_modified = definition.get_attribute(XREF_DICT_NAME, XREF_READONLY_MODIFIED_KEY, false)
      
      status = "Available"
      status_key = "ok"
      
      if !path || !File.exist?(path)
        status = "File Not Found"
        status_key = "not_found"
      elsif is_unloaded
        status = "Unloaded"
        status_key = "unloaded"
      elsif is_readonly
        # Readonly checkout takes precedence
        if lock_owner_name && !lock_owner_name.empty?
          status = "Read-Only Checkout (Locked by #{lock_owner_name})"
        else
          status = "Read-Only Checkout"
        end
        status_key = "readonly_checkout"
        # If modified in readonly checkout, show as update available
        if readonly_modified
          update_available = true
        end
      elsif is_locked
        if lock_owner_name == @user_name
           if lock_owner_guid == model.guid
             status = "Checked Out (You)"
             status_key = "mine"
           else
             status = "Checked Out (You, elsewhere)"
             status_key = "mine_elsewhere"
           end
        else
           status = "Locked by #{lock_owner_name}"
           status_key = "locked"
        end
      elsif update_available
        status = "Update Available"
        status_key = "update_available"
      end

      # Get last publisher info
      last_publisher_name = definition.get_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_NAME_KEY)
      last_publisher_model = definition.get_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_MODEL_KEY)
      last_publisher_path = definition.get_attribute(XREF_DICT_NAME, XREF_LAST_PUBLISHER_PATH_KEY)
      
      # Determine if we can use relative paths (model must be saved)
      can_be_relative = !model.path.nil? && !model.path.empty?
      
      # Check travel-through mode
      travel_through_enabled = is_travel_through_enabled?(definition)
      nested_xrefs = find_nested_xrefs(definition)
      has_nested_xrefs = !nested_xrefs.empty?
      
      {
        name: definition.name,
        path: path || "Missing",
        stored_path: stored_path,
        path_type: path_type,
        can_be_relative: can_be_relative,
        status: status,
        status_key: status_key,
        is_locked: is_locked,
        lock_owner_name: lock_owner_name,
        lock_model: lock_model,
        lock_model_path: lock_model_path,
        update_available: update_available,
        timestamp: definition.get_attribute(XREF_DICT_NAME, XREF_TIMESTAMP_KEY),
        file_timestamp: (path && File.exist?(path)) ? File.mtime(path).to_i : nil,
        is_unloaded: is_unloaded,
        found: (path && File.exist?(path)),
        last_publisher_name: last_publisher_name,
        last_publisher_path: last_publisher_path,
        travel_through_enabled: travel_through_enabled,
        has_nested_xrefs: has_nested_xrefs,
        is_readonly_checkout: is_readonly,
        readonly_modified: readonly_modified
      }
    end
    
    data.to_json
  end

  # Creates and shows the main XRef Manager dialog.
  def self.show_manager_dialog
    if @dialog && @dialog.visible?
      @dialog.bring_to_front
    else
      html_path = File.join(__dir__, 'manager.html')
      
      options = {
        dialog_title: "Open XRef Manager v#{VERSION}",
        preferences_key: "OpenXrefManager_Dialog",
        style: UI::HtmlDialog::STYLE_DIALOG,
        resizable: true,
        width: 1000,
        height: 600,
        min_width: 800,
        min_height: 400
      }
      
      @dialog = UI::HtmlDialog.new(options)
      @dialog.set_file(html_path)
      
      @dialog.add_action_callback("refresh_data") do |action_context|
        self.refresh_dialog_data
      end
      
      @dialog.add_action_callback("close_dialog") do |action_context|
        @dialog.close
      end
      
      @dialog.add_action_callback("select_component_clicked") do |action_context, component_name|
        self.select_component_instances(component_name)
      end
      
      @dialog.add_action_callback("check_out_clicked") do |action_context, component_name|
        self.check_out_xref(component_name)
      end

      @dialog.add_action_callback("check_out_readonly_clicked") do |action_context, component_name|
        self.check_out_xref_readonly(component_name)
      end
      
      @dialog.add_action_callback("save_and_check_in_clicked") do |action_context, component_name|
        self.save_and_check_in_xref(component_name)
      end
      
      @dialog.add_action_callback("force_check_in_clicked") do |action_context, component_name|
        self.force_check_in_xref(component_name)
      end

      @dialog.add_action_callback("force_unlock_clicked") do |action_context, component_name|
        self.force_unlock_xref(component_name)
      end
      
      @dialog.add_action_callback("reload_single_clicked") do |action_context, component_name, is_update|
        # is_update is passed from JS as a boolean (or nil)
        if is_update
           # If it's an update, we don't need to warn about losing changes if we are just reloading from disk
           # BUT, if the user has made local changes, we SHOULD warn.
           # For now, let's stick to the safe behavior:
           self.reload_single_xref(component_name)
        else
           self.reload_single_xref(component_name)
        end
      end
      
      @dialog.add_action_callback("unload_single_clicked") do |action_context, component_name|
        self.unload_single_xref(component_name)
      end
      
      @dialog.add_action_callback("relink_clicked") do |action_context, component_name|
        self.relink_xref(component_name)
      end
      
      @dialog.add_action_callback("unlink_single_clicked") do |action_context, component_name|
        self.unlink_single_xref(component_name)
      end

      @dialog.add_action_callback("enable_travel_through_clicked") do |action_context, component_name|
        self.enable_travel_through(component_name)
      end

      @dialog.add_action_callback("disable_travel_through_clicked") do |action_context, component_name|
        self.disable_travel_through(component_name)
      end

      @dialog.add_action_callback("cancel_readonly_checkout_clicked") do |action_context, component_name|
        self.cancel_readonly_checkout(component_name)
      end

      @dialog.add_action_callback("publish_all_clicked") do |action_context, keep_locked_str|
        # Convert JavaScript boolean string to Ruby boolean
        keep_locked = (keep_locked_str == "true")
        # Save the preference for next time
        Sketchup.write_default("OpenXrefManager", "KeepLockedAfterPublish", keep_locked)
        self.save_and_check_in_all_my_xrefs(keep_locked: keep_locked)
      end
      
      @dialog.add_action_callback("get_keep_locked_preference") do |action_context|
        # Return the saved preference (default to false)
        keep_locked = Sketchup.read_default("OpenXrefManager", "KeepLockedAfterPublish", false)
        @dialog.execute_script("setKeepLockedCheckbox(#{keep_locked});")
      end
      
      @dialog.add_action_callback("get_monitoring_state") do |action_context|
        # Return the current monitoring paused state
        is_paused = self.monitoring_paused?
        @dialog.execute_script("setMonitoringButtonState(#{is_paused});")
      end
      
      @dialog.add_action_callback("purge_unused_clicked") do |action_context|
        self.purge_unused_xrefs
      end
      
      @dialog.add_action_callback("toggle_path_type_clicked") do |action_context, component_name|
        self.toggle_path_type(component_name)
      end
      
      @dialog.add_action_callback("set_user_clicked") do |action_context|
        self.set_user_name
      end
      
      @dialog.add_action_callback("settings_clicked") do |action_context|
        self.show_settings_dialog
      end
      
      @dialog.add_action_callback("pause_monitoring_clicked") do |action_context|
        self.pause_monitoring
      end
      
      @dialog.add_action_callback("resume_monitoring_clicked") do |action_context|
        self.resume_monitoring
      end
      
      @dialog.add_action_callback("reload_all_clicked") do |action_context|
        self.reload_all_xrefs
      end
      
      @dialog.add_action_callback("import_origin_clicked") do |action_context|
        self.import_as_xref_at_origin
      end
      
      @dialog.add_action_callback("import_place_clicked") do |action_context|
        self.import_as_xref
      end
      
      @dialog.add_action_callback("create_xref_clicked") do |action_context|
        self.create_xref_from_component
      end

      # New callback for JS confirmation dialogs
      @dialog.add_action_callback("request_confirmation") do |action_context, message, callback_name, param|
        result = UI.messagebox(message, MB_YESNO)
        if result == IDYES
          # Call the specified JS function with the parameter if confirmed
          @dialog.execute_script("#{callback_name}('#{param}')")
        end
      end
      
      @dialog.center
      @dialog.show
    end
  end

  # Sends the latest XRef data to the HTML Dialog.
  def self.refresh_dialog_data
    if @dialog && @dialog.visible?
      json_data = self.get_xref_data_as_json
      # Escape backslashes first, then single quotes
      safe_json = json_data.gsub('\\', '\\\\\\\\').gsub("'", "\\\\'")
      @dialog.execute_script("updateTable(JSON.parse('#{safe_json}'));")
    end
  end

  # Selects all instances of a given component definition in the model.
  def self.select_component_instances(component_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return unless definition
    
    instances = definition.instances
    if instances.empty?
      UI.messagebox("No instances of '#{component_name}' found in the model.")
    else
      model.selection.clear
      model.selection.add(instances)
    end
  end

  # Helper method to ask user if they want to publish changes before continuing with an operation.
  # Returns: true if operation should proceed, false if user cancelled
  def self.ask_publish_before_operation?(component_name, operation_name)
    model = Sketchup.active_model
    definition = model.definitions.find { |d| d.name == component_name }
    return true unless definition # Should not happen
    
    # Check if we have it checked out
    if self.xref_has_uncommitted_changes?(definition)
       # Check if we *actually* modified it? 
       # SketchUp doesn't easily track "dirty" state of components unless we track it ourselves.
       # But we have the 'edited_without_lock' flag, maybe we should add a 'modified' flag?
       # For now, assume if it's checked out, it might have changes.
       
       question = "You have '#{component_name}' checked out.\n\n" +
                  "Do you want to Save & Check In your changes before you #{operation_name}?\n\n" +
                  "Yes = Save & Check In, then proceed\n" +
                  "No = Discard changes and proceed\n" +
                  "Cancel = Abort operation"
                  
       result = UI.messagebox(question, MB_YESNOCANCEL)
       
       if result == IDYES
         self.save_and_check_in_xref(component_name)
         return true
       elsif result == IDNO
         return true
       else # IDCANCEL
         return false
       end
    end
    
    # Also check if we edited it without locking
    was_edited_without_lock = definition.get_attribute(XREF_DICT_NAME, XREF_EDITED_WITHOUT_LOCK_KEY, false)
    if was_edited_without_lock
       question = "You have modified '#{component_name}' without checking it out.\n\n" +
                  "Do you want to Save & Check In (try to acquire lock) before you #{operation_name}?\n\n" +
                  "Yes = Try to Save & Check In, then proceed\n" +
                  "No = Discard changes and proceed\n" +
                  "Cancel = Abort operation"
       
       result = UI.messagebox(question, MB_YESNOCANCEL)
       
       if result == IDYES
         # Try to check in
         self.save_and_check_in_xref(component_name)
         return true
       elsif result == IDNO
         return true
       else
         return false
       end
    end

    return true
  end

  # Helper method to show a confirmation dialog.
  # Returns true if the user wants to continue (lose changes), false otherwise.
  def self.confirm_close_with_uncommitted_changes?(action_text = "continue")
    question = "You have XRefs checked out in this model.\n\n" +
               "If you #{action_text} without saving them, your changes to the XRef files will be lost.\n" +
               "(The changes will remain in this model file, but won't be pushed to the XRefs)\n\n" +
               "Do you want to open the XRef Manager to Publish them first?"
               
    # Yes = Open Manager, No = Continue without publishing (danger), Cancel = Cancel action
    result = UI.messagebox(question, MB_YESNOCANCEL)
    
    if result == IDYES
      self.show_manager_dialog
      return false # Abort the original action (e.g. closing model) so user can publish
    elsif result == IDNO
      return true # User explicitly said "No, I don't want to publish", so proceed.
    else
      return false # Cancel
    end
  end

end
