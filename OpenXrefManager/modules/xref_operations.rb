# v1.3.2
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

      # Check if format is editable from SketchUp
      unless Core.is_editable_format?(definition)
        format_name = Core.get_format_name(definition)
        UI.messagebox("Cannot check out #{format_name} files from SketchUp.\n\n" +
                      "#{format_name} files are read-only XRefs.\n" +
                      "Edit them in their native application, then reload the XRef.")
        return
      end

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
    # Only processes editable formats (SKP). Non-editable formats (DWG/DXF) are skipped.
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

      # Filter to only editable formats (SKP)
      editable_xrefs = my_xrefs.select { |definition| Core.is_editable_format?(definition) }
      skipped_count = my_xrefs.length - editable_xrefs.length

      if editable_xrefs.empty?
        UI.messagebox("You have #{my_xrefs.length} XRef(s) checked out, but none are editable from SketchUp.\n\n" +
                      "Edit non-SKP files in their native applications, then reload the XRefs.")
        return
      end

      model.start_operation("Save & Check In All My XRefs", true)

      # Check if we are currently editing any of the XRefs being checked in.
      was_editing_an_xref = false
      if model.active_path
        was_editing_an_xref = model.active_path.any? do |instance|
          editable_xrefs.include?(instance.definition)
        end
      end

      editable_xrefs.each do |definition|
        self.silent_save_and_check_in(definition)
      end
      model.close_active if was_editing_an_xref
      model.commit_operation

      # Notify user if some were skipped
      if skipped_count > 0
        UI.messagebox("Checked in #{editable_xrefs.length} SKP XRef(s).\n\n" +
                      "Skipped #{skipped_count} non-editable XRef(s) (DWG/DXF).")
      end
    end

    # Saves and checks in a single XRef.
    def self.save_and_check_in_xref(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition

      # Check if format is editable from SketchUp
      unless Core.is_editable_format?(definition)
        format_name = Core.get_format_name(definition)
        UI.messagebox("Cannot check in #{format_name} files from SketchUp.\n\n" +
                      "Edit the file in its native application (e.g., AutoCAD),\n" +
                      "then reload the XRef to see changes.")
        return
      end

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

      # Check if format is editable from SketchUp
      unless Core.is_editable_format?(definition)
        format_name = Core.get_format_name(definition)
        UI.messagebox("Cannot check in #{format_name} files from SketchUp.\n\n" +
                      "Edit the file in its native application (e.g., AutoCAD),\n" +
                      "then reload the XRef to see changes.")
        return
      end

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

    # Imports a file as a new XRef and places it for the user to position.
    # Supports SKP, DWG, and DXF formats.
    def self.import_as_xref
      model = Sketchup.active_model
      path = UI.openpanel("Import XRef file", "", "Supported Files|*.skp;*.dwg;*.dxf||")
      return unless path

      format = FileOperations.detect_format_from_path(path)
      unless format
        UI.messagebox("Unsupported file format. Please select a .skp, .dwg, or .dxf file.")
        return
      end

      model.start_operation("Import as XRef", true)
      begin
        if format == "skp"
          import_skp_xref(path, place: true)
        else
          import_cad_xref(path, format, place: true)
        end
      rescue => e
        UI.messagebox("Failed to import XRef.\nError: #{e.message}")
        model.abort_operation
      ensure
        model.commit_operation
      end
    end

    # Imports a file as a new XRef at the model origin.
    # Supports SKP, DWG, and DXF formats.
    def self.import_as_xref_at_origin
      model = Sketchup.active_model
      path = UI.openpanel("Import XRef at Origin", "", "Supported Files|*.skp;*.dwg;*.dxf||")
      return unless path

      format = FileOperations.detect_format_from_path(path)
      unless format
        UI.messagebox("Unsupported file format. Please select a .skp, .dwg, or .dxf file.")
        return
      end

      model.start_operation("Import XRef at Origin", true)
      begin
        if format == "skp"
          import_skp_xref(path, place: false)
        else
          import_cad_xref(path, format, place: false)
        end
      rescue => e
        UI.messagebox("Failed to import XRef.\nError: #{e.message}")
        model.abort_operation
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

      format = Core.get_xref_format(original_definition)

      model.start_operation("Reload XRef: #{component_name}", true)

      success = if format == "skp"
        reload_skp_xref(original_definition, path, suppress_errors)
      else
        reload_cad_xref(original_definition, path, format, suppress_errors)
      end

      model.commit_operation
      success
    end

    # Reloads a SKP XRef (existing logic extracted into separate method).
    def self.reload_skp_xref(original_definition, path, suppress_errors)
      model = Sketchup.active_model
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

          # Clean up cache entry for the old definition before it's deleted
          old_guid = original_definition.guid
          Core.last_xref_statuses.delete(old_guid)

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
        UI.messagebox("Failed to reload XRef.\nError: #{e.message}") unless suppress_errors
        success = false
      end

      return success
    end

    # Reloads a CAD (DWG/DXF) XRef by importing fresh and swapping contents.
    # CAD files are imported as nested geometry within the component definition.
    def self.reload_cad_xref(original_definition, path, format, suppress_errors)
      model = Sketchup.active_model
      success = false
      temp_instance = nil
      temp_definition = nil

      begin
        # Validate original_definition is still valid
        unless original_definition && original_definition.valid?
          raise "Original XRef definition is invalid before reload"
        end

        # CRITICAL: Check if definition has instances
        # If it has no instances, it may be auto-purged by SketchUp
        if original_definition.instances.empty?
          raise "Cannot reload XRef: definition has no instances in the model. Please re-import the XRef instead."
        end

        # Store the original name before any operations
        original_name = original_definition.name

        # STEP 1: Import the CAD file FIRST (don't touch original_definition yet)
        # This avoids race conditions where import triggers cleanup
        entities_before = model.entities.to_a.dup
        status = model.import(path, false)  # false = no summary dialog

        unless status
          raise "Failed to import #{format.upcase} file"
        end

        # Find newly imported entities by comparing before/after
        entities_after = model.entities.to_a
        new_entities = entities_after - entities_before

        if new_entities.empty?
          raise "No entities were imported from #{format.upcase} file"
        end

        # Validate entities before grouping
        valid_entities = new_entities.select { |e| e && e.valid? }
        if valid_entities.empty?
          raise "Imported entities are invalid"
        end

        # STEP 2: Group and convert imported entities to component
        temp_group = model.entities.add_group(valid_entities)
        unless temp_group && temp_group.valid?
          raise "Failed to create group for imported entities"
        end

        temp_instance = temp_group.to_component
        unless temp_instance && temp_instance.valid?
          raise "Failed to convert group to component"
        end

        temp_definition = temp_instance.definition
        unless temp_definition && temp_definition.valid?
          raise "Failed to get definition from temp component"
        end

        # Give temp definition a unique name
        geometry_def_name = "#{original_name}_geometry"
        temp_definition.name = geometry_def_name

        # STEP 3: Now that import is complete, verify original_definition still valid
        unless original_definition && original_definition.valid?
          raise "Original XRef definition became invalid during import (may have been auto-purged)"
        end

        # STEP 4: Find and remove old nested geometry definition
        nested_geometry_name = "#{original_name}_geometry"
        old_nested_defs = model.definitions.select { |d| d.name.start_with?(nested_geometry_name) && d != temp_definition }

        # STEP 5: Clear entities from original definition
        original_definition.entities.clear!

        # STEP 6: Clean up old nested definitions now that their instances are gone
        old_nested_defs.each do |old_def|
          if old_def.valid? && old_def.instances.empty?
            begin
              model.definitions.remove(old_def)
            rescue => purge_error
              puts "Warning: Could not purge old nested definition: #{purge_error.message}"
            end
          end
        end

        # STEP 7: Verify original_definition STILL valid after clearing
        unless original_definition && original_definition.valid?
          raise "Original XRef definition became invalid after clearing entities"
        end

        # STEP 8: Add the temp definition as nested instance in original definition
        nested_instance = original_definition.entities.add_instance(temp_definition, Geom::Transformation.new)
        unless nested_instance && nested_instance.valid?
          raise "Failed to create nested instance in XRef definition"
        end

        # STEP 9: Now safe to remove temp instance from model (definition has another instance)
        if temp_instance && temp_instance.valid?
          temp_instance.erase!
        end

        # STEP 10: Update metadata
        original_definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_UNLOADED_KEY, false)
        Core.update_xref_timestamp(original_definition)

        success = true

      rescue => e
        # Clean up temp entities if operation failed
        begin
          if temp_instance && temp_instance.valid?
            temp_instance.erase!
          end
          if temp_definition && temp_definition.valid? && temp_definition.instances.empty?
            model.definitions.remove(temp_definition)
          end
        rescue => cleanup_error
          puts "Warning: Cleanup failed: #{cleanup_error.message}"
        end

        error_msg = "Failed to reload CAD XRef.\nError: #{e.message}\n\nDetails:\n#{e.class}\n#{e.backtrace.first(3).join("\n")}"
        UI.messagebox(error_msg) unless suppress_errors
        puts "OpenXrefManager CAD reload error: #{e.message}"
        puts e.backtrace.first(5).join("\n")
        success = false
      end

      return success
    end

    # --- Format-Specific Import Helpers ---

    # Imports a SKP file as an XRef.
    # If place=true, uses interactive placement. Otherwise places at origin.
    def self.import_skp_xref(path, place: true)
      model = Sketchup.active_model
      new_definition = model.definitions.load(path)
      FileOperations.set_xref_path(new_definition, path, ask_user: true)

      if place
        model.place_component(new_definition, true)
      else
        model.entities.add_instance(new_definition, Geom::Transformation.new)
      end
    end

    # Imports a CAD file (DWG/DXF) as an XRef by wrapping imported entities in a component.
    # If place=true, imports interactively. Otherwise imports at origin.
    def self.import_cad_xref(path, format, place: true)
      model = Sketchup.active_model
      component_name = File.basename(path, ".*")

      # Track entities before import
      entities_before = model.entities.to_a.dup

      # Import the CAD file
      # For DWG/DXF, SketchUp's import creates entities directly in the model
      status = model.import(path, false)  # false = no summary dialog

      unless status
        raise "Failed to import #{format.upcase} file"
      end

      # Find newly imported entities by comparing before/after
      entities_after = model.entities.to_a
      new_entities = entities_after - entities_before

      if new_entities.empty?
        raise "No entities were imported from #{format.upcase} file"
      end

      # Wrap imported entities in a group, then convert to component
      temp_group = model.entities.add_group(new_entities)
      instance = temp_group.to_component
      definition = instance.definition
      definition.name = component_name

      # Mark as XRef with format
      FileOperations.set_xref_path(definition, path, ask_user: true)

      # Note: The instance is already placed where the import occurred (origin or interactive)
      # The 'place' parameter is handled by the import dialog itself
    end

  end
end
