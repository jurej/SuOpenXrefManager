require_relative 'core'

module OpenXrefManager

  # --- Observers ---
  
  # Observes entity modifications to prevent unlocking of checked-out XRefs.
  class OpenXrefEntitiesObserver < Sketchup::EntitiesObserver
    def onElementModified(entities, entity)
      # We only care about instances that have been unlocked.
      return unless entity.is_a?(Sketchup::ComponentInstance) && !entity.locked?
      
      definition = entity.definition
      return unless OpenXrefManager.is_xref?(definition)

      # Check both lock status and update status
      lock_content = OpenXrefManager.get_xref_lock_status(definition)
      is_locked_by_file = lock_content != "unlocked"
      is_mine_in_this_window = false
      lock_owner_name = nil
      lock_model_name = nil
      
      if is_locked_by_file
        lock_owner_name, lock_owner_guid, lock_model_name, _ = lock_content.split('|')
        lock_model_name ||= "an unsaved model"
        is_mine_in_this_window = (lock_owner_name == OpenXrefManager.instance_variable_get(:@user_name) && lock_owner_guid == entities.model.guid)
      end

      update_available = OpenXrefManager._is_update_available?(definition)

      # Determine if the instance should be forced back to a locked state
      # Re-lock if it's locked by someone else OR if an update is available.
      # BUT: Don't lock if travel-through mode is enabled (allows entry to nested XRefs)
      should_be_locked = ((is_locked_by_file && !is_mine_in_this_window) || update_available) && !OpenXrefManager.is_travel_through_enabled?(definition)
      
      if should_be_locked
        # Use a short timer to avoid issues with modifying the model during a notification.
        UI.start_timer(0.01, false) do
          entity.locked = true if entity.valid?
          
          # Set the appropriate status bar message
          if update_available
            Sketchup.set_status_text("Cannot unlock: '#{definition.name}' has an update available.")
          elsif is_locked_by_file # This must be true if update_available was false
            Sketchup.set_status_text("Cannot unlock: '#{definition.name}' is checked out by #{lock_owner_name} in '#{lock_model_name}'.")
          end
        end
      end
    end
  end

  # Observes model-level events.
  class OpenXrefModelObserver < Sketchup::ModelObserver
    def initialize
      @definition_to_relink = nil
      @guid_before_save = Sketchup.active_model.guid
      @operation_aborted = false
    end

    # Re-check status after an undo operation.
    def onTransactionUndo(model)
      # If a save was aborted, don't run subsequent observers
      if @operation_aborted
        @operation_aborted = false # Reset flag
        return
      end
      UI.start_timer(0.1, false) { OpenXrefManager.check_for_status_changes(show_notification: false) }
    end

    # Captures the GUID before the save operation starts.
    def onPreSaveModel(model)
      @guid_before_save = model.guid
    end

    # Add an observer for when the model is saved.
    def onSaveModel(model)
      # We used to check for uncommitted XRefs here and block the save, 
      # but that prevents valid WIP saves and triggers on Export.
      # Changes are safe in the main model file, so we allow the save.
      
      @operation_aborted = false # Reset flag

      new_guid = model.guid
      
      # If the GUID changed after saving,
      # find all lock files owned by this user from the previous session state and update them.
      if @guid_before_save != new_guid
        OpenXrefManager.update_owned_lock_files(@guid_before_save, new_guid)
        OpenXrefManager.update_travel_through_guids(@guid_before_save, new_guid)
        @guid_before_save = new_guid # Update the stored GUID for the next save.
      end

      # Run a status check after a save to refresh the UI.
      UI.start_timer(0.1, false) { OpenXrefManager.check_for_status_changes(show_notification: false) }
      return true # Explicitly allow save
    end
    
    # Handles auto-checkout when a user starts editing an XRef.
    def onActivePathChanged(model)
      # Clear travel-through active state when exiting to top level
      if model.active_path.nil?
        travel_through_active = OpenXrefManager.instance_variable_get(:@travel_through_active)
        if travel_through_active
          travel_through_active.clear
        end
        return
      end
      
      instance = model.active_path.last
      return unless instance.is_a?(Sketchup::ComponentInstance)
      
      definition = instance.definition
      return unless OpenXrefManager.is_xref?(definition)
      
      # Check if travel-through is enabled for this XRef OR any parent in the path
      # This handles both entering and navigating within travel-through mode (including exiting child XRefs)
      travel_through_enabled_for_current = OpenXrefManager.is_travel_through_enabled?(definition)
      
      # Also check if any parent in the path has travel-through enabled
      travel_through_enabled_for_parent = false
      model.active_path.each do |path_instance|
        next unless path_instance.is_a?(Sketchup::ComponentInstance)
        parent_def = path_instance.definition
        if OpenXrefManager.is_xref?(parent_def) && parent_def != definition && OpenXrefManager.is_travel_through_enabled?(parent_def)
          travel_through_enabled_for_parent = true
          break
        end
      end
      
      # Handle travel-through scenarios
      if travel_through_enabled_for_parent
        # Case A: We are inside a child, but a parent further up has travel-through enabled.
        # We need to mark the parent as active in the session state for navigation tracking.
        travel_through_active = OpenXrefManager.instance_variable_get(:@travel_through_active)
        if travel_through_active.nil?
          travel_through_active = {}
          OpenXrefManager.instance_variable_set(:@travel_through_active, travel_through_active)
        end
        
        # Find which parent has travel-through enabled
        model.active_path.each do |path_instance|
          next unless path_instance.is_a?(Sketchup::ComponentInstance)
          parent_def = path_instance.definition
          if OpenXrefManager.is_xref?(parent_def) && parent_def != definition && OpenXrefManager.is_travel_through_enabled?(parent_def)
            travel_through_active[parent_def.name] = true
            Sketchup.set_status_text("Travel-through mode: Navigating within '#{parent_def.name}'. Parent cannot be saved.")
            break 
          end
        end
        # IMPORTANT: Do NOT return here. We must proceed to verify standard lock checks for the CURRENT nested definition.
      
      elsif travel_through_enabled_for_current
         # Case B: We are entering (or exiting back into) the XRef that has travel-through ENABLED (The Parent).
         # We allow this unconditionally (bypassing lock checks) because that is the purpose of the feature.
         
         travel_through_active = OpenXrefManager.instance_variable_get(:@travel_through_active)
         if travel_through_active.nil?
           travel_through_active = {}
           OpenXrefManager.instance_variable_set(:@travel_through_active, travel_through_active)
         end
         travel_through_active[definition.name] = true
         
         # Check if there are nested XRefs (Sanity check)
         nested_xrefs = OpenXrefManager.find_nested_xrefs(definition)
         if nested_xrefs.empty?
           UI.start_timer(0.1, false) do
             UI.messagebox("Travel-through mode is enabled, but '#{definition.name}' does not contain any nested XRefs.")
             model.close_active if model.active_path
           end
           return
         end
         
         Sketchup.set_status_text("Travel-through mode: You can navigate to nested XRefs in '#{definition.name}'. Parent cannot be saved.")
         return # Allow entry/navigation - skip lock checks
      end
      
      # Check if we're in travel-through mode for a parent XRef (for nested XRefs)
      travel_through_active = OpenXrefManager.instance_variable_get(:@travel_through_active) || {}
      parent_in_travel_through = nil
      
      # Check if any parent in the path is in travel-through mode
      model.active_path.each do |path_instance|
        next unless path_instance.is_a?(Sketchup::ComponentInstance)
        parent_def = path_instance.definition
        if OpenXrefManager.is_xref?(parent_def) && travel_through_active[parent_def.name]
          parent_in_travel_through = parent_def
          break
        end
      end
      
      # If we're editing the parent that's in travel-through mode, prevent editing
      if parent_in_travel_through && definition == parent_in_travel_through
        UI.start_timer(0.1, false) do
          UI.messagebox("You are in travel-through mode for '#{definition.name}'.\n\nNavigate to a nested XRef to edit it. The parent XRef cannot be edited while in travel-through mode.")
          model.close_active if model.active_path
        end
        return
      end
      
      # Prevent editing if an update is available and it's locked by someone else.
      update_available = OpenXrefManager._is_update_available?(definition)
      lock_content = OpenXrefManager.get_xref_lock_status(definition)
      is_unlocked = lock_content == "unlocked"
      is_locked_by_other = false
      
      if !is_unlocked
        lock_owner_name, lock_owner_guid, _, _ = lock_content.split('|')
        user_name = OpenXrefManager.instance_variable_get(:@user_name)
        is_locked_by_other = (lock_owner_name != user_name || lock_owner_guid != model.guid)
      end
      
      # If locked by someone else and update available, prevent editing
      if update_available && is_locked_by_other
        UI.start_timer(0.1, false) do
          UI.messagebox("This XRef has an update available and is checked out by another user. Please update it from the XRef Manager before editing.")
          model.close_active if model.active_path # Exit the component edit context
        end
        return
      end
      
      # Check if it's locked by this user, but in a different SketchUp window/model.
      is_mine_elsewhere = false
      if !is_unlocked
        lock_owner_name, lock_owner_guid, _, _ = lock_content.split('|')
        is_mine_elsewhere = (lock_owner_name == OpenXrefManager.instance_variable_get(:@user_name) && lock_owner_guid != model.guid)
      end

      # Check if travel-through is enabled (works for both locked by others and locked by same user elsewhere)
      # This handles initial entry into travel-through mode
      if (is_locked_by_other || is_mine_elsewhere) && OpenXrefManager.is_travel_through_enabled?(definition)
        # Travel-through is enabled - allow entry but mark as travel-through mode
        OpenXrefManager.instance_variable_set(:@travel_through_active, {}) unless OpenXrefManager.instance_variable_get(:@travel_through_active)
        OpenXrefManager.instance_variable_get(:@travel_through_active)[definition.guid] = true
        
        # Check if there are nested XRefs
        nested_xrefs = OpenXrefManager.find_nested_xrefs(definition)
        if nested_xrefs.empty?
          UI.start_timer(0.1, false) do
            UI.messagebox("Travel-through mode is enabled, but '#{definition.name}' does not contain any nested XRefs.")
            model.close_active if model.active_path
          end
          return
        end
        
        # Allow entry - user can navigate to nested XRefs
        Sketchup.set_status_text("Travel-through mode: You can navigate to nested XRefs in '#{definition.name}'. Parent cannot be saved.")
        return # Allow entry
      end

      # Check if readonly checkout is already active - mark as modified when entering edit mode
      if OpenXrefManager.is_readonly_checkout?(definition)
        # User is entering edit mode for readonly checkout XRef - mark as modified
        definition.set_attribute(OpenXrefManager::XREF_DICT_NAME, OpenXrefManager::XREF_READONLY_MODIFIED_KEY, true)
        # Allow entry - readonly checkout already active
        return
      end

      # If locked by someone else (not us), offer readonly checkout option
      if is_locked_by_other
        UI.start_timer(0.1, false) do
          lock_owner_name, _, lock_model_name, _ = lock_content.split('|')
          lock_model_name ||= "an unsaved model"
          
          message = "'#{definition.name}' is checked out by #{lock_owner_name} in '#{lock_model_name}'.\n\n"
          message += "You can check it out in read-only mode to make local edits, but you won't be able to publish changes to the file.\n\n"
          message += "What would you like to do?"
          
          # Use a custom dialog with multiple options
          # SketchUp's UI.messagebox only supports Yes/No/Cancel, so we'll use a workaround
          # For now, we'll offer Yes (readonly checkout) or No (cancel)
          result = UI.messagebox(message + "\n\nYes = Check Out (Read-Only)\nNo = Cancel", MB_YESNO)
          
          if result == IDYES
            # User chose readonly checkout
            OpenXrefManager.check_out_xref_readonly(definition.name)
            # Clear the edited_without_lock flag when checking out
            definition.set_attribute(OpenXrefManager::XREF_DICT_NAME, OpenXrefManager::XREF_EDITED_WITHOUT_LOCK_KEY, false)
            # Mark as modified when entering edit mode (user will likely make changes)
            definition.set_attribute(OpenXrefManager::XREF_DICT_NAME, OpenXrefManager::XREF_READONLY_MODIFIED_KEY, true)
            # Allow entry - instances are already unlocked by check_out_xref_readonly
          else
            # User chose to cancel - exit edit mode
            model.close_active if model.active_path
          end
        end
        return
      end

      # Check if auto-checkout is enabled for this model
      auto_checkout_enabled = OpenXrefManager.get_auto_checkout_setting
      
      # If the component is available or locked by us elsewhere, handle checkout based on settings
      # Force prompt if we are in travel-through mode (nested navigation) to ensure users don't miss checkout
      if is_unlocked || is_mine_elsewhere || travel_through_enabled_for_parent
        if auto_checkout_enabled
          # Auto-checkout enabled: prompt to check it out
          UI.start_timer(0.1, false) do
            message = "You are about to edit the '#{definition.name}' XRef component.\n\n"
            message += is_mine_elsewhere ? "Taking ownership from your other session...\n\n" : ""
            message += "Do you want to check it out? (Yes = check out, No = open without locking)"
            result = UI.messagebox(message, MB_YESNO)
            
            if result == IDYES
              # Force unlock if it was ours elsewhere, then check it out here.
              OpenXrefManager.force_unlock_xref(definition.name) if is_mine_elsewhere
              OpenXrefManager.check_out_xref(definition.name)
              # Clear the edited_without_lock flag when checking out
              definition.set_attribute(OpenXrefManager::XREF_DICT_NAME, OpenXrefManager::XREF_EDITED_WITHOUT_LOCK_KEY, false)
            else
              # User chose to open without locking - mark as needs updating
              definition.set_attribute(OpenXrefManager::XREF_DICT_NAME, OpenXrefManager::XREF_EDITED_WITHOUT_LOCK_KEY, true)
              OpenXrefManager.check_for_status_changes(show_notification: false)
            end
          end
        else
          # Auto-checkout disabled: warn user they need to check out manually
          UI.start_timer(0.1, false) do
            message = "Warning: '#{definition.name}' is an XRef component.\n\n"
            message += is_mine_elsewhere ? "This XRef is checked out by you in another session.\n" : ""
            message += "Auto-checkout is DISABLED in settings.\n\n"
            message += "Please check out this XRef from the XRef Manager before making changes, or your edits will not be saved to the external file.\n\n"
            message += "Continue editing without checking out?"
            result = UI.messagebox(message, MB_YESNO)
            
            if result == IDNO
              # User chose not to continue - exit edit mode
              model.close_active if model.active_path
            else
              # User chose to continue without locking - mark as edited without lock
              definition.set_attribute(OpenXrefManager::XREF_DICT_NAME, OpenXrefManager::XREF_EDITED_WITHOUT_LOCK_KEY, true)
              OpenXrefManager.check_for_status_changes(show_notification: false)
            end
          end
        end
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
      
      # Update the timestamp to match the new file's timestamp to prevent false "edited elsewhere" status
      if new_path && File.exist?(new_path)
        begin
          file_timestamp = File.mtime(new_path).to_i
          definition.set_attribute(OpenXrefManager::XREF_DICT_NAME, OpenXrefManager::XREF_TIMESTAMP_KEY, file_timestamp)
        rescue => e
          puts "Could not update timestamp for new file: #{e.message}"
        end
      end
      
      OpenXrefManager.check_for_status_changes(show_notification: false)
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
      UI.start_timer(0, false) do
        self.check_xrefs_and_show_manager
      end
    end
    def onQuit()
      OpenXrefManager.stop_timer
    end
    
    # Check statuses and show dialog
    def check_xrefs_and_show_manager
      # Make sure model is valid
      model = Sketchup.active_model
      return unless model && model.valid?
      
      # We can leverage the get_xref_data_as_json method to get statuses,
      # but we need to parse the JSON it returns.
      json_data = OpenXrefManager.get_xref_data_as_json
      
      # Avoid parsing if it's an empty list
      return if json_data == "[]" 
      
      require 'json' # Make sure JSON is available
      begin
        xref_data = JSON.parse(json_data)
      rescue JSON::ParserError => e
        puts "OpenXrefManager: Error parsing XRef data on open: #{e.message}"
        return
      end

      # Check if any XRef has a status_key other than "ok" (which is "Available")
      needs_attention = xref_data.any? do |xref|
        xref['status_key'] != 'ok'
      end

      if needs_attention
        # Don't show if it's already visible
        dialog = OpenXrefManager.instance_variable_get(:@dialog)
        if dialog.nil? || !dialog.visible?
          OpenXrefManager.show_manager_dialog
        else
          dialog.bring_to_front
        end
      end
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

end
