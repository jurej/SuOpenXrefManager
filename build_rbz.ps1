# Build script for creating .rbz extension files
# Usage: .\build_rbz.ps1 [version]
# If version is not provided, it will read from OpenXrefManager/core.rb

param(
    [string]$Version = ""
)

# If version not provided, try to read from core.rb
if ([string]::IsNullOrEmpty($Version)) {
    $coreFile = "OpenXrefManager\core.rb"
    if (Test-Path $coreFile) {
        $content = Get-Content $coreFile -Raw
        if ($content -match 'VERSION\s*=\s*"([^"]+)"') {
            $Version = $matches[1]
            Write-Host "Detected version: $Version" -ForegroundColor Green
        }
    }
    
    if ([string]::IsNullOrEmpty($Version)) {
        Write-Host "Error: Could not detect version. Please provide version as parameter or ensure VERSION is set in OpenXrefManager/core.rb" -ForegroundColor Red
        exit 1
    }
}

# Create releases directory if it doesn't exist
if (-not (Test-Path "releases")) {
    New-Item -ItemType Directory -Path "releases" | Out-Null
    Write-Host "Created releases directory" -ForegroundColor Green
}

# Build .rbz file
$zipName = "releases\OpenXrefManager_v$Version.zip"
$rbzName = "releases\OpenXrefManager_v$Version.rbz"

Write-Host "Building .rbz file..." -ForegroundColor Yellow
Write-Host "  Version: $Version" -ForegroundColor Cyan
Write-Host "  Output: $rbzName" -ForegroundColor Cyan

# Remove old files if they exist
if (Test-Path $zipName) { Remove-Item $zipName -Force }
if (Test-Path $rbzName) { Remove-Item $rbzName -Force }

# Create ZIP archive
Compress-Archive -Path "OpenXrefManager.rb", "OpenXrefManager" -DestinationPath $zipName -Force

# Rename to .rbz
Move-Item -Path $zipName -Destination $rbzName -Force

# Get file size
$fileInfo = Get-Item $rbzName
$sizeKB = [math]::Round($fileInfo.Length / 1KB, 2)

Write-Host "`nSuccess! Created: $rbzName" -ForegroundColor Green
Write-Host "  Size: $sizeKB KB" -ForegroundColor Cyan
Write-Host "`nReady for installation in SketchUp!" -ForegroundColor Green
