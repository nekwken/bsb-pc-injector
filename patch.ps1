#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Install BSB runtime mode: restore official asar + launcher + injector.
  Does NOT patch app.asar. Official client updates do not require re-patching.

.EXAMPLE
  .\patch.ps1
  .\patch.ps1 -InstallRoot "C:\Program Files\bilibili"
#>
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$PayloadDir,
    [switch]$Force,
    [switch]$NoAutostart,   # skip logon autostart + shortcut rewriting
    [switch]$WithLaunchers, # also (re)create the 哔哩哔哩-BSB launcher shortcuts
    [switch]$SkipUpdateYml  # kept for compat; runtime mode never needs this
)

$ErrorActionPreference = "Stop"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

. (Join-Path $PatcherRoot "tools\Asar.ps1")
. (Join-Path $PatcherRoot "tools\Find-Client.ps1")
. (Join-Path $PatcherRoot "tools\Shortcuts.ps1")

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }
function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding $false))
}

$StateRoot = Get-StateRoot
$BackupDir = Join-Path $StateRoot "backups"
$LogDir = Join-Path $StateRoot "logs"
$PayloadRuntime = Join-Path $StateRoot "payload"
$StatePath = Join-Path $StateRoot "state.json"
$RuntimeDir = Join-Path $PatcherRoot "runtime"
New-Item -ItemType Directory -Force -Path $StateRoot, $BackupDir, $LogDir, $PayloadRuntime | Out-Null
$logFile = Join-Path $LogDir ("runtime-install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $logFile -Append | Out-Null

try {
    Write-Host ""
    Write-Host "BSB Client Runtime Injector" -ForegroundColor Magenta
    Write-Host "Mode: CDP runtime (official app.asar will NOT be patched)"
    Write-Host "State: $StateRoot"
    Write-Host ""

    if (-not $PayloadDir) { $PayloadDir = Join-Path $PatcherRoot "payload" }
    if (-not (Test-Path (Join-Path $PayloadDir "manifest.json"))) {
        throw "Invalid payload: $PayloadDir"
    }
    $manifest = Get-Content (Join-Path $PayloadDir "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Step "Payload v$($manifest.version)"

    Write-Step "Sync payload -> $PayloadRuntime"
    if (Test-Path $PayloadRuntime) { Remove-Item -Recurse -Force $PayloadRuntime }
    Copy-Item -Recurse -Force $PayloadDir $PayloadRuntime
    Write-Ok "payload ready"

    # default config into state dir
    $cfgSrc = Join-Path $PayloadRuntime "bsb-config.default.json"
    $cfgDst = Join-Path $StateRoot "bsb-config.json"
    if ((Test-Path $cfgSrc) -and -not (Test-Path $cfgDst)) {
        Copy-Item -Force $cfgSrc $cfgDst
        Write-Ok "wrote default config: $cfgDst"
    }

    Write-Step "Locate official client"
    $root = $null
    if ($InstallRoot) {
        if (-not (Test-Path (Join-Path $InstallRoot "resources\app.asar"))) {
            throw "Invalid InstallRoot: $InstallRoot"
        }
        $root = (Resolve-Path $InstallRoot).Path
    } else {
        $root = Find-BilibiliInstall -StatePath $StatePath
    }
    if (-not $root) { throw "Bilibili PC client not found. Use -InstallRoot" }
    Write-Ok "InstallRoot: $root"

    # find exe
    $exe = Get-ChildItem $root -Filter "*.exe" -File | Where-Object {
        $_.Name -match "bili|哔哩" -and $_.Name -notmatch "uninstall|卸载|elevate"
    } | Select-Object -First 1
    if (-not $exe) {
        $exe = Get-ChildItem $root -Filter "*.exe" -File | Select-Object -First 1
    }
    if (-not $exe) { throw "Cannot find client exe under $root" }
    Write-Ok "Exe: $($exe.FullName)"

    # Ensure official asar (unpatch if previously patched)
    $asarPath = Join-Path $root "resources\app.asar"
    $asarHash = Get-FileSha256 -Path $asarPath
    Write-Step "Check app.asar official-ness"
    $tool = Initialize-AsarTool -PatcherRoot $PatcherRoot
    $probe = Join-Path $StateRoot "work-probe"
    Expand-AsarFile -Tool $tool -AsarPath $asarPath -DestDir $probe
    $idxTxt = Get-Content (Join-Path $probe "index.js") -Raw -Encoding UTF8
    $mainTxt = ""
    try { $mainTxt = Get-Content (Join-Path $probe "main\index.js") -Raw -Encoding UTF8 } catch {}
    $needsRestore = $false
    if ($idxTxt -match "bsb-hooks|bsb-bootstrap|__BSB_HOST__") { $needsRestore = $true }
    if ($mainTxt -match "bsb/bsb-hooks") { $needsRestore = $true }
    if (Test-Path (Join-Path $probe "bsb\manifest.json")) { $needsRestore = $true }

    if ($needsRestore) {
        Write-Warn2 "asar contains BSB patch - restoring official backup"
        $bak = Join-Path $BackupDir "app.asar.bak"
        if (-not (Test-Path $bak)) { throw "No official backup at $bak" }
        try {
            Copy-Item -Force $bak $asarPath
            Write-Ok "app.asar restored from backup"
        } catch {
            throw "Cannot write app.asar (need admin). Run unpatch.ps1 elevated, then re-run this script."
        }
        # restore yml best-effort
        $ymlBak = Join-Path $BackupDir "app-update.yml.bak"
        $yml = Join-Path $root "resources\app-update.yml"
        if (Test-Path $ymlBak) {
            try { Copy-Item -Force $ymlBak $yml } catch {}
        }
    } else {
        Write-Ok "asar already official"
    }

    # 无感模式下不需要专用图标（快捷方式已就地带上调试端口），所以默认不再创建；
    # 需要旧的「哔哩哔哩-BSB」图标时加 -WithLaunchers。
    $launcherArgs = "--remote-debugging-port=9222 --remote-allow-origins=*"
    if ($WithLaunchers) {
        Write-Step "Create launcher shortcuts"
        $desktop = [Environment]::GetFolderPath("Desktop")
        $startMenu = Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs"
        $targets = @(
            (Join-Path $desktop "哔哩哔哩-BSB.lnk"),
            (Join-Path $startMenu "哔哩哔哩-BSB.lnk")
        )
        $wsh = New-Object -ComObject WScript.Shell
        foreach ($lnkPath in $targets) {
            try {
                $sc = $wsh.CreateShortcut($lnkPath)
                $sc.TargetPath = $exe.FullName
                $sc.Arguments = $launcherArgs
                $sc.WorkingDirectory = $root
                $sc.Description = "Bilibili PC + BSB runtime injector"
                $sc.Save()
                Write-Ok "Shortcut: $lnkPath"
            } catch {
                Write-Warn2 "shortcut failed: $lnkPath $($_.Exception.Message)"
            }
        }
    } else {
        Write-Step "Launcher shortcuts"
        Write-Ok "skipped (no need: shortcuts carry the debug port; use -WithLaunchers to create them)"
    }

    Write-Step "Seamless startup"
    if ($NoAutostart) {
        Write-Warn2 "skipped (-NoAutostart)"
    } else {
        $args = "--remote-debugging-port=9222 --remote-allow-origins=*"
        $fixed = 0
        foreach ($r in (Update-BilibiliShortcutArgs -ExePath $exe.FullName -Arguments $args)) {
            if ($r.Error) { Write-Warn2 "$(Split-Path $r.Path -Leaf): $($r.Error)" }
            elseif ($r.Changed) { $fixed++; Write-Ok "shortcut patched: $(Split-Path $r.Path -Leaf)" }
            else { Write-Ok "shortcut ok: $(Split-Path $r.Path -Leaf)" }
        }
        if ($fixed -eq 0) { Write-Ok "all client shortcuts already carry the debug port" }
        try {
            $cmd = Install-InjectorAutostart -PatcherRoot $PatcherRoot
            Write-Ok "logon autostart: $cmd"
        } catch {
            Write-Warn2 "autostart failed: $($_.Exception.Message)"
        }
    }

    Write-Step "Check injector helper scripts"
    $startPs1 = Join-Path $PatcherRoot "start-injector.ps1"
    if (-not (Test-Path $startPs1)) { throw "Missing $startPs1" }
    Write-Ok "start-injector.ps1 present (not regenerated)"

    $stopCmd = Join-Path $PatcherRoot "stop-injector.cmd"
    Write-Utf8NoBom -Path $stopCmd -Text @'
@echo off
powershell -NoProfile -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'injector.mjs' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; echo injector stopped"
pause
'@

    # Desktop launcher for injector
    $injLnk = Join-Path $desktop "BSB注入器.lnk"
    try {
        $sc2 = $wsh.CreateShortcut($injLnk)
        $sc2.TargetPath = "powershell.exe"
        $sc2.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$startPs1`""
        $sc2.WorkingDirectory = $PatcherRoot
        $sc2.Description = "Start BSB CDP injector"
        $sc2.Save()
        Write-Ok "Injector shortcut: $injLnk"
    } catch {
        Write-Warn2 "injector shortcut failed: $($_.Exception.Message)"
    }

    $stateObj = [ordered]@{
        mode                 = "cdp-runtime"
        installRoot          = $root
        exePath              = $exe.FullName
        launcherArgs         = $launcherArgs
        payloadVersion       = $manifest.version
        asarHash             = $asarHash
        asarPatched          = $false
        lastConfiguredAt     = (Get-Date).ToString("o")
        logFile              = $logFile
        note                 = "Client shortcuts carry the debug port; injector autostarts hidden at logon. Official asar is not modified."
    }
    Write-Utf8NoBom -Path $StatePath -Text ($stateObj | ConvertTo-Json)

    Write-Host ""
    Write-Ok "Runtime mode ready"
    Write-Host "  Client exe : $($exe.FullName)"
    Write-Host "  Launcher   : any client shortcut (debug port added in place)"
    Write-Host "  Injector   : hidden at logon; .\start-injector.ps1 -Background now"
    Write-Host "  Official asar is NOT patched - safe for client updates."
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Cyan
    Write-Host "  1. Open the client normally (any icon) - it now carries the debug port"
    Write-Host "  2. Injector runs hidden at logon; to start it now: .\start-injector.ps1 -Background"
    Write-Host "  3. Play a video  :  BV14741127BN"
    Write-Host ""
}
catch {
    Write-Host "  [X] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
}
