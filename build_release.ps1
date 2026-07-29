# han_pe_app release build
# Generates timestamp automatically

# Change to the script's directory (the project root)
Set-Location -Path $PSScriptRoot

# Add Flutter to PATH
$env:Path = "D:\flutter_sdk\flutter\bin;" + $env:Path

try {
$timestamp = Get-Date -Format "MM-dd HH:mm"
Write-Host "Building han_pe_app with timestamp: $timestamp" -ForegroundColor Green

# Define custom output directory
$outputDir = "D:\Documents\OneDrive\smartphone"

# Ensure output directory exists
if (-not (Test-Path -Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

# Build APK with timestamp
flutter build apk --release --dart-define=BUILD_DATE="$timestamp"

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nBuild successful!" -ForegroundColor Green
    $srcApk = "build\app\outputs\flutter-apk\app-release.apk"
    $destApk = Join-Path $outputDir "han_pe_app.apk"
    Copy-Item -Path $srcApk -Destination $destApk -Force
    Write-Host "APK copied to: $destApk" -ForegroundColor Cyan
}
else {
    Write-Host "`nBuild failed!" -ForegroundColor Red
}
}
catch {
    Write-Host "`nError occurred: $_" -ForegroundColor Red
}
finally {
    Read-Host "Press Enter to exit..."
}
