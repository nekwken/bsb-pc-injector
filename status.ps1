#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Show BSB patcher status
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $PatcherRoot "tools\Asar.ps1")
. (Join-Path $PatcherRoot "tools\Find-Client.ps1")

$StateRoot = Get-StateRoot
$StatePath = Join-Path $StateRoot "state.json"
$PayloadRuntime = Join-Path $StateRoot "payload"
$BackupDir = Join-Path $StateRoot "backups"

Write-Host ""
Write-Host "BSB Client Patcher - Status" -ForegroundColor Magenta
Write-Host "State root: $StateRoot"
Write-Host ""

$pv = "(none)"
$pmf = Join-Path $PayloadRuntime "manifest.json"
if (Test-Path $pmf) {
    try { $pv = (Get-Content $pmf -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { $pv = "(invalid)" }
} elseif (Test-Path (Join-Path $PatcherRoot "payload\manifest.json")) {
    try {
        $pv = (Get-Content (Join-Path $PatcherRoot "payload\manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json).version
        $pv = "$pv (repo payload, not installed to state dir)"
    } catch {}
}
Write-Host "Payload runtime version : $pv"

# --- injector diagnostics (CDP runtime mode) -------------------------------
function Test-LocalPort([int]$Port) {
    try {
        $c = New-Object System.Net.Sockets.TcpClient
        $c.Connect("127.0.0.1", $Port)
        $c.Close()
        return $true
    } catch { return $false }
}

Write-Host ""
Write-Host "Injector (CDP runtime):" -ForegroundColor Cyan
$shells = @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'bash.exe', 'sh.exe', 'wsl.exe', 'explorer.exe', 'windowsterminal.exe', 'conhost.exe')
$inj = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match "injector\.mjs" -and $shells -notcontains $_.Name })
if ($inj.Count -eq 0) {
    Write-Host "  running                 : no  (start .\start-injector.ps1)" -ForegroundColor Yellow
} else {
    Write-Host "  running                 : $($inj.Count) process(es)"
    foreach ($p in $inj) {
        $s = ($p.CommandLine -split '\s+' | Where-Object { $_ -match "injector\.mjs" } | Select-Object -First 1)
        Write-Host "      PID $($p.ProcessId)  [$($p.Name)]  $s"
    }
    if ($inj.Count -gt 1) {
        Write-Host "  WARNING                 : multiple injectors = duplicate UI, flickering button!" -ForegroundColor Red
        Write-Host "                            Run .\start-injector.ps1 - it stops the others first." -ForegroundColor Red
    }
}
$portOpen = Test-LocalPort 9222
Write-Host "  CDP 127.0.0.1:9222      : $(if ($portOpen) { 'open' } else { 'closed - launch client via a patched shortcut' })" -ForegroundColor $(if ($portOpen) { "Green" } else { "Yellow" })

# --- seamless startup -----------------------------------------------------
Write-Host ""
Write-Host "Seamless startup:" -ForegroundColor Cyan
. (Join-Path $PatcherRoot "tools\Shortcuts.ps1") -ErrorAction SilentlyContinue
$runCmd = Get-InjectorAutostart
if ($runCmd) {
    Write-Host "  logon autostart         : $runCmd" -ForegroundColor Green
} else {
    Write-Host "  logon autostart         : not set  (run .\enable-seamless.ps1)" -ForegroundColor Yellow
}
$exeForShortcuts = $null
if (Test-Path $StatePath) {
    try { $exeForShortcuts = (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).exePath } catch {}
}
$lnks = @(Get-BilibiliShortcutPaths -ExePath $exeForShortcuts)
if ($lnks.Count -eq 0) {
    Write-Host "  client shortcuts        : none found" -ForegroundColor Yellow
} else {
    $withPort = 0
    foreach ($l in $lnks) {
        $has = $false
        try {
            $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($l)
            $has = ($sc.Arguments -match "remote-debugging-port")
        } catch {}
        if ($has) { $withPort++ }
        Write-Host "  $($l)"
        Write-Host "      debug port          : $(if ($has) { 'yes' } else { 'NO - run .\enable-seamless.ps1' })" -ForegroundColor $(if ($has) { "Green" } else { "Yellow" })
    }
    if ($withPort -eq $lnks.Count) { Write-Host "  all client shortcuts carry the debug port" -ForegroundColor Green }
}
$injLog = Join-Path $StateRoot "logs\injector.log"
if (Test-Path $injLog) {
    Write-Host "  injector log            : $injLog"
}

$root = $null
if (Test-Path $StatePath) {
    $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host "Install root            : $($st.installRoot)"
    Write-Host "Client version          : $($st.clientVersion)"
    Write-Host "Last patched payload    : $($st.payloadVersion)"
    Write-Host "Last patched at         : $($st.lastPatchedAt)"
    Write-Host "Last patched asar hash  : $($st.lastPatchedAsarHash)"
    Write-Host "Last official asar hash : $($st.lastOfficialAsarHash)"
    Write-Host "Backup                  : $($st.backupPath)"
    $root = $st.installRoot
} else {
    Write-Host "state.json              : (missing - never patched?)"
}

if (-not $root) {
    $root = Find-BilibiliInstall -StatePath $StatePath
}

Write-Host ""
if ($root -and (Test-Path (Join-Path $root "resources\app.asar"))) {
    $asar = Join-Path $root "resources\app.asar"
    $hash = Get-FileSha256 -Path $asar
    Write-Host "Found client            : $root"
    Write-Host "Current asar SHA256     : $hash"
    $yml = Join-Path $root "resources\app-update.yml"
    if (Test-Path $yml) {
        Write-Host "app-update.yml          :"
        Get-Content $yml | ForEach-Object { Write-Host "    $_" }
    }

    $stHash = $null
    if (Test-Path $StatePath) {
        try { $stHash = (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).lastPatchedAsarHash } catch {}
    }
    if ($stHash -and $hash -eq $stHash) {
        Write-Host "Patch status            : ACTIVE (hash match)" -ForegroundColor Green
    } elseif ($stHash -and $hash -ne $stHash) {
        Write-Host "Patch status            : STALE / OFFICIAL UPDATE" -ForegroundColor Yellow
        Write-Host "  -> Run .\patch.ps1 to re-apply"
    } else {
        Write-Host "Patch status            : UNKNOWN" -ForegroundColor Yellow
    }
} else {
    Write-Host "Found client            : (not found)" -ForegroundColor Yellow
}

$bak = Join-Path $BackupDir "app.asar.bak"
Write-Host ""
Write-Host "Backup exists           : $(Test-Path $bak)"
if (Test-Path $bak) {
    Write-Host "Backup SHA256           : $(Get-FileSha256 -Path $bak)"
}
Write-Host ""
Write-Host "Commands:"
Write-Host "  .\patch.ps1                 # one-click adapt / re-apply after update"
Write-Host "  .\update-plugin.ps1         # one-click plugin update"
Write-Host "  .\unpatch.ps1               # restore official files"
Write-Host ""
