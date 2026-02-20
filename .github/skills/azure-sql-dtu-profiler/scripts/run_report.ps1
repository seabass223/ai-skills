<#
.SYNOPSIS
    Azure SQL DTU Profiler – collects Query Store + resource pressure metrics
    and renders a Markdown report with sparklines and ranked offender cards.

.DESCRIPTION
    Connects to Azure SQL Database using Entra ID (via local az CLI context),
    executes the read-only SQL scripts shipped with this skill, and produces
    a compact Markdown report at <OutDir>/azure-sql-dtu-profiler_report.md.

.PARAMETER Window
    Lookback window. Examples: 30m, 1h, 2h. Default: 1h.

.PARAMETER BucketMinutes
    Aggregation bucket size in minutes. Default: 5.

.PARAMETER Top
    Number of top offender queries to include. Default: 10.

.PARAMETER OrderBy
    Ranking metric. Options: cpu, duration, reads, writes, max_duration. Default: cpu.

.PARAMETER OutDir
    Output directory for the report artifact. Default: artifacts.
#>
[CmdletBinding()]
param(
    [string]$Window = '1h',
    [int]   $BucketMinutes = 5,
    [int]   $Top = 10,
    [ValidateSet('cpu', 'duration', 'reads', 'writes', 'max_duration')]
    [string]$OrderBy = 'cpu',
    [string]$OutDir = 'artifacts'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

function Parse-Window ([string]$w) {
    if ($w -match '^(\d+)\s*m$') { return [int]$Matches[1] }
    if ($w -match '^(\d+)\s*h$') { return [int]$Matches[1] * 60 }
    if ($w -match '^(\d+)\s*d$') { return [int]$Matches[1] * 1440 }
    throw "Invalid -Window format '$w'. Use e.g. 30m, 1h, 2h, 1d."
}

function Load-Sql ([string]$FileName, [hashtable]$Tokens) {
    $sql = Get-Content (Join-Path $scriptDir $FileName) -Raw
    foreach ($kv in $Tokens.GetEnumerator()) {
        $sql = $sql.Replace("{{$($kv.Key)}}", "$($kv.Value)")
    }
    return $sql
}

function Invoke-AzureSql ([string]$Query, [string]$ConnStr, [string]$AccessToken = $null) {
    $conn = New-Object System.Data.SqlClient.SqlConnection($ConnStr)
    if ($AccessToken) {
        $conn.AccessToken = $AccessToken
    }
    $conn.Open()
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = 120
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $dt = New-Object System.Data.DataTable
        [void]$adapter.Fill($dt)
        # Comma-prefix prevents PowerShell from enumerating the DataTable rows
        return , $dt
    }
    finally {
        $conn.Close()
        $conn.Dispose()
    }
}

function Format-Number ([double]$n) {
    if ($n -ge 1e6) { return '{0:N1}M' -f ($n / 1e6) }
    if ($n -ge 1e3) { return '{0:N1}K' -f ($n / 1e3) }
    return '{0:N1}' -f $n
}

function Format-Pct ([object]$val) {
    if ($null -eq $val -or $val -is [DBNull]) { return '-' }
    return '{0:N1}%' -f [double]$val
}

# ─────────────────────────────────────────────
# 1. Parse window & compute time range
# ─────────────────────────────────────────────

$windowMinutes = Parse-Window $Window
$endUtc = [DateTime]::UtcNow
$startUtc = $endUtc.AddMinutes(-$windowMinutes)

$startStr = $startUtc.ToString('yyyy-MM-dd HH:mm:ss')
$endStr = $endUtc.ToString('yyyy-MM-dd HH:mm:ss')

Write-Host "Time window : $startStr – $endStr UTC ($Window, ${BucketMinutes}-min buckets)"

# ─────────────────────────────────────────────
# 2. Validate environment
# ─────────────────────────────────────────────

$server = $env:SKILL_AZURE_SQL_SERVER
$database = $env:SKILL_AZURE_SQL_DATABASE

if (-not $server) { throw 'Environment variable SKILL_AZURE_SQL_SERVER is not set.' }
if (-not $database) { throw 'Environment variable SKILL_AZURE_SQL_DATABASE is not set.' }

# Normalise server FQDN
if ($server -notlike '*.*') {
    $server = "$server.database.windows.net"
}

# ─────────────────────────────────────────────
# 3. Authenticate & build connection string
# ─────────────────────────────────────────────

$sqlUser = $env:SKILL_SQL_READONLY_USER
$sqlPass = $env:SKILL_SQL_READONLY_PASSWORD
$accessToken = $null

if ($sqlUser -and $sqlPass) {
    # SQL authentication
    Write-Host 'Using SQL authentication (SKILL_SQL_READONLY_USER / SKILL_SQL_READONLY_PASSWORD)...'
    $connStr = "Server=tcp:${server},1433;Database=${database};User Id=${sqlUser};Password=${sqlPass};Encrypt=True;TrustServerCertificate=False;"
}
else {
    # Entra ID authentication via az CLI
    Write-Host 'Acquiring Entra ID access token via Azure CLI...'
    $tokenRaw = az account get-access-token --resource https://database.windows.net/ --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get access token. Ensure you are logged in (az login).`n$tokenRaw"
    }
    $accessToken = ($tokenRaw | ConvertFrom-Json).accessToken
    Write-Host 'Token acquired.'
    $connStr = "Server=tcp:${server},1433;Database=${database};Encrypt=True;TrustServerCertificate=False;"
}

# ─────────────────────────────────────────────
# 4. Execute SQL collectors
# ─────────────────────────────────────────────

# --- 4a. Resource pressure ---
Write-Host 'Collecting resource pressure...'
$resSql = Load-Sql 'collect_resources.sql' @{
    START_UTC      = $startStr
    END_UTC        = $endStr
    BUCKET_MINUTES = "$BucketMinutes"
}
$resources = Invoke-AzureSql -Query $resSql -ConnStr $connStr -AccessToken $accessToken

# --- 4b. Top queries ---
Write-Host "Collecting top $Top queries (order by $OrderBy)..."
$topSql = Load-Sql 'collect_query_store_top.sql' @{
    START_UTC = $startStr
    END_UTC   = $endStr
    TOP_N     = "$Top"
    ORDER_BY  = $OrderBy
}
try {
    $topQueries = Invoke-AzureSql -Query $topSql -ConnStr $connStr -AccessToken $accessToken
}
catch {
    Write-Warning "Query Store top queries unavailable (Query Store may be disabled): $_"
    $topQueries = $null
}

# --- 4c. Wait stats ---
Write-Host 'Collecting Query Store wait stats...'
$waitSql = Load-Sql 'collect_query_store_waits.sql' @{
    START_UTC = $startStr
    END_UTC   = $endStr
}
try {
    $waits = Invoke-AzureSql -Query $waitSql -ConnStr $connStr -AccessToken $accessToken
}
catch {
    Write-Warning "Wait stats unavailable: $_"
    $waits = $null
}

# ─────────────────────────────────────────────
# 5. Build resource-pressure summary (avg / max / peak bucket)
# ─────────────────────────────────────────────

function Get-MetricSummary ([System.Data.DataTable]$dt, [string]$ColName) {
    if (-not $dt -or $dt.Rows.Count -eq 0) {
        return @{ Avg = '-'; Max = '-'; Peak = '-' }
    }
    $vals = @($dt.Rows | ForEach-Object { [double]$_[$ColName] })
    $avg = ($vals | Measure-Object -Average).Average
    $max = ($vals | Measure-Object -Maximum).Maximum
    # Find the bucket where the max occurred
    $peakRow = $dt.Rows | Where-Object { [double]$_[$ColName] -eq $max } | Select-Object -First 1
    $peak = if ($peakRow) { $peakRow['bucket_utc'] } else { '-' }
    return @{
        Avg  = '{0:N1}%' -f $avg
        Max  = '{0:N1}%' -f $max
        Peak = "$peak"
    }
}

$cpuStats = Get-MetricSummary $resources 'cpu_percent'
$dataIoStats = Get-MetricSummary $resources 'data_io_percent'
$logIoStats = Get-MetricSummary $resources 'log_io_percent'
$memStats = Get-MetricSummary $resources 'memory_percent'

# Compute DTU-ish (max of CPU, DataIO, LogIO per bucket) then summarise
if ($resources -and $resources -is [System.Data.DataTable] -and $resources.Rows.Count -gt 0) {
    $dtuVals = @()
    $dtuPeakVal = 0.0
    $dtuPeakBucket = '-'
    foreach ($row in $resources.Rows) {
        $dtu = [Math]::Max([double]$row['cpu_percent'], [Math]::Max([double]$row['data_io_percent'], [double]$row['log_io_percent']))
        $dtuVals += $dtu
        if ($dtu -gt $dtuPeakVal) {
            $dtuPeakVal = $dtu
            $dtuPeakBucket = $row['bucket_utc']
        }
    }
    $dtuStats = @{
        Avg  = '{0:N1}%' -f (($dtuVals | Measure-Object -Average).Average)
        Max  = '{0:N1}%' -f $dtuPeakVal
        Peak = "$dtuPeakBucket"
    }
}
else {
    $dtuStats = @{ Avg = '-'; Max = '-'; Peak = '-' }
}

# ─────────────────────────────────────────────
# 6. Build wait-stats lookup  (query_id, plan_id) → row
# ─────────────────────────────────────────────

$waitLookup = @{}
if ($waits -and $waits -is [System.Data.DataTable] -and $waits.Rows.Count -gt 0) {
    foreach ($row in $waits.Rows) {
        $key = "$($row['query_id'])|$($row['plan_id'])"
        $waitLookup[$key] = $row
    }
}

# ─────────────────────────────────────────────
# 7. Build offender cards
# ─────────────────────────────────────────────

$offenderCards = [System.Text.StringBuilder]::new()

if ($topQueries -and $topQueries -is [System.Data.DataTable] -and $topQueries.Rows.Count -gt 0) {
    $rank = 0
    foreach ($q in $topQueries.Rows) {
        $rank++
        $qid = $q['query_id']
        $planId = $q['plan_id']
        $key = "$qid|$planId"
        $execs = [long]$q['executions']

        $totalCpu = [double]$q['total_cpu_ms']
        $totalDur = [double]$q['total_duration_ms']
        $maxDur = [double]$q['max_duration_ms']
        $reads = [double]$q['total_logical_reads']
        $writes = [double]$q['total_logical_writes']
        $sampleSql = "$($q['sample_sql_text'])"

        # Truncate SQL for display
        if ($sampleSql.Length -gt 200) {
            $sampleSql = $sampleSql.Substring(0, 197) + '...'
        }

        # Wait profile
        $waitLine = ''
        if ($waitLookup.ContainsKey($key)) {
            $w = $waitLookup[$key]
            $parts = @()
            if ($w['wait_cpu_pct'] -isnot [DBNull] -and [double]$w['wait_cpu_pct'] -gt 0) { $parts += "CPU $(Format-Pct $w['wait_cpu_pct'])" }
            if ($w['wait_lock_pct'] -isnot [DBNull] -and [double]$w['wait_lock_pct'] -gt 0) { $parts += "Lock $(Format-Pct $w['wait_lock_pct'])" }
            if ($w['wait_io_pct'] -isnot [DBNull] -and [double]$w['wait_io_pct'] -gt 0) { $parts += "IO $(Format-Pct $w['wait_io_pct'])" }
            if ($w['wait_mem_pct'] -isnot [DBNull] -and [double]$w['wait_mem_pct'] -gt 0) { $parts += "Mem $(Format-Pct $w['wait_mem_pct'])" }
            if ($w['wait_buflatch_pct'] -isnot [DBNull] -and [double]$w['wait_buflatch_pct'] -gt 0) { $parts += "BufLatch $(Format-Pct $w['wait_buflatch_pct'])" }
            if ($w['wait_unknown_pct'] -isnot [DBNull] -and [double]$w['wait_unknown_pct'] -gt 0) { $parts += "Unknown $(Format-Pct $w['wait_unknown_pct'])" }
            if ($parts.Count -gt 0) {
                $waitLine = $parts -join ' | '
            }
        }

        [void]$offenderCards.AppendLine("### #${rank}  query_id **${qid}** / plan_id **${planId}**")
        [void]$offenderCards.AppendLine('')
        [void]$offenderCards.AppendLine("| Metric | Value |")
        [void]$offenderCards.AppendLine("|--------|-------|")
        [void]$offenderCards.AppendLine("| Executions | $(Format-Number $execs) |")
        [void]$offenderCards.AppendLine("| Total CPU | $(Format-Number $totalCpu) ms |")
        [void]$offenderCards.AppendLine("| Total Duration | $(Format-Number $totalDur) ms |")
        [void]$offenderCards.AppendLine("| Max Duration | $(Format-Number $maxDur) ms |")
        [void]$offenderCards.AppendLine("| Logical Reads | $(Format-Number $reads) |")
        [void]$offenderCards.AppendLine("| Logical Writes | $(Format-Number $writes) |")

        if ($waitLine) {
            [void]$offenderCards.AppendLine("| Wait Profile | $waitLine |")
        }

        [void]$offenderCards.AppendLine('')
        [void]$offenderCards.AppendLine('```sql')
        [void]$offenderCards.AppendLine($sampleSql)
        [void]$offenderCards.AppendLine('```')
        [void]$offenderCards.AppendLine('')
    }

    # ── Also produce "Top 3 by duration" and "Top 3 by reads" summaries
    #    if they surface queries not already in the primary ranking
    $primaryIds = @($topQueries.Rows | ForEach-Object { "$($_['query_id'])|$($_['plan_id'])" })

    # Secondary: by duration
    $byDuration = $topQueries.Rows | Sort-Object { - [double]$_['total_duration_ms'] } | Select-Object -First 3
    $durDiff = $byDuration | Where-Object { $primaryIds.IndexOf("$($_['query_id'])|$($_['plan_id'])") -gt 2 }
    if ($byDuration) {
        [void]$offenderCards.AppendLine('### Also notable – Top 3 by Duration')
        [void]$offenderCards.AppendLine('')
        [void]$offenderCards.AppendLine('| query_id | plan_id | Total Duration (ms) | Total CPU (ms) |')
        [void]$offenderCards.AppendLine('|----------|---------|---------------------|----------------|')
        foreach ($d in $byDuration) {
            [void]$offenderCards.AppendLine("| $($d['query_id']) | $($d['plan_id']) | $(Format-Number ([double]$d['total_duration_ms'])) | $(Format-Number ([double]$d['total_cpu_ms'])) |")
        }
        [void]$offenderCards.AppendLine('')
    }

    # Secondary: by reads
    $byReads = $topQueries.Rows | Sort-Object { - [double]$_['total_logical_reads'] } | Select-Object -First 3
    if ($byReads) {
        [void]$offenderCards.AppendLine('### Also notable – Top 3 by Reads')
        [void]$offenderCards.AppendLine('')
        [void]$offenderCards.AppendLine('| query_id | plan_id | Logical Reads | Total CPU (ms) |')
        [void]$offenderCards.AppendLine('|----------|---------|---------------|----------------|')
        foreach ($r in $byReads) {
            [void]$offenderCards.AppendLine("| $($r['query_id']) | $($r['plan_id']) | $(Format-Number ([double]$r['total_logical_reads'])) | $(Format-Number ([double]$r['total_cpu_ms'])) |")
        }
        [void]$offenderCards.AppendLine('')
    }
}
else {
    [void]$offenderCards.AppendLine('> **No Query Store data found for this time window.**')
    [void]$offenderCards.AppendLine('> Query Store may be disabled or the window may be too narrow.')
}

# ─────────────────────────────────────────────
# 9. Fill template & write report
# ─────────────────────────────────────────────

$templatePath = Join-Path $scriptDir 'templates\report.md.tmpl'
$template = Get-Content $templatePath -Raw

$report = $template `
    -replace [regex]::Escape('{{SERVER}}'), $server `
    -replace [regex]::Escape('{{DATABASE}}'), $database `
    -replace [regex]::Escape('{{START_UTC}}'), $startStr `
    -replace [regex]::Escape('{{END_UTC}}'), $endStr `
    -replace [regex]::Escape('{{WINDOW}}'), $Window `
    -replace [regex]::Escape('{{BUCKET_MINUTES}}'), "$BucketMinutes" `
    -replace [regex]::Escape('{{DTU_AVG}}'), $dtuStats.Avg `
    -replace [regex]::Escape('{{DTU_MAX}}'), $dtuStats.Max `
    -replace [regex]::Escape('{{DTU_PEAK}}'), $dtuStats.Peak `
    -replace [regex]::Escape('{{CPU_AVG}}'), $cpuStats.Avg `
    -replace [regex]::Escape('{{CPU_MAX}}'), $cpuStats.Max `
    -replace [regex]::Escape('{{CPU_PEAK}}'), $cpuStats.Peak `
    -replace [regex]::Escape('{{DATAIO_AVG}}'), $dataIoStats.Avg `
    -replace [regex]::Escape('{{DATAIO_MAX}}'), $dataIoStats.Max `
    -replace [regex]::Escape('{{DATAIO_PEAK}}'), $dataIoStats.Peak `
    -replace [regex]::Escape('{{LOGIO_AVG}}'), $logIoStats.Avg `
    -replace [regex]::Escape('{{LOGIO_MAX}}'), $logIoStats.Max `
    -replace [regex]::Escape('{{LOGIO_PEAK}}'), $logIoStats.Peak `
    -replace [regex]::Escape('{{MEM_AVG}}'), $memStats.Avg `
    -replace [regex]::Escape('{{MEM_MAX}}'), $memStats.Max `
    -replace [regex]::Escape('{{MEM_PEAK}}'), $memStats.Peak `
    -replace [regex]::Escape('{{OFFENDERS}}'), $offenderCards.ToString()

# Ensure output directory exists
if (-not (Test-Path $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# Determine output file path, appending a sequential number if it already exists
$baseName = 'azure-sql-dtu-profiler_report'
$outPath = Join-Path $OutDir "${baseName}.md"
if (Test-Path $outPath) {
    $seq = 1
    while (Test-Path (Join-Path $OutDir "${baseName}_${seq}.md")) {
        $seq++
    }
    $outPath = Join-Path $OutDir "${baseName}_${seq}.md"
}

# $report | Out-File -FilePath $outPath -Encoding utf8 -Force

Write-Host ''
# Write-Host "Report written to: artifacts\azure-sql-dtu-profiler_report_example.md" -ForegroundColor Green
Write-Host "Report written to: $outPath" -ForegroundColor Green
Write-Host ''

# Return report content to stdout so the agent can display it
Write-Output $report
