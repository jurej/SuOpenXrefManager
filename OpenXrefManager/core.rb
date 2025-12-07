module OpenXrefManager

  # --- Constants ---
  VERSION = "1.6.0"
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
  
  # Settings dictionary and keys
  SETTINGS_DICT_NAME = "OpenXrefManager::Settings"
  SETTINGS_AUTO_CHECKOUT_KEY = "auto_checkout_on_edit"
  SETTINGS_CHECK_INTERVAL_KEY = "check_interval_seconds"
  DEFAULT_CHECK_INTERVAL = 2.0 # Default: 2 seconds
  
  # Travel-through mode keys (stored in model settings)
  SETTINGS_TRAVEL_THROUGH_XREFS_KEY = "travel_through_xrefs" # Hash of definition GUID => user info

  # --- Global Variables ---
  @user_name = ENV['USERNAME'] || ENV['USER'] || 'Unknown'
  @timer = nil
  @last_xref_statuses = {}
  @last_model_guid = nil
  @dialog = nil # Keep track of the dialog instance
  @monitoring_paused = false # Track if background monitoring is paused
  @travel_through_active = {} # Track active travel-through state: definition GUID => true
  
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
  
  # Gets the auto-checkout setting from the current model (default: true)
  def self.get_auto_checkout_setting
    model = Sketchup.active_model
    return true unless model
    setting = model.get_attribute(SETTINGS_DICT_NAME, SETTINGS_AUTO_CHECKOUT_KEY)
    return true if setting.nil? # Default to true (auto-checkout enabled)
    return setting
  end
  
  # Sets the auto-checkout setting for the current model
  def self.set_auto_checkout_setting(enabled)
    model = Sketchup.active_model
    return unless model
    model.set_attribute(SETTINGS_DICT_NAME, SETTINGS_AUTO_CHECKOUT_KEY, enabled)
  end
  
  # Gets the check interval setting (in seconds) from SketchUp defaults (default: 2.0)
  def self.get_check_interval_setting
    interval = Sketchup.read_default("OpenXrefManager", "CheckIntervalSeconds", DEFAULT_CHECK_INTERVAL)
    # Ensure it's a valid number between 1 and 60 seconds
    interval = interval.to_f
    interval = DEFAULT_CHECK_INTERVAL if interval < 1.0 || interval > 60.0
    return interval
  end
  
  # Sets the check interval setting (in seconds)
  def self.set_check_interval_setting(seconds)
    # Clamp between 1 and 60 seconds
    seconds = seconds.to_f
    seconds = [[seconds, 1.0].max, 60.0].min
    Sketchup.write_default("OpenXrefManager", "CheckIntervalSeconds", seconds)
  end
  
  # Opens settings dialog
  def self.show_settings_dialog
    model = Sketchup.active_model
    return unless model
    
    current_auto_checkout = get_auto_checkout_setting
    current_interval = get_check_interval_setting
    
    prompts = ["Automatically check out when entering XRef:", "Background check interval (seconds):"]
    defaults = [current_auto_checkout ? "Yes" : "No", current_interval.to_s]
    list = ["Yes|No", ""]
    
    input = UI.inputbox(prompts, defaults, list, "XRef Manager Settings")
    if input
      # Auto-checkout setting
      new_auto_checkout = (input[0] == "Yes")
      set_auto_checkout_setting(new_auto_checkout)
      
      # Check interval setting
      new_interval = input[1].to_f
      if new_interval < 1.0 || new_interval > 60.0
        UI.messagebox("Check interval must be between 1 and 60 seconds. Using default (2.0 seconds).")
        new_interval = DEFAULT_CHECK_INTERVAL
      end
      set_check_interval_setting(new_interval)
      
      # Restart timer with new interval if it changed
      if new_interval != current_interval
        self.start_timer
      end
      
      UI.messagebox("Settings saved.\n\n" +
                    "Auto-checkout when entering XRef: #{new_auto_checkout ? 'Enabled' : 'Disabled'}\n" +
                    "Background check interval: #{new_interval} seconds\n\n" +
                    (new_auto_checkout ? 
                      "XRefs will automatically prompt for checkout when you double-click to edit them." :
                      "You must manually check out XRefs before editing them."))
    end
  end
  
  # Pauses background monitoring
  def self.pause_monitoring
    @monitoring_paused = true
    # Update dialog button if dialog is open
    if @dialog && @dialog.visible?
      @dialog.execute_script("setMonitoringButtonState(true);")
    end
  end
  
  # Resumes background monitoring
  def self.resume_monitoring
    @monitoring_paused = false
    # Update dialog button if dialog is open
    if @dialog && @dialog.visible?
      @dialog.execute_script("setMonitoringButtonState(false);")
    end
    # Immediately check for changes when resuming
    check_for_status_changes(show_notification: false)
  end
  
  # Returns whether monitoring is paused
  def self.monitoring_paused?
    @monitoring_paused
  end

  # Load saved username if available
  saved_name = Sketchup.read_default("OpenXrefManager", "UserName")
  @user_name = saved_name if saved_name && !saved_name.empty?

end
