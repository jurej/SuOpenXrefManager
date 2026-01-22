# Building .rbz Files

## Manual Build

To create a new .rbz file for installation:

1. Update the version number in:
   - `OpenXrefManager.rb` (line 25)
   - `OpenXrefManager/core.rb` (line 3)

2. Run the build script:
   ```powershell
   .\build_rbz.ps1
   ```

   Or manually:
   ```powershell
   $version = "1.7.0"  # Update version number
   $zipName = "releases\OpenXrefManager_v$version.zip"
   $rbzName = "releases\OpenXrefManager_v$version.rbz"
   Compress-Archive -Path "OpenXrefManager.rb", "OpenXrefManager" -DestinationPath $zipName -Force
   Move-Item -Path $zipName -Destination $rbzName -Force
   ```

## Installation

1. Open SketchUp
2. Go to **Window > Extension Manager**
3. Click **Install Extension**
4. Select the `.rbz` file from the `releases` folder
5. Restart SketchUp

The extension will appear in the Extension Manager and can be enabled/disabled as needed.
