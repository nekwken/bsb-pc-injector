#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Start the BSB CDP injector.

.DESCRIPTION
  Foreground by default (console output). With -Background it logs to
  %LOCALAPPDATA%\bsb-client-patcher\logs\injector.log instead, which is how the
  logon autostart runs it (see runtime\bsb-injector-hidden.vbs).

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\start-injector.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\start-injector.ps1 -Background
#>
[CmdletBinding()]
param(
    [switch]$Background
)

$ErrorActionPreference = "Stop"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $PatcherRoot "tools\Common.ps1")
$node = Find-Node
if (-not $node) { throw "Node.js not found" }

# kill ALL existing injectors (avoid dual old+new).
# Match on the command line only: injectors may run as node.exe or as the
# node runtime bundled with another host (e.g. "Xiaomi MiMo.exe").
# Launcher shells are skipped - their command line mentions the script too.
$self = $PID
$shells = @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'bash.exe', 'sh.exe', 'wsl.exe', 'explorer.exe', 'windowsterminal.exe', 'conhost.exe')
$stale = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $self -and $_.CommandLine -match "injector\.mjs" -and $shells -notcontains $_.Name }
if ($stale) {
    Write-Host "Stopping $($stale.Count) running injector(s)..." -ForegroundColor DarkGray
    $stale | ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop
            Write-Host "  stopped PID $($_.ProcessId) [$($_.Name)]" -ForegroundColor DarkGray
        } catch {
            Write-Warning "  could not stop PID $($_.ProcessId): $($_.Exception.Message)"
        }
    }
    Start-Sleep -Milliseconds 600
}

# prefer the project payload, fall back to the state-dir copy
$payload = Join-Path $PatcherRoot "payload"
if (-not (Test-Path (Join-Path $payload "bsb-content.js"))) {
    $payload = Join-Path (Get-StateRoot) "payload"
}

$env:BSB_PAYLOAD_DIR = $payload
$env:BSB_DEBUG = if ($env:BSB_DEBUG) { $env:BSB_DEBUG } else { "0" }
$script = Join-Path $PatcherRoot "runtime\injector.mjs"

if ($Background) {
    # launched hidden at logon: keep a rolling log instead of a console
    $logDir = Join-Path (Get-StateRoot) "logs"
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $env:BSB_LOG_FILE = Join-Path $logDir "injector.log"
} else {
    Write-Host "BSB injector starting..."
    Write-Host "  node:    $node"
    Write-Host "  payload: $payload"
    Write-Host "  script:  $script"
    Write-Host "  cdp:     127.0.0.1:9222"
    Write-Host ""
    Write-Host "Open the client normally - every client shortcut carries the debug port." -ForegroundColor Yellow
}

& $node $script
