require_relative 'core'

module OpenXrefManager

  # --- Live Update Timer ---

  # Starts the background timer to check for changes in XRef lock files.
  def self.start_timer
    self.stop_timer # Ensure no duplicate timers
    @timer = UI.start_timer(2.0, true) do
      self.check_for_status_changes
    end
  end

  # Stops the background timer.
  def self.stop_timer
    if @timer
      UI.stop_timer(@timer)
      @timer = nil
    end
  end

  # Checks all XRefs for changes in their lock status and updates instance locks.
  def self.check_for_status_changes(show_notification: true)
    model = Sketchup.active_model
    return unless model && model.valid?

    # Check if model GUID changed (e.g. Save As / Save Copy As)
    current_guid = model.guid
    if @last_model_guid && @last_model_guid != current_guid
       # GUID changed! Update our locks to point to the new GUID
       update_owned_lock_files(@last_model_guid, current_guid)
    end
    @last_model_guid = current_guid
    
    something_changed = false
    
    get_xref_definitions.each do |definition|
      current_lock_content = get_xref_lock_status(definition)
      current_update_available = _is_update_available?(definition)
      
      last_status = @last_xref_statuses[definition.guid]
      
      # Check if status changed
      if last_status.nil? || 
         last_status[:lock_content] != current_lock_content || 
         last_status[:update_available] != current_update_available
         
         something_changed = true
         @last_xref_statuses[definition.guid] = { lock_content: current_lock_content, update_available: current_update_available }
         
         # Update lock state of instances in the model
         is_locked_by_file = current_lock_content != "unlocked"
         is_mine_in_this_window = false
         
         if is_locked_by_file
           lock_owner_name, lock_owner_guid, _, _ = current_lock_content.split('|')
           is_mine_in_this_window = (lock_owner_name == @user_name && lock_owner_guid == model.guid)
         end
         
         # We should lock instances if:
         # 1. It is locked by someone else (or us in another window)
         # 2. OR an update is available (force user to update before editing)
         should_be_locked = (is_locked_by_file && !is_mine_in_this_window) || current_update_available
         
         lock_or_unlock_instances_for_definition(definition, should_be_locked)
      end
    end
    
    if something_changed
      self.refresh_dialog_data
    end
  end

end
