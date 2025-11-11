# v1.3.4
# Copyright (c) 2025 Jure Judez and Sebastian Barthmes
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

module OpenXrefManager
  module MenuToolbar

    # Using a class variable to hold observer instances to ensure they are not garbage collected.
    @@app_observer = nil

    def self.setup
      # Initialize app observer
      @@app_observer = Observers::AppObserver.new
      Sketchup.add_observer(@@app_observer)

      if Sketchup.active_model
        @@app_observer.attach_observers(Sketchup.active_model)
      end

      # --- Toolbar ---
      toolbar = UI::Toolbar.new("Open XRef")

      cmd_manager = UI::Command.new("XRef Manager") { UIManager.show_manager_dialog }
      cmd_manager.tooltip = "Open the XRef Manager"
      cmd_manager.small_icon = File.join(File.dirname(__FILE__), "..", "icons", "manager_icon.png")
      cmd_manager.large_icon = File.join(File.dirname(__FILE__), "..", "icons", "manager_icon.png")
      toolbar.add_item(cmd_manager)

      cmd_insert = UI::Command.new("Insert XRef at Origin") { XrefOperations.import_as_xref_at_origin }
      cmd_insert.tooltip = "Insert an XRef at the Model Origin"
      cmd_insert.small_icon = File.join(File.dirname(__FILE__), "..", "icons", "insert_icon.png")
      cmd_insert.large_icon = File.join(File.dirname(__FILE__), "..", "icons", "insert_icon.png")
      toolbar.add_item(cmd_insert)

      cmd_publish = UI::Command.new("Save & Check In All") do
        XrefOperations.save_and_check_in_all_my_xrefs
        UIManager.check_for_status_changes(show_notification: false)
        UIManager.refresh_dialog_data
      end
      cmd_publish.tooltip = "Save & Check In all XRefs you have checked out in this model"
      cmd_publish.small_icon = File.join(File.dirname(__FILE__), "..", "icons", "publish_icon.png")
      cmd_publish.large_icon = File.join(File.dirname(__FILE__), "..", "icons", "publish_icon.png")
      toolbar.add_item(cmd_publish)

      toolbar.restore

      # --- Menus ---
      menu = UI.menu("Extensions").add_submenu("Open XRef")
      menu.add_item(cmd_manager)
      menu.add_item(cmd_publish)
      menu.add_item("Set User Name...") { Core.set_user_name }
      menu.add_separator
      menu.add_item("Import XRef at Origin...") { XrefOperations.import_as_xref_at_origin }
      menu.add_item("Import XRef (Place)...") { XrefOperations.import_as_xref }
      menu.add_separator
      menu.add_item("Create XRef from Component...") { XrefOperations.create_xref_from_component }
      menu.add_item("Reload All XRefs") { XrefOperations.reload_all_xrefs; UIManager.refresh_dialog_data }

      # --- Context Menu ---
      UI.add_context_menu_handler do |context_menu|
        model = Sketchup.active_model
        next unless model && model.valid?
        selection = model.selection

        submenu = context_menu.add_submenu("Open XRef")

        if selection.length == 1 && selection.first.is_a?(Sketchup::ComponentInstance)
          instance = selection.first
          definition = instance.definition

          if Core.is_xref?(definition)
            submenu.add_item("Reload XRef") do
              XrefOperations.reload_single_xref(definition.name)
              UIManager.refresh_dialog_data
            end

            # Check if format is editable before showing checkout/checkin options
            is_editable = Core.is_editable_format?(definition)
            lock_content = FileOperations.get_xref_lock_status(definition)
            is_locked = lock_content != "unlocked"

            if is_locked
              lock_owner_name, lock_owner_guid = lock_content.split('|')
              if lock_owner_name == Core.user_name && lock_owner_guid == model.guid
                if is_editable
                  submenu.add_item("Save & Check In XRef") do
                    XrefOperations.save_and_check_in_xref(definition.name)
                    UIManager.check_for_status_changes(show_notification: false)
                    UIManager.refresh_dialog_data
                  end
                else
                  cmd_readonly = UI::Command.new("Read-only XRef (Edit externally)") { }
                  cmd_readonly.set_validation_proc { MF_GRAYED }
                  submenu.add_item(cmd_readonly)
                end
              else
                cmd_locked = UI::Command.new("Locked by #{lock_owner_name}") { }
                cmd_locked.set_validation_proc { MF_GRAYED }
                submenu.add_item(cmd_locked)
              end
            else
              if is_editable
                submenu.add_item("Check Out XRef") do
                  XrefOperations.check_out_xref(definition.name)
                  UIManager.check_for_status_changes(show_notification: false)
                  UIManager.refresh_dialog_data
                end
              else
                format_name = Core.get_format_name(definition)
                cmd_readonly = UI::Command.new("Read-only #{format_name}") { }
                cmd_readonly.set_validation_proc { MF_GRAYED }
                submenu.add_item(cmd_readonly)
              end
            end

            submenu.add_separator
            submenu.add_item("Unlink XRef") do
              XrefOperations.unlink_single_xref(definition.name)
              UIManager.refresh_dialog_data
            end
          else
            submenu.add_item("Create XRef from this Component...") { XrefOperations.create_xref_from_component }
          end
        else
          submenu.add_item("Import XRef...") { XrefOperations.import_as_xref }
        end
      end
    end

  end
end
