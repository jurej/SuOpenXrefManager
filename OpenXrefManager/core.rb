module OpenXrefManager

  # --- Constants ---
  VERSION = "1.4.0"
  XREF_DICT_NAME = "OpenXrefManager::Xref"
  XREF_PATH_KEY = "path"
  XREF_PATH_TYPE_KEY = "path_type" # "absolute" or "relative"
  XREF_UNLOADED_KEY = "is_unloaded" # true or false
  XREF_TIMESTAMP_KEY = "timestamp" # Unix timestamp of file when last loaded
  XREF_EDITED_WITHOUT_LOCK_KEY = "edited_without_lock" # true if user chose to edit without locking

  # Keys for storing "Last Published By" info
  XREF_LAST_PUBLISHER_NAME_KEY = "last_publisher_name"
  XREF_LAST_PUBLISHER_MODEL_KEY = "last_publisher_model"
  XREF_LAST_PUBLISHER_PATH_KEY = "last_publisher_path"

  # --- Global Variables ---
  @user_name = ENV['USERNAME'] || ENV['USER'] || 'Unknown'
  @timer = nil
  @last_xref_statuses = {}
  @last_model_guid = nil
  @dialog = nil # Keep track of the dialog instance
  
  # Using a class variable to hold observer instances to ensure they are not garbage collected.
  @@app_observer = nil

  def self.user_name
    @user_name
  end

  def self.user_name=(name)
    @user_name = name
  end

  # Prompts the user to set their name for locking.
  def self.set_user_name
    prompts = ["User Name:"]
    defaults = [@user_name]
    input = UI.inputbox(prompts, defaults, "Set User Name for XRef Locking")
    if input
      @user_name = input[0]
      # Save to defaults or registry if desired, but for now just in memory/session
      Sketchup.write_default("OpenXrefManager", "UserName", @user_name)
    end
  end

  # Load saved username if available
  saved_name = Sketchup.read_default("OpenXrefManager", "UserName")
  @user_name = saved_name if saved_name && !saved_name.empty?

end
