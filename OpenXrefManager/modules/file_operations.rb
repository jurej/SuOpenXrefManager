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
  module FileOperations

    # --- Format Detection ---

    # Detects the file format from a file path based on extension.
    def self.detect_format_from_path(file_path)
      return nil unless file_path
      ext = File.extname(file_path).downcase
      case ext
      when ".skp" then "skp"
      when ".dwg" then "dwg"
      when ".dxf" then "dxf"
      else nil
      end
    end

    # --- Path Resolution ---

    # Resolves the full, absolute path for an XRef definition, accounting for relative paths.
    def self.resolve_xref_path(definition)
      model = definition.model
      path = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_KEY)
      path_type = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_TYPE_KEY)
      return nil unless path && !path.empty?

      # If the path is relative and the model has been saved, construct the absolute path.
      if path_type == "relative" && model.path && !model.path.empty?
        model_dir = File.dirname(model.path)
        return File.expand_path(File.join(model_dir, path))
      else
        # Otherwise, assume it's an absolute path.
        return path
      end
    end

    # Reads the lock file for a given XRef and returns its content (owner|guid|model_name|model_path).
    def self.get_xref_lock_status(definition)
      path = self.resolve_xref_path(definition)
      return "unlocked" unless path
      lock_path = path + ".lock"
      return "unlocked" unless File.exist?(lock_path)

      begin
        return File.read(lock_path).strip
      rescue => e
        puts "Error reading lock file #{lock_path}: #{e.message}"
        return "unlocked" # Treat as unlocked if lock file is unreadable
      end
    end

    # Checks if a given XRef definition has a newer version available on disk.
    def self.is_update_available?(definition)
      return false unless Core.is_xref?(definition)

      absolute_path = self.resolve_xref_path(definition)
      file_found = absolute_path && File.exist?(absolute_path)
      is_unloaded = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_UNLOADED_KEY) == true
      stored_timestamp = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_TIMESTAMP_KEY)

      # An update can't be available if the file isn't found, is unloaded, or has never been loaded.
      return false unless file_found && !is_unloaded && stored_timestamp

      begin
        file_timestamp = File.mtime(absolute_path).to_i
        return file_timestamp > stored_timestamp
      rescue => e
        puts "Could not get mtime for #{absolute_path}: #{e.message}"
        return false
      end
    end

    # Internal helper to set the path attribute, with an option to ask the user about relative paths.
    def self.set_xref_path(definition, absolute_path, ask_user: true)
      model = definition.model
      use_relative = false

      if ask_user && model.path && !model.path.empty?
        question = "Would you like to save this XRef with a relative path?\n\n" +
                   "Relative paths are recommended for projects where the main file and XRefs are stored together and might be moved."
        result = UI.messagebox(question, Core::MB_YESNO)
        use_relative = (result == Core::IDYES)
      end

      if use_relative
        model_dir = Pathname.new(File.dirname(model.path))
        xref_path = Pathname.new(absolute_path)
        relative_path = xref_path.relative_path_from(model_dir).to_s
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_KEY, relative_path)
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_TYPE_KEY, "relative")
      else
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_KEY, absolute_path)
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_TYPE_KEY, "absolute")
      end

      # Auto-detect and set the format based on file extension
      format = detect_format_from_path(absolute_path)
      if format
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_FORMAT_KEY, format)
      end

      Core.update_xref_timestamp(definition)
    end

    # Toggles an XRef's path between absolute and relative.
    def self.toggle_path_type(component_name)
      model = Sketchup.active_model
      definition = model.definitions.find { |d| d.name == component_name }
      return unless definition

      current_path = self.resolve_xref_path(definition) # Use resolved path
      current_type = definition.get_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_TYPE_KEY) || "absolute"

      model.start_operation("Toggle XRef Path Type", true)

      if current_type == "absolute"
        if model.path && !model.path.empty?
          model_dir = Pathname.new(File.dirname(model.path))
          xref_path = Pathname.new(current_path)
          begin
            relative_path = xref_path.relative_path_from(model_dir).to_s
            definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_KEY, relative_path)
            definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_TYPE_KEY, "relative")
          rescue ArgumentError # Happens if paths are on different drives on Windows
            UI.messagebox("Cannot create a relative path. The XRef file appears to be on a different drive than the model file.")
          end
        else
          UI.messagebox("The main model must be saved to create a relative path.")
        end
      else # "relative"
        absolute_path = self.resolve_xref_path(definition)
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_KEY, absolute_path)
        definition.set_attribute(Core::XREF_DICT_NAME, Core::XREF_PATH_TYPE_KEY, "absolute")
      end

      model.commit_operation
    end

    # Finds all lock files owned by the current user with a specific (old) model GUID
    # and updates them with the new GUID. This is crucial for when a model is saved for the first time.
    def self.update_owned_lock_files(old_guid, new_guid)
      my_xrefs_to_update = Core.get_xref_definitions.select do |definition|
        lock_content = self.get_xref_lock_status(definition)
        next false if lock_content == "unlocked"
        lock_owner_name, lock_owner_guid = lock_content.split('|')
        # Find files locked by this user with the old GUID
        lock_owner_name == Core.user_name && lock_owner_guid == old_guid
      end

      return if my_xrefs_to_update.empty?

      # This is a file system operation, not a model operation.
      my_xrefs_to_update.each do |definition|
        path = self.resolve_xref_path(definition)
        next unless path
        lock_path = path + ".lock"
        begin
          model_path = definition.model.path
          model_name = (model_path.nil? || model_path.empty?) ? "Untitled Model" : File.basename(model_path)
          model_path_str = model_path.nil? ? "" : model_path # Get the full path as a string
          lock_content = "#{Core.user_name}|#{new_guid}|#{model_name}|#{model_path_str}"

          File.write(lock_path, lock_content)
          Core.last_xref_statuses[definition.guid] = lock_content # Update cache
        rescue => e
          puts "Could not update lock file #{lock_path}: #{e.message}"
        end
      end
    end

  end
end
