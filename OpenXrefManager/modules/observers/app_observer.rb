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

    # Observes application-level events like opening new models.
    class AppObserver < Sketchup::AppObserver
      def initialize
        @model_observers = {}
        @entities_observers = {}
      end

      def onNewModel(model)
        attach_observers(model)
        UIManager.refresh_dialog_data
      end

      def onOpenModel(model)
        attach_observers(model)
        UIManager.refresh_dialog_data
        UI.start_timer(0, false) do
          check_xrefs_and_show_manager
        end
      end

      def onQuit()
        UIManager.stop_timer
      end

      # Check statuses and show dialog if any XRefs need attention.
      def check_xrefs_and_show_manager
        # Make sure model is valid
        model = Sketchup.active_model
        return unless model && model.valid?

        # We can leverage the get_xref_data_as_json method to get statuses,
        # but we need to parse the JSON it returns.
        json_data = UIManager.get_xref_data_as_json

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
          if Core.dialog.nil? || !Core.dialog.visible?
            UIManager.show_manager_dialog
          else
            Core.dialog.bring_to_front
          end
        end
      end

      # Attaches model and entities observers to a given model.
      def attach_observers(model)
        detach_observers(model) # Ensure no old observers are lingering

        Core.last_xref_statuses = {}

        model_observer = ModelObserver.new
        model.add_observer(model_observer)
        @model_observers[model.guid] = model_observer

        entities_observer = EntitiesObserver.new
        model.entities.add_observer(entities_observer)
        @entities_observers[model.guid] = entities_observer

        UIManager.start_timer
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
end
