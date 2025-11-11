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
  module Observers

    # Observes model-level events.
    class ModelObserver < Sketchup::ModelObserver
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
        UI.start_timer(0.1, false) { UIManager.check_for_status_changes(show_notification: false) }
      end

      # Add an observer for when the model is saved.
      def onSaveModel(model)
        # This is called when user saves *before* a File > New or File > Open.
        # We check for uncommitted XRefs here.
        if Core.has_uncommitted_changes?
          unless Core.confirm_close_with_uncommitted_changes?("save the main model")
            # Returning false aborts the save operation.
            @operation_aborted = true
            return false
          end
        end
        @operation_aborted = false # Reset flag

        new_guid = model.guid
        # If the GUID changed after saving,
        # find all lock files owned by this user from the previous session state and update them.
        if @guid_before_save != new_guid
          FileOperations.update_owned_lock_files(@guid_before_save, new_guid)
          @guid_before_save = new_guid # Update the stored GUID for the next save.
        end

        # Run a status check after a save to refresh the UI.
        UI.start_timer(0.1, false) { UIManager.check_for_status_changes(show_notification: false) }
        return true # Explicitly allow save
      end

      # Handles auto-checkout when a user starts editing an XRef.
      def onActivePathChanged(model)
        return unless model.active_path # Path is nil when exiting to top level.
        instance = model.active_path.last
        return unless instance.is_a?(Sketchup::ComponentInstance)

        definition = instance.definition
        return unless Core.is_xref?(definition)

        # Prevent editing non-editable formats (DWG/DXF)
        unless Core.is_editable_format?(definition)
          format_name = Core.get_format_name(definition)
          UI.start_timer(0.1, false) do
            UI.messagebox("Cannot edit #{format_name} XRefs in SketchUp.\n\n" +
                          "#{format_name} files are read-only.\n\n" +
                          "Edit the file in its native application (e.g., AutoCAD),\n" +
                          "then reload the XRef to see changes.")
            model.close_active if model.active_path # Exit the component edit context
          end
          return
        end

        # Prevent editing if an update is available.
        if FileOperations.is_update_available?(definition)
          UI.start_timer(0.1, false) do
            UI.messagebox("This XRef has an update available. Please update it from the XRef Manager before editing.")
            model.close_active if model.active_path # Exit the component edit context
          end
          return
        end

        lock_content = FileOperations.get_xref_lock_status(definition)
        is_unlocked = lock_content == "unlocked"

        # Check if it's locked by this user, but in a different SketchUp window/model.
        is_mine_elsewhere = false
        if !is_unlocked
          lock_owner_name, lock_owner_guid, _, _ = lock_content.split('|')
          is_mine_elsewhere = (lock_owner_name == Core.user_name && lock_owner_guid != model.guid)
        end

        # If the component is available or locked by us elsewhere, prompt to check it out.
        return unless is_unlocked || is_mine_elsewhere

        UI.start_timer(0.1, false) do
          message = "You are about to edit the '#{definition.name}' XRef component.\n\n"
          message += is_mine_elsewhere ? "Taking ownership from your other session...\n\n" : ""
          message += "The component will be checked out to you automatically."
          UI.messagebox(message)

          # Force unlock if it was ours elsewhere, then check it out here.
          XrefOperations.force_unlock_xref(definition.name) if is_mine_elsewhere
          XrefOperations.check_out_xref(definition.name)
          UIManager.check_for_status_changes(show_notification: false)
          UIManager.refresh_dialog_data
        end
      end

      # This method is called BEFORE SketchUp shows the 'Save As' dialog.
      def onBeforeComponentSaveAs(instance)
        definition = instance.definition
        return true unless Core.is_xref?(definition)

        # Prevent Save As for non-editable formats (DWG/DXF)
        unless Core.is_editable_format?(definition)
          format_name = Core.get_format_name(definition)
          UI.messagebox("Cannot save #{format_name} XRefs from SketchUp.\n\n" +
                        "#{format_name} files must be edited in their native application.\n\n" +
                        "Edit the file externally, then reload the XRef.")
          return false # Prevent the save operation.
        end

        question = "Warning: You are using SketchUp's native 'Save As' on a linked XRef ('#{definition.name}').\n\n" +
                   "This will create a new, separate component file. The XRef link will be updated to point to the new file.\n\n" +
                   "Do you want to continue?"
        result = UI.messagebox(question, Core::MB_YESNO)

        if result == Core::IDYES
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
        FileOperations.set_xref_path(definition, new_path, ask_user: true)

        UIManager.refresh_dialog_data
        Sketchup.set_status_text("XRef '#{definition.name}' link updated to new file.")
      end

    end

  end
end
