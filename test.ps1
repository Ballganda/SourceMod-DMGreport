# Builds the plugin and its test suite, runs the suite on a local srcds unattended, scans the logs
# the run touched, then removes everything it deployed. Exit code: 0 pass, 1 fail, 2 could not start.
#   .\test.ps1                         run on a free test slot (srcds-slot.ps1 checkout/checkin)
#   .\test.ps1 -ServerDir <dir>        run on that server copy instead of a slot (-Port sets its game port)
#   .\test.ps1 -WithClient             also launch the CS:S client so the real-client cases run
#                                      (leave the game window alone while it runs)
#   .\test.ps1 -InjectError            self-check: the suite logs a deliberate error, so this run MUST fail
param(
    [switch]$WithClient,
    [switch]$InjectError,
    [string]$ServerDir = $env:CSS_SERVER_DIR,
    [int]$Port = 27015,
    [string]$ClientDir = $(if ($env:CSS_CLIENT_DIR) { $env:CSS_CLIENT_DIR } else { 'C:\Program Files (x86)\Steam\steamapps\common\Counter-Strike Source' }),
    [string]$Map = 'de_dust2',
    [int]$TimeoutSec = 0
)
$OWNER = 'SourceMod-DMGreport/test'
$SLOT_TOOL = 'C:\Users\user\srcds-slot.ps1'
$PLUGINS = 'sm_damagereport.smx', 'damagereport_tests.smx'
# files the plugin creates on first load; teardown removes those the run created
$GENERATED_FILES = 'configs\damagereportusersettings.cfg', 'configs\sm_damagereport.cfg'
$clientNames = 'cstrike_win64', 'cstrike', 'hl2'
$clientLog = Join-Path $ClientDir 'cstrike\console.log'
$steamExe = Join-Path (Split-Path (Split-Path (Split-Path $ClientDir))) 'steam.exe'
if ($TimeoutSec -eq 0) { $TimeoutSec = if ($WithClient) { 600 } else { 240 } }

$benign = @(
    'metamod[\\/]bin[\\/]win64[\\/]server',      # x64 VDF on a 32-bit server
    'vscript_convar_allowlist\.txt',
    '\[dr_test\]', '\[(PASS|FAIL|WARN|SKIP|INFO)\]', 'tests finished:',
    'damage report test cleanup', 'DRFake'
)
$hard = '\[SM\] (Exception|Blaming|Call stack|Unable to load|Failed to load|Plugin .* failed|Fatal)|' +
        'Exception reported|Native ".*" (reported|was not found)|Script execution timed out|' +
        '<(Failed|Error|Bad Load)>|Could not find required file|Language phrase ".*" not found|' +
        'Host_Error|Engine Error|Segmentation fault|Access violation|Failed to load plugin|required extension'
$soft = '\b(error|errors|exception|failed|failure|unable to|could not|cannot|invalid|not found|missing|warning|deprecated|leak)\b'

function Get-LogSizes([string]$smLogs, [string]$consoleLog) {
    $sizes = @{}
    $files = @(Get-ChildItem $smLogs -Filter *.log -ErrorAction SilentlyContinue)
    if (Test-Path $consoleLog) { $files += Get-Item $consoleLog }
    foreach ($f in $files) { $sizes[$f.FullName] = $f.Length }
    return $sizes
}

# Lines appended to a log since the snapshot (the whole file if it is new).
function Get-NewLines([string]$path, $before) {
    if (-not (Test-Path $path)) { return @() }
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $bytes = New-Object byte[] $fs.Length; [void]$fs.Read($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $from = 0
    if ($before.ContainsKey($path) -and $before[$path] -le $bytes.Length) { $from = $before[$path] }
    if ($from -ge $bytes.Length) { return @() }
    $text = [Text.Encoding]::UTF8.GetString($bytes, $from, $bytes.Length - $from)
    return @($text -split "`r?`n" | Where-Object { $_.Trim() })
}

function Test-Benign([string]$line) {
    foreach ($b in $benign) { if ($line -match $b) { return $true } }
    return $false
}

function Get-FreeUdpPort([int]$from) {
    for ($p = $from; $p -lt $from + 100; $p++) {
        if (-not (Get-NetUDPEndpoint -LocalPort $p -ErrorAction SilentlyContinue)) { return $p }
    }
    throw "no free UDP port from $from"
}

# --- setup: server folder and ports ---
$slot = $null
if (-not $ServerDir) {
    $line = & $SLOT_TOOL checkout -Owner $OWNER
    if ($LASTEXITCODE -ne 0 -or "$line" -notmatch 'slot=(\d+) dir=(\S+) port=(\d+)') {
        Write-Error "no test slot: $line (pass -ServerDir to use a server copy)"; exit 2
    }
    $slot = $Matches[1]; $ServerDir = $Matches[2]; $Port = [int]$Matches[3]
    Write-Host "Checked out slot $slot ($ServerDir, port $Port)"
}
$game = Join-Path $ServerDir 'cstrike'
$smDir = Join-Path $game 'addons\sourcemod'
$smLogs = Join-Path $smDir 'logs'
$consoleLog = Join-Path $game 'console.log'
$testLog = Join-Path $smLogs 'damagereport_tests.log'
$generated = $GENERATED_FILES | ForEach-Object { Join-Path $smDir $_ } | Where-Object { -not (Test-Path $_) }

$problems = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$deployed = @()
$backups = @{}
$proc = $null
$clientStarted = $false
$before = @{}
$exitCode = 0

try {
    $serverExe = Join-Path $ServerDir 'srcds.exe'
    if (Get-CimInstance Win32_Process -Filter "name='srcds.exe'" | Where-Object { $_.ExecutablePath -eq $serverExe }) {
        throw [System.InvalidOperationException]"srcds.exe from $ServerDir is already running"
    }
    if ($WithClient) {
        if (Get-Process $clientNames -ErrorAction SilentlyContinue) { throw [System.InvalidOperationException]'the CS:S client is already running' }
        if (-not (Test-Path $steamExe)) { throw [System.InvalidOperationException]"steam.exe not found at $steamExe" }
    }

    # --- build and deploy, keeping any file the run overwrites ---
    $buildOut = & "$PSScriptRoot\build.ps1" -SourceModDir $smDir 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { $buildOut | Write-Host; throw [System.InvalidOperationException]'build failed' }
    foreach ($l in $buildOut) { if ($l -match ' : (warning|error) \d+') { $warnings.Add('compiler: ' + ($l -replace '^.*\\', '')) } }
    foreach ($p in $PLUGINS) {
        $target = Join-Path $smDir "plugins\$p"
        if (Test-Path $target) { $backups[$target] = [IO.File]::ReadAllBytes($target) }
        Copy-Item (Join-Path $PSScriptRoot "plugins\$p") $target -Force
        $deployed += $target
    }

    # --- run ---
    $before = Get-LogSizes $smLogs $consoleLog
    if (Test-Path $clientLog) { $before[$clientLog] = (Get-Item $clientLog).Length }
    $srcdsArgs = "-console -game cstrike -condebug -tickrate 100 -port $Port +tv_port $($Port + 5) +clientport $($Port + 6) " +
                 "+sv_lan 1 +maxplayers 10 +bot_quota 0 +dr_test_autorun 1 +dr_test_inject_error $([int][bool]$InjectError) " +
                 "+dr_test_wait_client $([int][bool]$WithClient) +map $Map"
    Write-Host "Starting srcds on port $Port ($Map)..."
    $proc = Start-Process $serverExe -ArgumentList $srcdsArgs -WorkingDirectory $ServerDir -PassThru
    if ($WithClient) {
        $ip = (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | Select-Object -First 1).IPv4Address.IPAddress
        $clientPort = Get-FreeUdpPort 27900
        Start-Sleep -Seconds 20
        Write-Host "Launching the CS:S client -> ${ip}:$Port (do not touch the game window)..."
        Start-Process $steamExe -ArgumentList "-applaunch 240 -novid -windowed -w 1024 -h 768 -condebug +clientport $clientPort +connect ${ip}:$Port"
        $clientStarted = $true
    }
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        $problems.Add("server did not quit within ${TimeoutSec}s; it was killed")
    }
}
catch [System.InvalidOperationException] {
    Write-Error $_.Exception.Message
    $exitCode = 2
}
finally {
    if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force; $proc.WaitForExit(10000) | Out-Null }
    if ($clientStarted) { Start-Sleep -Seconds 3; Get-Process $clientNames -ErrorAction SilentlyContinue | Stop-Process -Force }

    # --- judge before teardown: checkin deletes the slot's logs ---
    if ($exitCode -eq 0) {
        $results = Get-NewLines $testLog $before
        $passed = @($results | Where-Object { $_ -match '\[PASS\]' })
        $failed = @($results | Where-Object { $_ -match '\[FAIL\]' })
        $skipped = @($results | Where-Object { $_ -match '\[SKIP\]' })
        $summary = $results | Where-Object { $_ -match 'tests finished:' } | Select-Object -Last 1
        $started = $results | Where-Object { $_ -match 'tests started \((\d+) cases\)' } | Select-Object -Last 1
        if (-not $results.Count) { $problems.Add('the suite wrote nothing to damagereport_tests.log (test plugin not loaded?)') }
        elseif (-not $summary) { $problems.Add('the suite never reached its summary line') }
        $reported = $passed.Count + $failed.Count + $skipped.Count
        if ($started -match 'tests started \((\d+) cases\)' -and $reported -lt [int]$Matches[1]) { $problems.Add("only $reported of $($Matches[1]) cases reported a result") }
        if ($WithClient -and $skipped.Count) { $problems.Add("$($skipped.Count) real-client case(s) were skipped: the client never got into the game") }
        foreach ($l in $failed) { $problems.Add('test: ' + ($l -replace '^.*?(\[FAIL\])', '$1')) }
        foreach ($l in @($results | Where-Object { $_ -match '\[(WARN|INFO)\]' })) { $warnings.Add('test: ' + ($l -replace '^.*?(\[(WARN|INFO)\])', '$1')) }

        $logs = @(Get-ChildItem $smLogs -Filter *.log -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $testLog })
        if (Test-Path $consoleLog) { $logs += Get-Item $consoleLog }
        foreach ($f in $logs) {
            foreach ($l in (Get-NewLines $f.FullName $before)) {
                if ($f.Name -like 'errors_*') { $problems.Add("$($f.Name): $l"); continue }
                if (Test-Benign $l) { continue }
                if ($l -match $hard) { $problems.Add("$($f.Name): $l") }
                elseif ($l -match $soft) { $warnings.Add("$($f.Name): $l") }
            }
        }
        if ($WithClient) {
            $chat = @(Get-NewLines $clientLog $before | Where-Object { $_ -match 'Damage report|inflicted most damage|Attackers|Victims|/drs' })
            if ($chat.Count) { Write-Host "`nClient chat:"; $chat | ForEach-Object { Write-Host "  $_" -ForegroundColor Cyan } }
        }
        Write-Host ''
        foreach ($l in $passed) { Write-Host ($l -replace '^.*?(\[PASS\])', '$1') -ForegroundColor DarkGreen }
        foreach ($l in $skipped) { Write-Host ($l -replace '^.*?(\[SKIP\])', '$1') -ForegroundColor DarkGray }
        foreach ($l in $failed) { Write-Host ($l -replace '^.*?(\[FAIL\])', '$1') -ForegroundColor Red }
        Write-Host "`nCases: $($passed.Count) passed, $($failed.Count) failed, $($skipped.Count) skipped."
    }

    # --- teardown: put back what the run changed ---
    foreach ($t in $deployed) {
        if ($backups.ContainsKey($t)) { [IO.File]::WriteAllBytes($t, $backups[$t]) } else { Remove-Item $t -Force -ErrorAction SilentlyContinue }
    }
    foreach ($g in $generated) { Remove-Item $g -Force -ErrorAction SilentlyContinue }
    if ($slot) {
        $checkin = & $SLOT_TOOL checkin -Slot $slot -Owner $OWNER
        Write-Host "$checkin"
        if ($LASTEXITCODE -ne 0) { $problems.Add("slot not clean after teardown: $checkin") }
    }
}
if ($exitCode -ne 0) { exit $exitCode }

if ($warnings.Count) {
    Write-Host "`nWarnings ($($warnings.Count)):" -ForegroundColor Yellow
    $warnings | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}
if ($problems.Count) {
    Write-Host "`nProblems ($($problems.Count)):" -ForegroundColor Red
    $problems | Select-Object -Unique | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    Write-Host "`nRESULT: FAIL" -ForegroundColor Red
    exit 1
}
Write-Host "`nRESULT: PASS" -ForegroundColor Green
exit 0
