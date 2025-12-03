require_relative 'core'
require_relative 'xref_manager'
require_relative 'ui_manager'

module OpenXrefManager

  # --- Menu and Toolbar Setup ---
  puts "OpenXrefManager: Loading menu..."
  unless file_loaded?(__FILE__)

    
    @@app_observer = OpenXrefAppObserver.new
    Sketchup.add_observer(@@app_observer)

    if Sketchup.active_model
      @@app_observer.attach_observers(Sketchup.active_model)
    end
    
    # --- Toolbar ---
    toolbar = UI::Toolbar.new("Open XRef Manager")

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
    
    cmd_pause_monitoring = UI::Command.new("Pause/Resume Monitoring") do
      if self.monitoring_paused?
        self.resume_monitoring
        Sketchup.set_status_text("XRef monitoring resumed")
        # Update dialog button if dialog is open
        if @dialog && @dialog.visible?
          @dialog.execute_script("setMonitoringButtonState(false);")
        end
      else
        self.pause_monitoring
        Sketchup.set_status_text("XRef monitoring paused")
        # Update dialog button if dialog is open
        if @dialog && @dialog.visible?
          @dialog.execute_script("setMonitoringButtonState(true);")
        end
      end
    end
    cmd_pause_monitoring.tooltip = "Pause/Resume background XRef monitoring"
    cmd_pause_monitoring.small_icon = File.join(__dir__, "icons", "icon_pause.png")
    cmd_pause_monitoring.large_icon = File.join(__dir__, "icons", "icon_pause.png")
    cmd_pause_monitoring.set_validation_proc do
      # Show checkmark when paused
      self.monitoring_paused? ? MF_CHECKED : MF_UNCHECKED
    end
    toolbar.add_item(cmd_pause_monitoring)
    
    toolbar.restore

    # --- Menus ---
    extensions_menu = UI.menu("Extensions")
    extensions_menu.add_separator
    menu = extensions_menu.add_submenu("Open XRef Manager")
    menu.add_item(cmd_manager)
    menu.add_item(cmd_publish)
    menu.add_item(cmd_pause_monitoring)
    menu.add_separator
    menu.add_item("Set User Name...") { self.set_user_name }
    menu.add_item("Settings...") { self.show_settings_dialog }
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
      context_menu.add_separator
      submenu = context_menu.add_submenu("Open XRef Manager")
      
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
              cmd_locked = UI::Command.new("Locked by #{lock_owner_name}") { }
              cmd_locked.set_validation_proc { MF_GRAYED }
              submenu.add_item(cmd_locked)
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
