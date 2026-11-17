# Run every smoke test of the project and fail on the first broken one.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tests/run_all.ps1
#   powershell -File tests/run_all.ps1 -Godot "C:\Games\Godot_v4.7.2-stable_win64_console.exe"
#   powershell -File tests/run_all.ps1 -TestTimeoutSec 300
#
# The script checks the parse first, then runs every tests/*_smoke.gd. A test
# passes when its output contains "RESULT: OK" or the runtime smoke marker.
# The process exit code is not used: Godot returns 1 on leaked resources even
# when the checks passed.
#
# Every Godot run is hard-capped by -TestTimeoutSec. A hanging test must not hang
# the whole run (a broken script can leave the process spinning forever), so the
# child is started with Start-Process and killed on timeout; such a test counts
# as failed and the run continues.

param(
	[string]$Godot = "",
	[string]$Filter = "*_smoke.gd",
	[int]$TestTimeoutSec = 240,
	[int]$ParseTimeoutSec = 300
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot

if ($Godot -eq "") {
	$candidates = @(
		"C:\Work\Godot_v4.7.2-stable_win64_console.exe",
		"C:\Games\Godot_v4.7.2-stable_win64_console.exe",
		"D:\Work\UnityProjects\Godot_v4.7.2-stable_win64_console.exe"
	)
	foreach ($c in $candidates) {
		if (Test-Path $c) {
			$Godot = $c
			break
		}
	}
}
if ($Godot -eq "" -or -not (Test-Path $Godot)) {
	throw "Godot console executable not found. Pass -Godot <path>."
}

# Run Godot with a hard timeout; returns @{ text = output; timed_out = bool }.
function Invoke-GodotCapped {
	param(
		[string]$Exe,
		[string[]]$Arguments,
		[int]$TimeoutSec,
		[string]$Tag
	)
	$logOut = Join-Path $env:TEMP ("godot_" + $Tag + ".out.log")
	$logErr = Join-Path $env:TEMP ("godot_" + $Tag + ".err.log")
	if (Test-Path $logOut) { Remove-Item $logOut -Force }
	if (Test-Path $logErr) { Remove-Item $logErr -Force }
	$proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -PassThru `
		-RedirectStandardOutput $logOut -RedirectStandardError $logErr
	$finished = $proc.WaitForExit($TimeoutSec * 1000)
	if (-not $finished) {
		try { $proc.Kill($true) } catch {}
		return @{ text = ""; timed_out = $true }
	}
	$lines = @()
	try { $lines += Get-Content $logOut } catch {}
	try { $lines += Get-Content $logErr } catch {}
	return @{ text = ($lines | Out-String); timed_out = $false }
}

Push-Location $root
try {
	Write-Host "== parse =="
	$parse = Invoke-GodotCapped -Exe $Godot -Arguments @("--headless", "--path", ".", "--quit") `
		-TimeoutSec $ParseTimeoutSec -Tag "parse"
	if ($parse.timed_out) {
		throw ("parse timed out after " + $ParseTimeoutSec + " s")
	}
	$parseErrors = $parse.text -split "`r?`n" | Select-String "SCRIPT ERROR|Parse Error"
	if ($parseErrors) {
		$parseErrors | ForEach-Object { Write-Host $_ }
		throw "parse failed"
	}
	Write-Host "parse OK"

	# perf_probe and stress_1m are measuring instruments, not pass/fail gates.
	$skip = @("perf_probe_smoke", "stress_1m_smoke")
	$tests = Get-ChildItem "tests" -Filter $Filter |
		Where-Object { $skip -notcontains $_.BaseName } |
		Sort-Object Name
	$failed = @()
	$passed = 0
	foreach ($test in $tests) {
		$name = $test.BaseName
		$run = Invoke-GodotCapped -Exe $Godot `
			-Arguments @("--headless", "--path", ".", "--script", ("res://tests/" + $name + ".gd")) `
			-TimeoutSec $TestTimeoutSec -Tag $name
		if ($run.timed_out) {
			$failed += $name
			Write-Host ("  TIMEOUT " + $name + " (> " + $TestTimeoutSec + " s), process killed")
			continue
		}
		$text = $run.text
		$ok = $text.Contains("RESULT: OK") -or $text.Contains("RESULT: PASS") `
			-or $text.Contains("0 fails") -or $text.Contains("SMOKE:")
		if ($ok) {
			$passed += 1
			Write-Host ("  OK   " + $name)
		} else {
			$failed += $name
			Write-Host ("  FAIL " + $name)
			($text -split "`r?`n") | Select-Object -Last 8 | ForEach-Object { Write-Host ("       " + $_) }
		}
	}

	Write-Host ""
	Write-Host ("smoke: " + $passed + " passed, " + $failed.Count + " failed")
	if ($failed.Count -gt 0) {
		Write-Host ("failed: " + ($failed -join ", "))
		exit 1
	}
} finally {
	Pop-Location
}
