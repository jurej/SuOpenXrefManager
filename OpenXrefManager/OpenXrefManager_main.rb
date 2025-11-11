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

# Main entry point for Open XRef Manager
# This file loads all modules in the correct dependency order

module OpenXrefManager
end

# Load modules in dependency order using Sketchup.require
# Core must be loaded first as it defines constants and state used by other modules
Sketchup.require 'OpenXrefManager/modules/core'

# File operations depend on Core
Sketchup.require 'OpenXrefManager/modules/file_operations'

# XRef operations depend on Core and FileOperations
Sketchup.require 'OpenXrefManager/modules/xref_operations'

# UI Manager depends on Core, FileOperations, and XrefOperations
Sketchup.require 'OpenXrefManager/modules/ui_manager'

# Observers depend on Core, FileOperations, XrefOperations, and UIManager
Sketchup.require 'OpenXrefManager/modules/observers/entities_observer'
Sketchup.require 'OpenXrefManager/modules/observers/model_observer'
Sketchup.require 'OpenXrefManager/modules/observers/app_observer'

# Menu/Toolbar setup depends on all other modules
Sketchup.require 'OpenXrefManager/modules/menu_toolbar'

# Initialize the plugin only once
unless file_loaded?(__FILE__)
  OpenXrefManager::MenuToolbar.setup
  file_loaded(__FILE__)
end
