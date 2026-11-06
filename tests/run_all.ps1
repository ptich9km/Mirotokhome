# Run every smoke test of the project and fail on the first broken one.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File tests/run_all.ps1
#   powershell -File tests/run_all.ps1 -Godot "C:\Games\Godot_v4.7.2-stable_win64_console.exe"
#
# The script checks the parse first, then runs every tests/*_smoke.gd. A test
# passes when its output contains "RESULT: OK" or the runtime smoke marker.
# The process exit code is not used: Godot returns 1 on leaked resources even
# when the checks passed.

param(
	[string]$Godot = "",
	[string]$Filter = "*_smoke.gd"
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

Push-Location $root
try {
	Write-Host "== parse =="
	$parse = & $Godot --headless --path . --quit 2>&1
	$parseErrors = $parse | Select-String "SCRIPT ERROR|Parse Error"
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
		$out = & $Godot --headless --path . --script ("res://tests/" + $name + ".gd") 2>&1
		$text = ($out | Out-String)
		$ok = $text.Contains("RESULT: OK") -or $text.Contains("RESULT: PASS") `
			-or $text.Contains("0 fails") -or $text.Contains("SMOKE:")
		if ($ok) {
			$passed += 1
			Write-Host ("  OK   " + $name)
		} else {
			$failed += $name
			Write-Host ("  FAIL " + $name)
			$out | Select-Object -Last 8 | ForEach-Object { Write-Host ("       " + $_) }
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
