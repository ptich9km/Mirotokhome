# Build the Windows release of Mirotokhome.
#
# Player rule (11.11): the version MUST be in the executable name --
# build/windows/Mirotokhome0.2.0.exe, never a plain Mirotokhome.exe. A bare name
# makes builds indistinguishable after two releases, and the version is what the
# itch.io channel and the download filename are keyed on.
#
# Version source of truth: the VERSION file in the repository root (one line).
# It is NOT read by the engine -- project.godot has no config/version yet, so the
# Windows file properties still say 0.1.0.0 (see docs/journal/2026-11.md).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tests/build_windows.ps1
#   powershell -ExecutionPolicy Bypass -File tests/build_windows.ps1 -Version 0.2.1
#   powershell -ExecutionPolicy Bypass -File tests/build_windows.ps1 -Push
#
# -Push uploads the build folder to itch.io with butler to the "windows" channel
# and the same version. The API key is read from outside the repository,
# %APPDATA%\Mirotokhome\itch_key, so it never lands in the project folder.

param(
    [string]$Version = "",
    [string]$Godot = "C:\Games\Godot_v4.7.2-stable_win64_console.exe",
    [switch]$Push
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if (-not $Version) {
    $versionFile = Join-Path $repo "VERSION"
    if (-not (Test-Path $versionFile)) {
        throw "VERSION file not found at $versionFile"
    }
    $Version = (Get-Content $versionFile -Raw).Trim()
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version '$Version' is not MAJOR.MINOR.PATCH"
}

$outDir = Join-Path $repo "build\windows"
$out = Join-Path $outDir "Mirotokhome$Version.exe"

New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "exporting $out"
& $Godot --headless --path $repo --export-release "Windows Desktop" $out
if ($LASTEXITCODE -ne 0) {
    throw "godot export failed with exit code $LASTEXITCODE"
}
if (-not (Test-Path $out)) {
    throw "export produced no file: $out"
}

$size = (Get-Item $out).Length / 1MB
Write-Host ("built: {0} ({1:N1} MB)" -f $out, $size)

# A bare Mirotokhome.exe means a stale export or a preset path leak: the preset
# still points at build/windows/Mirotokhome.exe, which is fine for the editor but
# must never be the file we hand out.
$bare = Join-Path $outDir "Mirotokhome.exe"
if (Test-Path $bare) {
    Write-Warning "build/windows/Mirotokhome.exe exists (old naming, not for release); remove it: Remove-Item '$bare'"
}

if ($Push) {
    $butler = Join-Path $env:LOCALAPPDATA "butler\butler.exe"
    $key = Join-Path $env:APPDATA "Mirotokhome\itch_key"
    if (-not (Test-Path $butler)) { throw "butler not found: $butler" }
    if (-not (Test-Path $key)) { throw "itch.io API key not found: $key" }

    # Push the folder, not the exe: the channel then has one build containing
    # Mirotokhome<version>.exe, and patching stays incremental.
    & $butler -i $key push $outDir "ptich9km/mirotokhome:windows" --userversion $Version
    if ($LASTEXITCODE -ne 0) {
        throw "butler push failed with exit code $LASTEXITCODE"
    }
}
