# Compiles scripting\*.sp (the plugin) and tests\*.sp (the test suite) into plugins\*.smx
# with the spcomp of the SourceMod install on the local test server.
# Shared includes (instance_config) come from the incs submodule (github.com/Ballganda/SourceMod-Incs);
# its include folder is searched before SourceMod's own.
#   .\build.ps1                          compile only
#   .\build.ps1 -DeployTo <SourceModDir> compile, then copy the .smx files into that SourceMod install
#   .\build.ps1 -Package                 compile, then write plugins\sm_damagereport-<version>.zip (the release zip)
#   git submodule update --init          once after cloning
param(
    [string]$DeployTo,
    [switch]$Package,
    [string]$SourceModDir = $(if ($env:SOURCEMOD_DIR) { $env:SOURCEMOD_DIR } else { 'C:\Users\user\cssds\cstrike\addons\sourcemod' })
)

$spcomp = Join-Path $SourceModDir 'scripting\spcomp.exe'
if (-not (Test-Path $spcomp)) { Write-Error "spcomp not found at $spcomp"; exit 1 }

$incs = Join-Path $PSScriptRoot 'incs\scripting\include'
if (-not (Test-Path (Join-Path $incs 'instance_config.inc'))) {
    Write-Error "Shared includes missing at $incs. Run: git submodule update --init"; exit 1
}

$src = Join-Path $PSScriptRoot 'scripting'
$out = Join-Path $PSScriptRoot 'plugins'
New-Item -ItemType Directory -Force $out | Out-Null

$failed = 0
$targets = @(Get-ChildItem $src -Filter *.sp) + @(Get-ChildItem (Join-Path $PSScriptRoot 'tests') -Filter *.sp -ErrorAction SilentlyContinue)
foreach ($sp in $targets) {
    $smx = Join-Path $out ($sp.BaseName + '.smx')
    & $spcomp $sp.FullName "-i$incs" "-i$SourceModDir\scripting\include" "-o$smx"
    if ($LASTEXITCODE -ne 0) { $failed++; continue }
    if ($DeployTo) {
        Copy-Item $smx (Join-Path $DeployTo 'plugins') -Force
        Write-Host "Deployed $($sp.BaseName).smx"
    }
}
if ($failed) { Write-Error "$failed plugin(s) failed to compile"; exit 1 }

if ($Package) {
    # Release zip: extracted into the server's cstrike folder. Only the plugin, never the test suite.
    $plugin = 'sm_damagereport'
    $version = (Select-String -Path "$src\$plugin.sp" -Pattern '#define\s+PLUGIN_VERSION\s+"([^"]+)"').Matches[0].Groups[1].Value
    if (-not $version) { Write-Error "PLUGIN_VERSION not found in $plugin.sp"; exit 1 }
    $stage = Join-Path $out 'package'
    $sm = Join-Path $stage 'addons\sourcemod'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Force "$sm\plugins", "$sm\scripting\include" | Out-Null
    Copy-Item "$out\$plugin.smx" "$sm\plugins"
    Copy-Item "$src\$plugin.sp" "$sm\scripting"
    # GPL v3 text beside the source (not addons/sourcemod/LICENSE.txt, which is SourceMod's own)
    Copy-Item "$PSScriptRoot\LICENSE" "$sm\scripting\$plugin-LICENSE.txt"
    # every include the plugin uses from the submodule, so the zip recompiles on its own
    foreach ($inc in Get-ChildItem $incs -Filter *.inc) {
        if (Select-String -Path "$src\$plugin.sp" -Pattern "#include\s+<$($inc.BaseName)>" -Quiet) {
            Copy-Item $inc.FullName "$sm\scripting\include"
        }
    }
    $zip = Join-Path $out "$plugin-$version.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    # not Compress-Archive: on Windows PowerShell 5.1 it writes `\` into entry names, which Linux unzip keeps literally
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::Open($zip, 'Create')
    try {
        foreach ($f in Get-ChildItem $stage -Recurse -File) {
            $entry = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry)
        }
    } finally { $archive.Dispose() }
    Remove-Item $stage -Recurse -Force
    Write-Host "Packaged $zip"
}
