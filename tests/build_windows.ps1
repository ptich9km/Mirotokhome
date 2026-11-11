# Build the Windows release of Mirotokhome.
#
# Player rule (11.11): the version MUST be in the executable name --
# build/windows/Mirotokhome0.2.0.exe, never a plain Mirotokhome.exe. A bare name
# makes builds indistinguishable after two releases, and the version is what the
# itch.io channel and the download filename are keyed on.
#
# Version source of truth: the VERSION file in the repository root (one line).
# The script keeps project.godot's config/version in sync with it, so the Windows
# file properties and the file name cannot disagree.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tests/build_windows.ps1
#   powershell -ExecutionPolicy Bypass -File tests/build_windows.ps1 -Version 0.2.1
#   powershell -ExecutionPolicy Bypass -File tests/build_windows.ps1 -Push
#   powershell -ExecutionPolicy Bypass -File tests/build_windows.ps1 -Force
#
# -Force allows overwriting an executable of the same version. By default an
# existing build/windows/Mirotokhome<version>.exe stops the build: silently
# replacing it would erase the previous build of that version.
#
# -Push uploads the build folder to itch.io with butler to the "windows" channel
# and the same version. The API key is read from outside the repository,
# %APPDATA%\Mirotokhome\itch_key, so it never lands in the project folder.

param(
    [string]$Version = "",
    [string]$Godot = "C:\Games\Godot_v4.7.2-stable_win64_console.exe",
    [switch]$Push,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

$versionFile = Join-Path $repo "VERSION"
$projectFile = Join-Path $repo "project.godot"

if (-not $Version) {
    if (-not (Test-Path $versionFile)) {
        throw "VERSION file not found at $versionFile"
    }
    $Version = (Get-Content $versionFile -Raw).Trim()
}

if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "Version '$Version' is not MAJOR.MINOR.PATCH"
}

# VERSION is the source of truth; project.godot follows it. Two version sources
# that drift are exactly how an exe ends up named 0.2.1 while its properties say
# 0.2.0, so the script writes the engine value instead of trusting it.
$projectText = Get-Content $projectFile -Raw
$engineMatch = [regex]::Match($projectText, 'config/version="([^"]*)"')
if ($engineMatch.Success) {
    $engineVersion = $engineMatch.Groups[1].Value
    if ($engineVersion -ne $Version) {
        $projectText = [regex]::Replace(
            $projectText,
            'config/version="[^"]*"',
            "config/version=`"$Version`"")
        # UTF-8 WITHOUT BOM: Godot refuses to read a project file that starts with
        # one, and Windows PowerShell 5.1 `-Encoding utf8` always adds it.
        [System.IO.File]::WriteAllText($projectFile, $projectText,
            (New-Object System.Text.UTF8Encoding($false)))
        Write-Host "synced config/version in project.godot: $engineVersion -> $Version"
    }
} else {
    throw "project.godot has no config/version; add config/version=`"$Version`" next to config/name"
}

# The Windows file properties do NOT come from config/version: they come from the
# export preset. Two hardcoded "0.1.0.0" values there is how an exe named 0.2.0
# still reports 0.1.0.0 in its Properties dialog, so keep them in sync as well.
$presetFile = Join-Path $repo "export_presets.cfg"
if (Test-Path $presetFile) {
    $winVersion = "$Version.0"   # Windows wants four components
    $presetText = Get-Content $presetFile -Raw
    $changed = $false
    foreach ($key in @("application/file_version", "application/product_version")) {
        $pattern = [regex]::Escape($key) + '="[^"]*"'
        if ([regex]::IsMatch($presetText, $pattern)) {
            $current = [regex]::Match($presetText, [regex]::Escape($key) + '="([^"]*)"').Groups[1].Value
            if ($current -ne $winVersion) {
                $presetText = [regex]::Replace($presetText, $pattern, "$key=`"$winVersion`"")
                Write-Host "synced $key in export_presets.cfg: $current -> $winVersion"
                $changed = $true
            }
        }
    }
    if ($changed) {
        # Same BOM trap as above: export_presets.cfg with a BOM makes Godot report
        # "Invalid export preset name" and lose every preset.
        [System.IO.File]::WriteAllText($presetFile, $presetText,
            (New-Object System.Text.UTF8Encoding($false)))
    }
}

$outDir = Join-Path $repo "build\windows"
$out = Join-Path $outDir "Mirotokhome$Version.exe"

if ((Test-Path $out) -and -not $Force) {
    throw "build already exists: $out. Bump VERSION for a new build, or pass -Force to overwrite."
}

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

# What Windows will show in the file properties. If this does not match the name,
# the export did not pick up config/version.
$fileVersion = (Get-Item $out).VersionInfo.FileVersion
Write-Host "file version properties: $fileVersion"

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
