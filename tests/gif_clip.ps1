# One command = one store GIF: records the game window, then assembles the GIF.
#
#   powershell -ExecutionPolicy Bypass -File tests/gif_clip.ps1 -Name 01_world -Seconds 8
#
# Frames land in import/gif_frames/<Name> (gitignored), the result in
# docs/publish/gifs/<Name>.gif. Run it, then immediately play the scene: the
# window is brought to the front and recording starts at once.
param(
    [Parameter(Mandatory = $true)][string]$Name,
    [int]$Seconds = 4,
    [int]$Fps = 10,
    [int]$Width = 640,
    [int]$GifFps = 0,
    [int]$Delay = 3,
    [switch]$NoTrim
)

if ($GifFps -le 0) { $GifFps = $Fps }
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$frames = Join-Path $root "import/gif_frames/$Name"
$out = Join-Path $root "docs/publish/gifs/$Name.gif"

& (Join-Path $root "tests/record_window.ps1") -Seconds $Seconds -Fps $Fps -Out $frames -Delay $Delay
$count = @(Get-ChildItem $frames -Filter '*.png' -ErrorAction SilentlyContinue).Count
if ($count -eq 0) { Write-Error "recording failed: no frames in $frames"; exit 1 }

$pyArgs = @(
    (Join-Path $root "tests/make_gif.py"),
    "--frames", $frames,
    "--out", $out,
    "--width", $Width,
    "--fps", $GifFps
)
if (-not $NoTrim) { $pyArgs += "--trim" }
& py -3 @pyArgs

