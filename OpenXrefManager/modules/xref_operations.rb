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

module OpenXrefManager
  module XrefOperations

    # Purges all unused XRefs from the model.
    def self.purge_unused_xrefs
      model = Sketchup.active_model
      unused_xrefs = Core.get_xref_definitions.select { |d| d.instances.empty? }

      if unused_xrefs.empty?
        UI.messagebox("No unused XRefs found to purge.")
        return
      end

      # Confirmation dialog (moved from JavaScript for reliability)
      question = "Are you sure you want to remove all unused XRefs from this model?\n\n" +
                 "This action cannot be undone and will skip any locked files."
      result = UI.messagebox(question, Core::MB_YESNO)
      return unless result == Core::IDYES

      model.start_operation("Purge Unused XRefs", true)
      purged_count = 0
      unused_xrefs.each do |definition|
        # Also remove any lock files associated with the purged XRef if we own them
        lock_content = FileOperations.get_xref_lock_status(definition)
        if lock_content != "unlocked"
          lock_owner_name, lock_owner_guid = lock_content.split('|')
          if lock_owner_name == Core.user_name && lock_owner_guid == model.guid
            path = FileOperations.resolve_xref_path(definition)
            lock_path = path + ".lock" if path
            File.delete(lock_path) if lock_path && File.exist?(lock_path)
          end
        end
        model.definitions.remove(definition)
        purged_count += 1
      end
      model.commit_operation
      UI.messagebox("Purged #{purged_count} unused XRef(s).")
    end

    # Creates a .lock file for an XRef, marking it as "checked out" by the current user.
    def self.check_out_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition
      path = FileOperations.resolve_xref_path(definition)
      return unless path
      lock_path = path + ".lock"

      if File.exist?(path) && !File.exist?(lock_path)
        model.start_operation("Check Out XRef", true)
        begin
          model_path = model.path
          model_name = (model_path.nil? || model_path.empty?) ? "Untitled Model" : File.basename(model_path)
          model_path_str = model_path.nil? ? "" : model_path # Get the full path as a string
          lock_content = "#{Core.user_name}|#{model.guid}|#{model_name}|#{model_path_str}"

          File.write(lock_path, lock_content)
          Core.last_xref_statuses[definition.guid] = lock_content
          Core.lock_or_unlock_instances_for_definition(definition, false)
        rescue => e
          UI.messagebox("Failed to create lock file:\n#{e.message}")
        end
        model.commit_operation
      else
        UI.beep # Can't check out if file doesn't exist or is already locked
      end
    end

    # Internal helper to save a definition and remove its lock file.
    def self.silent_save_and_check_in(definition)
      path = FileOperations.resolve_xref_path(definition)
      return false unless path
      begin
        definition.save_as(path)
        Core.update_xref_timestamp(definition)
        lock_path = path + ".lock"
        File.delete(lock_path) if File.exist?(lock_path)
        Core.last_xref_statuses[definition.guid] = "unlocked"
        return true
      rescue => e
        UI.messagebox("Failed to save component '#{definition.name}'.\nError: #{e.message}")
        return false
      end
    end

    # Saves and checks in all XRefs currently checked out by the user in this model.
    def self.save_and_check_in_all_my_xrefs
      model = Sketchup.active_model
      current_guid = model.guid

      my_xrefs = Core.get_xref_definitions.select do |definition|
        lock_content = FileOperations.get_xref_lock_status(definition)
        next false if lock_content == "unlocked"
        lock_owner_name, lock_owner_guid = lock_content.split('|')
        lock_owner_name == Core.user_name && lock_owner_guid == current_guid
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
        self.silent_save_and_check_in(definition)
      end
      model.close_active if was_editing_an_xref
      model.commit_operation
    end

    # Saves and checks in a single XRef.
    def self.save_and_check_in_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition

      lock_content = FileOperations.get_xref_lock_status(definition)
      lock_owner_name, lock_owner_guid = lock_content.split('|')

      if lock_owner_name == Core.user_name && lock_owner_guid == model.guid
        model.start_operation("Save & Check In XRef", true)
        was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }
        self.silent_save_and_check_in(definition)
        model.close_active if was_editing
        model.commit_operation
      else
        UI.beep
      end
    end

    # Forces a check-in, useful if an XRef is locked by the same user in another session.
    def self.force_check_in_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition

      lock_content = FileOperations.get_xref_lock_status(definition)
      lock_owner_name, _ = lock_content.split('|')

      if lock_owner_name == Core.user_name
        question = "This XRef appears to be checked out by you in another session or window.\n\n" +
                   "Forcing a check-in will overwrite the file with the version from THIS model.\n\n" +
                   "Are you sure you want to continue?"
        result = UI.messagebox(question, Core::MB_YESNO)
        return unless result == Core::IDYES

        model.start_operation("Force Check In XRef", true)
        self.silent_save_and_check_in(definition)
        model.commit_operation
      else
        UI.beep
      end
    end

    # Deletes the .lock file for a given XRef.
    def self.force_unlock_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition
      path = FileOperations.resolve_xref_path(definition)
      return unless path

      lock_path = path + ".lock"
      if File.exist?(lock_path)
        # Confirmation dialog (moved from JavaScript for reliability)
        question = "WARNING: You are about to force unlock '#{component_name}' which is checked out by another user.\n\n" +
                   "This can lead to data loss if they are actively working on the file.\n\n" +
                   "Are you sure you want to continue?"
        result = UI.messagebox(question, Core::MB_YESNO)
        return unless result == Core::IDYES

        model.start_operation("Force Unlock XRef", true)
        begin
          was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }
          File.delete(lock_path)
          model.close_active if was_editing
        rescue => e
          UI.messagebox("Could not delete lock file:\n#{e.message}")
        end
        model.commit_operation
      else
        UI.beep
      end
    end

    # Imports a .skp file as a new XRef and places it for the user to position.
    def self.import_as_xref
      model = Sketchup.active_model
      path = UI.openpanel("Import XRef file", "", "*.skp")
      return unless path

      model.start_operation("Import as XRef", true)
      begin
        new_definition = model.definitions.load(path)
        FileOperations.set_xref_path(new_definition, path, ask_user: true)
        model.place_component(new_definition, true)
      rescue => e
        UI.messagebox("Failed to import XRef.\nError: #{e.message}")
      ensure
        model.commit_operation
      end
    end

    # Imports a .skp file as a new XRef at the model origin.
    def self.import_as_xref_at_origin
      model = Sketchup.active_model
      path = UI.openpanel("Import XRef at Origin", "", "*.skp")
      return unless path
      model.start_operation("Import XRef at Origin", true)
      begin
        new_definition = model.definitions.load(path)
        FileOperations.set_xref_path(new_definition, path, ask_user: true)
        model.entities.add_instance(new_definition, Geom::Transformation.new)
      rescue => e
        UI.messagebox("Failed to import XRef.\nError: #{e.message}")
      ensure
        model.commit_operation
      end
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

      return UI.messagebox("'#{definition.name}' is already an XRef.") if Core.is_xref?(definition)

      path = UI.savepanel("Create and Link XRef File", "", "#{definition.name}.skp")
      return unless path

      model.start_operation("Create XRef from Component", true)
      begin
        definition.save_as(path)
        FileOperations.set_xref_path(definition, path, ask_user: true)
      rescue => e
        UI.messagebox("Failed to save new XRef file.\nError: #{e.message}")
        model.abort_operation
        return
      end

      model.commit_operation
    end

    # Allows the user to select a new file path for an existing XRef.
    def self.relink_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition

      path_to_relink = UI.openpanel("Select new file for '#{component_name}'", "", "*.skp")
      return unless path_to_relink

      model.start_operation("Relink XRef", true)

      FileOperations.set_xref_path(definition, path_to_relink, ask_user: true) # Ask about relative/absolute

      question = "Relink successful.\n\nDo you want to reload '#{component_name}' from the new location now?"
      result = UI.messagebox(question, Core::MB_YESNO)
      if result == Core::IDYES
        self.reload_single_xref_without_warning(component_name)
      end

      model.commit_operation
    end

    # Removes the XRef link from a component, making it a regular, internal component.
    def self.unlink_single_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition

      # Confirmation dialog (moved from JavaScript for reliability)
      question = "Are you sure you want to unlink '#{component_name}'?\n\nThis cannot be undone."
      result = UI.messagebox(question, Core::MB_YESNO)
      return unless result == Core::IDYES

      model.start_operation("Unlink XRef", true)
      was_editing = model.active_path && model.active_path.any? { |instance| instance.definition == definition }
      definition.attribute_dictionaries.delete(Core::XREF_DICT_NAME)
      Core.lock_or_unlock_instances_for_definition(definition, false)
      model.close_active if was_editing
      model.commit_operation
    end

    # Unloads an XRef's geometry to improve performance.
    def self.unload_single_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }

      unless definition
        UI.messagebox("Cannot find XRef component '#{component_name}'")
        return false
      end

      # Confirmation dialog (moved from JavaScript for reliability)
      question = "Are you sure you want to unload '#{component_name}'?\n\n" +
                 "This will remove it from the model to improve performance but keep the link so you can load it back at any time.\n\n" +
                 "Any uncommitted changes will be lost."
      result = UI.messagebox(question, Core::MB_YESNO)
      return false unless result == Core::IDYES

      lock_content = FileOperations.get_xref_lock_status(definition)

      # If it's locked by me, my local changes will be lost.
      # The lock must be removed to avoid conflicts.
      if lock_content != "unlocked"
        lock_owner_name, lock_owner_guid, _, _ = lock_content.split('|')
        if lock_owner_name == Core.user_name && lock_owner_guid == model.guid
          # Locked by me in this window. Remove the lock.
          lock_path = FileOperations.resolve_xref_path(definition)
          lock_path += ".lock" if lock_path
          File.delete(lock_path) if lock_path && File.exist?(lock_path)
          Core.last_xref_statuses[definition.guid] = "unlocked" # Update cache
        end
      end

      model.start_operation("Unload XRef", true)
      begin
        # Clear all geometry from the definition
        definition.entities.to_a.each { |e| e.erase! if e.valid? }
        placeholder_group = definition.entities.add_group
        placeholder_text = placeholder_group.definition.entities.add_text("XREF_PLACEHOLDER", [0, 0, 0])
        placeholder_text.hidden = true
        placeholder_group.hidden = true
        # Set the flag so we know it's unloaded
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_UNLOADED_KEY, true)
        model.commit_operation

        # Explicit UI refresh to ensure status updates even if callback fails
        UIManager.check_for_status_changes(show_notification: false)
        UIManager.refresh_dialog_data

        return true
      rescue => e
        model.abort_operation
        UI.messagebox("Failed to unload XRef '#{component_name}'.\nError: #{e.message}")
        return false
      end
    end

    # Reloads a single XRef after confirming with the user.
    def self.reload_single_xref(component_name, suppress_warning: false)
      if !suppress_warning
        question = "Reloading '#{component_name}' will discard any changes made to it in the current model.\n\n" +
                   "Are you sure you want to continue?"
        result = UI.messagebox(question, Core::MB_YESNO)
        return unless result == Core::IDYES
      end

      self.reload_single_xref_without_warning(component_name)
    end

    # Reloads all XRefs in the model after confirmation.
    def self.reload_all_xrefs
      xref_definitions = Core.get_xref_definitions
      return UI.messagebox("No XRefs to reload.") if xref_definitions.empty?

      question = "This will reload all linked XRefs, discarding any local changes.\n\n" +
                 "Are you sure you want to continue?"
      result = UI.messagebox(question, Core::MB_YESNO)
      return unless result == Core::IDYES

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
    end

    # The core logic for reloading an XRef from its file.
    def self.reload_single_xref_without_warning(component_name, suppress_errors: false)
      model = Sketchup.active_model
      # This is the original, "unloaded" definition (e.g., "Box")
      original_definition = model.definitions.find { |d| d.name == component_name }
      return false unless original_definition

      path = FileOperations.resolve_xref_path(original_definition)

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
          dict = original_definition.attribute_dictionary(Core::XREF_DICT_NAME)
          if dict
            dict.each_pair do |key, value|
              reloaded_definition.set_attribute(Core::XREF_DICT_NAME, key, value)
            end
          end

          reloaded_definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_UNLOADED_KEY, false)

          # Remove XRef attributes from the OLD definition so it's
          # no longer tracked and can be purged.
          original_definition.attribute_dictionaries.delete(Core::XREF_DICT_NAME)

          original_name = original_definition.name

          model.definitions.purge_unused

          if model.definitions[original_name].nil?
            reloaded_definition.name = original_name
          else
            # Purge failed (rare, but possible). We're stuck with 'Box#1'.
            puts "OpenXrefManager: Could not purge '#{original_name}'. " +
                 "Reloaded XRef remains as '#{reloaded_definition.name}'."
          end
          Core.update_xref_timestamp(reloaded_definition)

        elsif reloaded_definition && reloaded_definition == original_definition
          # This path happens if the definition was *already* purged.
          # In this case, just set the unloaded flag to false.
          reloaded_definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_UNLOADED_KEY, false)
          Core.update_xref_timestamp(reloaded_definition)
        end

        success = !reloaded_definition.nil?

      rescue => e
        UI.messagebox("Failed to reload #{component_name}.\nError: #{e.message}") unless suppress_errors
        success = false
      ensure
        model.commit_operation
      end

      return success
    end

  end
end
