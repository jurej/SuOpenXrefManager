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

    # Observes entity modifications to prevent unlocking of checked-out XRefs.
    class EntitiesObserver < Sketchup::EntitiesObserver
      def onElementModified(entities, entity)
        # We only care about instances that have been unlocked.
        return unless entity.is_a?(Sketchup::ComponentInstance) && !entity.locked?

        definition = entity.definition
        return unless Core.is_xref?(definition)

        lock_content = FileOperations.get_xref_lock_status(definition)
        return if lock_content == "unlocked"

        lock_owner_name, lock_owner_guid, lock_model_name, _ = lock_content.split('|')
        lock_model_name ||= "an unsaved model"
        is_mine_in_this_window = (lock_owner_name == Core.user_name && lock_owner_guid == entities.model.guid)

        # If the instance was unlocked, but shouldn't have been, re-lock it immediately.
        unless is_mine_in_this_window
          # Use a short timer to avoid issues with modifying the model during a notification.
          UI.start_timer(0.01, false) do
            entity.locked = true if entity.valid?
            Sketchup.set_status_text("Cannot unlock: '#{definition.name}' is checked out by #{lock_owner_name} in '#{lock_model_name}'.")
          end
        end
      end
    end

  end
end
