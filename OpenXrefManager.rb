# Open XRef Manager
# Copyright (C) 2025 Your Name or Company Name
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

require 'sketchup.rb'
require 'extensions.rb'

# Create a new SketchupExtension object.
open_xref_extension = SketchupExtension.new("Open XRef Manager", "OpenXrefManager/OpenXrefManager_main")

# Add some details that will show up in the Extension Manager.
open_xref_extension.description = "A professional XRef management system for collaborative workflows."
open_xref_extension.version = "1.3.4"
open_xref_extension.creator = "Jure Judez"
open_xref_extension.copyright = "2025, licensed under GNU GPL v3"

# Register the extension with SketchUp.
Sketchup.register_extension(open_xref_extension, true)

