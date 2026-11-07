# Captures the game window with GDI (no ffmpeg, no OBS).
# The game keeps running at full speed; frames are written as PNG so
# tests/make_gif.py can assemble them later.
#
#   powershell -ExecutionPolicy Bypass -File tests/record_window.ps1 -Seconds 8 -Fps 12 -Out import/gif_frames/world
param(
    [int]$Seconds = 8,
    [int]$Fps = 10,
    [string]$Out = "import/gif_frames/shot",
    [string]$Process = "Mirotokhome",
    [int]$Width = 0,
    [int]$Delay = 3
)

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32Rect {
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }
}
"@

# Windows scales the desktop at 125% here. A DPI-unaware PowerShell process sees
# a 1024x640 client instead of the real 1280x800 and then starts the capture at
# the logical origin, so the frames get desktop on the left and the title bar on
# top. Per-monitor v2 puts every rect and CopyFromScreen call in real pixels.
if (-not [Win32Rect]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
    [void][Win32Rect]::SetProcessDPIAware()
}

$proc = Get-Process -Name $Process -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $proc) { Write-Error "window not found: $Process"; exit 1 }

# A minimised window reports a zero client rect, so restore it first.
if ([Win32Rect]::IsIconic($proc.MainWindowHandle)) {
    [void][Win32Rect]::ShowWindow($proc.MainWindowHandle, 9)
    Start-Sleep -Milliseconds 600
}
[void][Win32Rect]::SetForegroundWindow($proc.MainWindowHandle)
Start-Sleep -Milliseconds 400
if ($Delay -gt 0) {
    for ($c = $Delay; $c -gt 0; $c--) {
        Write-Host "recording in $c..." -NoNewline
        Start-Sleep -Seconds 1
        Write-Host "`r"
    }
}

$rect = New-Object Win32Rect+RECT
[void][Win32Rect]::GetClientRect($proc.MainWindowHandle, [ref]$rect)
$origin = New-Object Win32Rect+POINT
[void][Win32Rect]::ClientToScreen($proc.MainWindowHandle, [ref]$origin)
# Client area only: the title bar with the new icon must not land in a store GIF.
$w = $rect.Right - $rect.Left
$h = $rect.Bottom - $rect.Top
if ($w -le 0 -or $h -le 0) { Write-Error "bad window rect"; exit 1 }

$scale = if ($Width -gt 0) { $Width / $w } else { 1 }
$outW = [int]($w * $scale)
$outH = [int]($h * $scale)

New-Item -ItemType Directory -Force -Path $Out | Out-Null
Get-ChildItem $Out -Filter '*.png' -ErrorAction SilentlyContinue | Remove-Item -Force

$src = New-Object System.Drawing.Point($origin.X, $origin.Y)
$size = New-Object System.Drawing.Size($w, $h)
$bmp = New-Object System.Drawing.Bitmap($outW, $outH)
$gfx = [System.Drawing.Graphics]::FromImage($bmp)
$gfx.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$gfx.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

$frames = $Seconds * $Fps
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$made = 0
for ($i = 0; $i -lt $frames; $i++) {
    $target = $i * (1000.0 / $Fps)
    $wait = $target - $sw.Elapsed.TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($src, [System.Drawing.Point]::Empty, $size,
        [System.Drawing.CopyPixelOperation]::SourceCopy)
    $g.Dispose()
    $bmp.Save((Join-Path $Out ("f{0:D4}.png" -f $i)),
        [System.Drawing.Imaging.ImageFormat]::Png)
    $made++
}

$sw.Stop()
$gfx.Dispose()
$bmp.Dispose()
Write-Output ("capture origin={0},{1} client={2}x{3}" -f $origin.X, $origin.Y, $w, $h)
Write-Output ("frames={0} in {1:N1}s -> {2:N1} fps, {3}x{4}" -f
    $made, $sw.Elapsed.TotalSeconds, ($made / $sw.Elapsed.TotalSeconds), $outW, $outH)
