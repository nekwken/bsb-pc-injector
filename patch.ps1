#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Install BSB runtime mode: sync payload, point launch shortcuts at the debug port,
  register the hidden injector. The official client is never modified.

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
    [switch]$WithLaunchers  # also (re)create the 哔哩哔哩-BSB launcher shortcuts
)

$ErrorActionPreference = "Stop"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

. (Join-Path $PatcherRoot "tools\Common.ps1")
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
$LogDir = Join-Path $StateRoot "logs"
$PayloadRuntime = Join-Path $StateRoot "payload"
$StatePath = Join-Path $StateRoot "state.json"
$RuntimeDir = Join-Path $PatcherRoot "runtime"
New-Item -ItemType Directory -Force -Path $StateRoot, $LogDir, $PayloadRuntime | Out-Null
$logFile = Join-Path $LogDir ("runtime-install-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
Start-Transcript -Path $logFile -Append | Out-Null

try {
    Write-Host ""
    Write-Host "BSB Client Runtime Injector" -ForegroundColor Magenta
    Write-Host "Mode: CDP runtime injection (官方客户端文件不做任何修改)"
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
    # 官方客户端从不被修改，所以这里只确认它在位；asar 相关内容已全部移除
    $asarPath = Join-Path $root "resources\app.asar"
    if (-not (Test-Path $asarPath)) { throw "app.asar not found: $asarPath" }
    Write-Ok "官方 asar 在位（本方案不修改它）"

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
