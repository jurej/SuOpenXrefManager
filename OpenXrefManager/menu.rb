require_relative "core"
require_relative "xref_manager"
require_relative "ui_manager"

module OpenXrefManager
  # --- Menu and Toolbar Setup ---
  puts "OpenXrefManager: Loading menu..."
  unless file_loaded?(__FILE__)


    @@app_observer = OpenXrefAppObserver.new
    Sketchup.add_observer(@@app_observer)

    @@app_observer.attach_observers(Sketchup.active_model) if Sketchup.active_model

    # --- Toolbar ---
    toolbar = UI::Toolbar.new("Open XRef Manager")

    cmd_manager = UI::Command.new("XRef Manager") { show_manager_dialog }
    cmd_manager.tooltip = "Open the XRef Manager"
    cmd_manager.small_icon = File.join(__dir__, "icons", "manager_icon.png")
    cmd_manager.large_icon = File.join(__dir__, "icons", "manager_icon.png")
    toolbar.add_item(cmd_manager)

    cmd_insert = UI::Command.new("Insert XRef at Origin") { import_as_xref_at_origin }
    cmd_insert.tooltip = "Insert an XRef at the Model Origin"
    cmd_insert.small_icon = File.join(__dir__, "icons", "insert_icon.png")
    cmd_insert.large_icon = File.join(__dir__, "icons", "insert_icon.png")
    toolbar.add_item(cmd_insert)

    cmd_publish = UI::Command.new("Save & Check In All") { save_and_check_in_all_my_xrefs }
    cmd_publish.tooltip = "Save & Check In all XRefs you have checked out in this model"
    cmd_publish.small_icon = File.join(__dir__, "icons", "publish_icon.png")
    cmd_publish.large_icon = File.join(__dir__, "icons", "publish_icon.png")
    toolbar.add_item(cmd_publish)

    cmd_pause_monitoring = UI::Command.new("Pause/Resume Monitoring") do
      if monitoring_paused?
        resume_monitoring
        Sketchup.set_status_text("XRef monitoring resumed")
        # Update dialog button if dialog is open
        @dialog.execute_script("setMonitoringButtonState(false);") if @dialog&.visible?
      else
        pause_monitoring
        Sketchup.set_status_text("XRef monitoring paused")
        # Update dialog button if dialog is open
        @dialog.execute_script("setMonitoringButtonState(true);") if @dialog&.visible?
      end
    end
    cmd_pause_monitoring.tooltip = "Pause/Resume background XRef monitoring"
    cmd_pause_monitoring.small_icon = File.join(__dir__, "icons", "icon_pause.png")
    cmd_pause_monitoring.large_icon = File.join(__dir__, "icons", "icon_pause.png")
    cmd_pause_monitoring.set_validation_proc do
      # Show checkmark when paused
      monitoring_paused? ? MF_CHECKED : MF_UNCHECKED
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
    menu.add_item("Set User Name...") { set_user_name }
    menu.add_item("Settings...") { show_settings_dialog }
    menu.add_separator
    menu.add_item("Import XRef at Origin...") { import_as_xref_at_origin }
    menu.add_item("Import XRef (Place)...") { import_as_xref }
    menu.add_separator
    menu.add_item("Create XRef from Component...") { create_xref_from_component }
    menu.add_item("Reload All XRefs") { reload_all_xrefs }

    # --- Context Menu ---
    UI.add_context_menu_handler do |context_menu|
      model = Sketchup.active_model
      return unless model&.valid?

      selection = model.selection
      context_menu.add_separator
      submenu = context_menu.add_submenu("Open XRef Manager")

      if selection.length == 1 && selection.first.is_a?(Sketchup::ComponentInstance)
        instance = selection.first
        definition = instance.definition

        if is_xref?(definition)
          submenu.add_item("Reload XRef") { reload_single_xref(definition.name) }

          lock_content = get_xref_lock_status(definition)
          is_locked = lock_content != "unlocked"
          is_readonly = is_readonly_checkout?(definition)

          if is_readonly
            # Read-only checkout is active
            submenu.add_item("Cancel Read-Only Checkout") { cancel_readonly_checkout(definition.name) }
            submenu.add_separator
          elsif is_locked
            lock_owner_name, lock_owner_guid = lock_content.split("|")
            if lock_owner_name == @user_name && lock_owner_guid == model.guid
              submenu.add_item("Save & Check In XRef") { save_and_check_in_xref(definition.name) }
            else
              # Locked by someone else - offer readonly checkout
              submenu.add_item("Check Out (Read-Only)") { check_out_xref_readonly(definition.name) }
              cmd_locked = UI::Command.new("Locked by #{lock_owner_name}") {}
              cmd_locked.set_validation_proc { MF_GRAYED }
              submenu.add_item(cmd_locked)
            end
          else
            submenu.add_item("Check Out XRef") { check_out_xref(definition.name) }
          end

          submenu.add_separator

          # Add force operations to context menu (moved from GUI for safety)
          if is_locked
            lock_owner_name, lock_owner_guid = lock_content.split("|")
            if lock_owner_name == @user_name && lock_owner_guid != model.guid
              # Checked out by user in another session - offer force check-in
              submenu.add_item("Force Check In...") { force_check_in_xref(definition.name) }
            elsif lock_owner_name != @user_name
              # Locked by someone else - offer force unlock
              submenu.add_item("Force Unlock...") { force_unlock_xref(definition.name) }
            end
          end

          submenu.add_separator
          submenu.add_item("Unlink XRef") { unlink_single_xref(definition.name) }
        else
          submenu.add_item("Create XRef from this Component...") { create_xref_from_component }
        end
      else
        submenu.add_item("Import XRef...") { import_as_xref }
      end
    end

    file_loaded(__FILE__)
  end
end
