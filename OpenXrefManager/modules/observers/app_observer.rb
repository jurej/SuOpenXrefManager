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
      end

      def onQuit()
        UIManager.stop_timer
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
