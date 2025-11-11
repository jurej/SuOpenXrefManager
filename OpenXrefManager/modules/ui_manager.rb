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
  module UIManager

    # --- Live Update Timer ---

    # Starts the background timer to check for changes in XRef lock files.
    def self.start_timer
      self.stop_timer # Ensure no duplicate timers are running
      #puts "Open XRef background monitor is running..."
      self.check_for_status_changes(show_notification: false) # Initial check
      Core.timer = UI.start_timer(Core::TIMER_INTERVAL, true) do
        self.check_for_status_changes
      end
    end

    # Stops the background timer.
    def self.stop_timer
      if Core.timer
        UI.stop_timer(Core.timer)
        Core.timer = nil
        puts "Stopping Open XRef background monitor."
      end
    end

    # Checks all XRefs for changes in their lock status and updates instance locks.
    def self.check_for_status_changes(show_notification: true)
      model = Sketchup.active_model
      return unless model && model.valid?
      current_guid = model.guid
      something_changed = false

      Core.get_xref_definitions.each do |definition|
        # Skip invalid definitions (can happen during reload operations)
        next unless definition && definition.valid?

        update_available = FileOperations.is_update_available?(definition)
        something_changed = true if update_available

        current_lock_content = FileOperations.get_xref_lock_status(definition)
        is_locked_by_file = current_lock_content != "unlocked"
        is_mine_in_this_window = false

        if is_locked_by_file
          lock_owner_name, lock_owner_guid, _, _ = current_lock_content.split('|')
          is_mine_in_this_window = (lock_owner_name == Core.user_name && lock_owner_guid == current_guid)
        end

        # Lock instances if locked by someone else OR if an update is available.
        should_be_locked = (is_locked_by_file && !is_mine_in_this_window) || update_available
        Core.lock_or_unlock_instances_for_definition(definition, should_be_locked)

        # Compare with last known status to see if a notification is needed.
        last_lock_content = Core.last_xref_statuses[definition.guid] || "unlocked"
        if current_lock_content != last_lock_content
          something_changed = true
          if show_notification
            if !is_locked_by_file
              Sketchup.set_status_text("XRef Status: '#{definition.name}' was checked in.")
            else
              lock_owner_name, _, lock_model_name, _ = current_lock_content.split('|')
              lock_model_name ||= "an unsaved model"
              Sketchup.set_status_text("XRef Status: '#{definition.name}' was checked out by #{lock_owner_name} in '#{lock_model_name}'.")
            end
          end
        end
        Core.last_xref_statuses[definition.guid] = current_lock_content
      end

      # Refresh the dialog if something changed
      self.refresh_dialog_data if something_changed
    end

    # --- UI Dialog Functions ---

    # Compiles all XRef data into a JSON string for the UI dialog.
    def self.get_xref_data_as_json
      model = Sketchup.active_model
      return [].to_json unless model && model.valid?
      current_guid = model.guid

      data = Core.get_xref_definitions.select { |d| d && d.valid? }.map do |definition|
        absolute_path = FileOperations.resolve_xref_path(definition)
        stored_path = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_KEY)
        file_found = absolute_path && File.exist?(absolute_path)
        path_type = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_TYPE_KEY) || "absolute"
        can_be_relative = model.path && !model.path.empty?
        is_unloaded = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_UNLOADED_KEY) == true

        # Get format information
        format = Core.get_xref_format(definition)
        format_name = Core.get_format_name(definition)
        is_editable = Core.is_editable_format?(definition)

        lock_content = FileOperations.get_xref_lock_status(definition)
        is_locked = lock_content != "unlocked"
        lock_owner_name, lock_owner_guid, lock_model_name, lock_model_path = is_locked ? lock_content.split('|') : [nil, nil, nil, nil]
        lock_model_name ||= "Untitled Model" if is_locked
        lock_model_path ||= "" if is_locked

        stored_timestamp = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_TIMESTAMP_KEY)

        status_text = "Available"
        status_key = "ok"

        update_available = FileOperations.is_update_available?(definition)
        file_timestamp = nil
        if file_found
          begin
            file_timestamp = File.mtime(absolute_path).to_i
          rescue => e
            file_timestamp = nil # Could not get timestamp
          end
        end

        if is_unloaded
          status_text = "Unloaded"
          status_key = "unloaded"
        elsif !file_found
          status_text = "File Not Found"
          status_key = "not_found"
        elsif update_available
          status_text = "Update Available"
          status_key = "update_available"
        elsif is_locked
          if lock_owner_name == Core.user_name
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
          is_locked: is_locked,
          lock_owner_name: lock_owner_name,
          lock_model_name: lock_model_name,
          lock_model_path: lock_model_path,
          is_unloaded: is_unloaded,
          timestamp: stored_timestamp,
          file_timestamp: file_timestamp,
          update_available: update_available,
          format: format,
          format_name: format_name,
          is_editable: is_editable
        }
      end
      return data.to_json
    end

    # Creates and shows the main XRef Manager dialog.
    def self.show_manager_dialog
      if Core.dialog && Core.dialog.visible?
        Core.dialog.bring_to_front
        return
      end

      Core.dialog = UI::HtmlDialog.new({
        dialog_title: "Open XRef Manager",
        preferences_key: "com.openxref.manager",
        scrollable: true,
        resizable: true,
        width: 850,
        height: 450,
        style: UI::HtmlDialog::STYLE_DIALOG
      })

      html_file = File.join(File.dirname(__FILE__), '..', 'manager.html')
      Core.dialog.set_file(html_file)

      # Register callbacks for actions triggered from the JavaScript UI.
      Core.dialog.add_action_callback("refresh_data") { |ctx| self.refresh_dialog_data }
      Core.dialog.add_action_callback("publish_all_clicked") { |ctx| XrefOperations.save_and_check_in_all_my_xrefs; self.check_for_status_changes(show_notification: false); self.refresh_dialog_data }
      Core.dialog.add_action_callback("reload_single_clicked") { |ctx, name, suppress_warning| XrefOperations.reload_single_xref(name, suppress_warning: suppress_warning); self.refresh_dialog_data }
      Core.dialog.add_action_callback("unlink_single_clicked") { |ctx, name| XrefOperations.unlink_single_xref(name); self.refresh_dialog_data }
      Core.dialog.add_action_callback("check_out_clicked") { |ctx, name| XrefOperations.check_out_xref(name); self.check_for_status_changes(show_notification: false); self.refresh_dialog_data }
      Core.dialog.add_action_callback("save_and_check_in_clicked") { |ctx, name| XrefOperations.save_and_check_in_xref(name); self.check_for_status_changes(show_notification: false); self.refresh_dialog_data }
      Core.dialog.add_action_callback("force_check_in_clicked") { |ctx, name| XrefOperations.force_check_in_xref(name); self.check_for_status_changes(show_notification: false); self.refresh_dialog_data }
      Core.dialog.add_action_callback("force_unlock_clicked") { |ctx, name| XrefOperations.force_unlock_xref(name); self.check_for_status_changes(show_notification: false); self.refresh_dialog_data }
      Core.dialog.add_action_callback("purge_unused_clicked") { |ctx| XrefOperations.purge_unused_xrefs; self.refresh_dialog_data }
      Core.dialog.add_action_callback("relink_clicked") { |ctx, name| XrefOperations.relink_xref(name); self.refresh_dialog_data }
      Core.dialog.add_action_callback("unload_single_clicked") { |ctx, name| XrefOperations.unload_single_xref(name); self.check_for_status_changes(show_notification: false); self.refresh_dialog_data }
      Core.dialog.add_action_callback("toggle_path_type_clicked") { |ctx, name| FileOperations.toggle_path_type(name); self.refresh_dialog_data }
      Core.dialog.add_action_callback("select_component_clicked") { |ctx, name| Core.select_component_instances(name) }
      Core.dialog.add_action_callback("close_dialog") { |ctx| Core.dialog.close }

      Core.dialog.set_on_closed { Core.dialog = nil }
      Core.dialog.show
    end

    # Sends the latest XRef data to the HTML Dialog.
    def self.refresh_dialog_data
      return unless Core.dialog && Core.dialog.visible?
      json_data = self.get_xref_data_as_json
      Core.dialog.execute_script("updateTable(#{json_data})")
      nil
    end

  end
end
