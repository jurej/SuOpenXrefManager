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

require 'pathname' # Required for relative path calculations

module OpenXrefManager
  module Core

    # --- Constants ---
    XREF_DICT_NAME = "OpenXrefManager::Xref"
    XREF_PATH_KEY = "path"
    XREF_PATH_TYPE_KEY = "path_type" # "absolute" or "relative"
    XREF_UNLOADED_KEY = "is_unloaded" # true or false
    XREF_TIMESTAMP_KEY = "timestamp"
    XREF_FORMAT_KEY = "format" # "skp", "dwg", "dxf", etc.
    TIMER_INTERVAL = 5 # Seconds between background checks

    # Supported XRef file formats
    SUPPORTED_FORMATS = {
      "skp" => { name: "SketchUp", ext: ".skp", editable: true },
      "dwg" => { name: "AutoCAD DWG", ext: ".dwg", editable: false },
      "dxf" => { name: "AutoCAD DXF", ext: ".dxf", editable: false }
    }.freeze

    # Messagebox Result Constants
    MB_YESNO = 4
    IDYES = 6
    IDNO = 7
    IDCANCEL = 2

    # --- Module State ---
    @dialog = nil
    @user_name = ENV['USERNAME'] || ENV['USER'] || 'Unknown'
    @timer = nil
    @last_xref_statuses = {}

    # --- State Accessors ---

    def self.dialog
      @dialog
    end

    def self.dialog=(value)
      @dialog = value
    end

    def self.user_name
      @user_name
    end

    def self.user_name=(value)
      @user_name = value
    end

    def self.timer
      @timer
    end

    def self.timer=(value)
      @timer = value
    end

    def self.last_xref_statuses
      @last_xref_statuses
    end

    def self.last_xref_statuses=(value)
      @last_xref_statuses = value
    end

    # --- Basic Helper Methods ---

    # Returns an array of all component definitions in the active model that are marked as XRefs.
    def self.get_xref_definitions
      model = Sketchup.active_model
      return [] unless model && model.valid?
      model.definitions.select { |d| is_xref?(d) }
    end

    # Checks if a given definition is an XRef by looking for the attribute dictionary.
    def self.is_xref?(definition)
      return false unless definition && definition.valid?
      !definition.get_attribute(XREF_DICT_NAME, XREF_PATH_KEY).nil?
    end

    # Helper to update the modification timestamp for an XRef.
    def self.update_xref_timestamp(definition)
      return unless definition && definition.valid?
      # Store as a Unix integer (seconds since epoch)
      definition.set_attribute(XREF_DICT_NAME, XREF_TIMESTAMP_KEY, Time.now.to_i)
    end

    # Locks or unlocks all instances of a given definition.
    def self.lock_or_unlock_instances_for_definition(definition, should_be_locked)
      return unless definition && definition.valid?
      definition.instances.each do |instance|
        instance.locked = should_be_locked if instance.valid? && instance.locked? != should_be_locked
      end
    end

    # Selects all instances of a given component definition in the model.
    def self.select_component_instances(component_name)
      model = Sketchup.active_model
      return unless model && model.valid?

      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition

      # Only proceed if there are instances to select.
      return if definition.instances.empty?

      model.selection.clear
      model.selection.add(definition.instances)

      # Bring SketchUp to the front to show the selection.
      Sketchup.focus

      # Zoom to the new selection.
      view = model.active_view
      view.zoom_extents if model.selection.length > 0
    end

    # Prompts the user to set their name for locking.
    def self.set_user_name
      prompts = ["Enter your name for XRef locking:"]
      defaults = [@user_name]
      input = UI.inputbox(prompts, defaults, "Set XRef User Name")
      @user_name = input[0].strip if input && input[0]
    end

    # --- Format Helper Methods ---

    # Gets the file format for an XRef definition.
    # Returns "skp" by default for backward compatibility with existing XRefs.
    def self.get_xref_format(definition)
      return nil unless definition && definition.valid?
      format = definition.get_attribute(XREF_DICT_NAME, XREF_FORMAT_KEY)
      format || "skp" # Default to skp for backward compatibility
    end

    # Checks if an XRef format can be edited within SketchUp.
    def self.is_editable_format?(definition)
      format = get_xref_format(definition)
      return false unless format && SUPPORTED_FORMATS[format]
      SUPPORTED_FORMATS[format][:editable]
    end

    # Gets the display name for an XRef format.
    def self.get_format_name(definition)
      format = get_xref_format(definition)
      return "Unknown" unless format && SUPPORTED_FORMATS[format]
      SUPPORTED_FORMATS[format][:name]
    end

  end
end
