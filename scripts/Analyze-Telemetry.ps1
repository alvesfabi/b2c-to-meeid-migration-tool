<#
.SYNOPSIS
    Analyzes a worker telemetry JSONL file and prints per-component latency stats and throughput.

.PARAMETER TelemetryFile
    Path to the JSONL telemetry file to analyze (default: ../src/B2CMigrationKit.Console/worker1-telemetry.jsonl).

.EXAMPLE
    .\Analyze-Telemetry.ps1
    .\Analyze-Telemetry.ps1 -TelemetryFile ..\src\B2CMigrationKit.Console\worker2-telemetry.jsonl
#>
param(
    [string]$TelemetryFile = "$PSScriptRoot\..\src\B2CMigrationKit.Console\worker1-telemetry.jsonl"
)

$resolved = Resolve-Path $TelemetryFile -ErrorAction Stop
$lines = [System.IO.File]::ReadAllLines($resolved)

$fetches  = [System.Collections.Generic.List[int]]::new()
$userMs   = [System.Collections.Generic.List[int]]::new()
$bB2c     = [System.Collections.Generic.List[int]]::new()
$bEeidAvg = [System.Collections.Generic.List[int]]::new()
$bEeidMax = [System.Collections.Generic.List[int]]::new()
$timestamps = [System.Collections.Generic.List[datetime]]::new()
$lastStartedTs = $null

foreach ($l in $lines) {
    if ($l -match '"ts":"([^"]+)"') {
        # \u002B is the JSON unicode escape for '+' — replace before parsing
        $tsRaw = $Matches[1] -replace '\\u002B', '+'
        try {
            $ts = [datetime]$tsRaw
            $timestamps.Add($ts)
            # Track the last WorkerMigrate.Started to scope throughput to current run
            if ($l -match '"name":"WorkerMigrate\.Started"') { $lastStartedTs = $ts }
        } catch {}
    }

    if ($l -match '"name":"WorkerMigrate\.B2CFetch"') {
        if ($l -match '"fetchMs":"(\d+)"') { $fetches.Add([int]$Matches[1]) }
    } elseif ($l -match '"name":"WorkerMigrate\.UserCreated"') {
        if ($l -match '"eeidCreateMs":"(\d+)"') { $userMs.Add([int]$Matches[1]) }
    } elseif ($l -match '"name":"WorkerMigrate\.BatchDone"') {
        if ($l -match '"b2cFetchMs":"(\d+)"')  { $bB2c.Add([int]$Matches[1]) }
        if ($l -match '"eeidAvgMs":"(\d+)"')   { $bEeidAvg.Add([int]$Matches[1]) }
        if ($l -match '"eeidMaxMs":"(\d+)"')   { $bEeidMax.Add([int]$Matches[1]) }
    }
}

Write-Host "File   : $resolved"
Write-Host "Parsed : fetches=$($fetches.Count)  users=$($userMs.Count)  batches=$($bB2c.Count)"

function Stats($label, [int[]]$a) {
    if ($a.Count -eq 0) { Write-Host "  $label — no data"; return }
    $s   = $a | Sort-Object
    $n   = $s.Count
    $avg = [Math]::Round(($a | Measure-Object -Average).Average)
    $min = $s[0]; $max = $s[-1]
    $p50 = $s[[int]($n * .50)]
    $p90 = $s[[int]($n * .90)]
    $p95 = $s[[int]($n * .95)]
    $p99 = $s[[int]($n * .99)]
    Write-Host ("  {0,-24} n={1,4}  avg={2,5}ms  min={3,5}  p50={4,5}  p90={5,5}  p95={6,5}  p99={7,5}  max={8,5}" `
        -f $label, $n, $avg, $min, $p50, $p90, $p95, $p99, $max)
}

$wall = [int[]]@(for ($i = 0; $i -lt $bB2c.Count; $i++) { $bB2c[$i] + $bEeidMax[$i] })

Write-Host ""
Write-Host "=== LATENCY BY COMPONENT (ms) ==="
Stats "B2C fetch  (per batch)"   ([int[]]$bB2c)
Stats "EEID create (per user)"   ([int[]]$userMs)
Stats "EEID max   (per batch)"   ([int[]]$bEeidMax)
Stats "EEID avg   (per batch)"   ([int[]]$bEeidAvg)
Stats "Wall time  (b2c+eeid_max)" $wall

Write-Host ""
Write-Host "=== SHARE OF WALL TIME ==="
if ($bB2c.Count -gt 0) {
    $sumB2c  = ($bB2c     | Measure-Object -Sum).Sum
    $sumEeid = ($bEeidMax  | Measure-Object -Sum).Sum
    $sumWall = ($wall      | Measure-Object -Sum).Sum
    Write-Host ("  B2C fetch  : {0,8:N1}s  ({1,3}% of wall)" -f ($sumB2c/1000),  [Math]::Round($sumB2c*100/$sumWall))
    Write-Host ("  EEID create: {0,8:N1}s  ({1,3}% of wall)" -f ($sumEeid/1000), [Math]::Round($sumEeid*100/$sumWall))
    Write-Host ("  Total wall : {0,8:N1}s  (sum across {1} batches)" -f ($sumWall/1000), $bB2c.Count)
}

Write-Host ""
Write-Host "=== THROUGHPUT ==="
if ($timestamps.Count -ge 2) {
    # Use the last WorkerMigrate.Started as t0 to scope to current run only
    $t0 = if ($lastStartedTs) { $lastStartedTs } else { ($timestamps | Sort-Object)[0] }
    $t1 = ($timestamps | Sort-Object)[-1]
    $elapsed = ($t1 - $t0).TotalSeconds
    $runNote = if ($lastStartedTs) { " (from last WorkerMigrate.Started)" } else { " (from first event in file)" }
    Write-Host "  Run start   : $t0$runNote"
    Write-Host "  Last event  : $t1"
    Write-Host ("  Elapsed     : {0:N1}s" -f $elapsed)
    if ($elapsed -gt 0 -and $userMs.Count -gt 0) {
        Write-Host ("  Users/sec   : {0:N2}" -f ($userMs.Count / $elapsed))
        Write-Host ("  Users/min   : {0:N0}" -f ($userMs.Count / $elapsed * 60))
    }
}

Write-Host ""
Write-Host "=== THEORETICAL MAX (20 users/batch) ==="
if ($wall.Count -gt 0) {
    $avgBatch = [Math]::Round(($wall | Measure-Object -Average).Average)
    $minBatch = ($wall | Measure-Object -Minimum).Minimum
    Write-Host ("  At avg wall {0}ms/batch => {1:N1} users/s  ({2:N0} users/min)" `
        -f $avgBatch, (20/$avgBatch*1000), (20/$avgBatch*60000))
    Write-Host ("  At min wall {0}ms/batch => {1:N1} users/s  ({2:N0} users/min)" `
        -f $minBatch, (20/$minBatch*1000), (20/$minBatch*60000))
}

Write-Host ""
Write-Host "=== TAIL LATENCY (EEID > 1000ms) ==="
$slowCount = ($lines | Where-Object {
    $_ -match '"name":"WorkerMigrate\.UserCreated"' -and
    $_ -match '"eeidCreateMs":"(\d+)"' -and [int]$Matches[1] -gt 1000
}).Count
if ($userMs.Count -gt 0) {
    Write-Host ("  Slow users (>1s): {0} / {1}  ({2:N1}%)" `
        -f $slowCount, $userMs.Count, ($slowCount * 100.0 / $userMs.Count))
}
