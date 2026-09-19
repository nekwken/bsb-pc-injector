#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Make BSB injection seamless: client shortcuts carry the debug port and the
  injector starts hidden at logon.

.DESCRIPTION
  After this, launch the client the way you always do (desktop icon, Start menu,
  taskbar pin) - no special shortcut, no console window, no manual step.
  Nothing inside the client is modified; only shortcuts and one HKCU Run entry.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\enable-seamless.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\enable-seamless.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [switch]$Uninstall,
    [switch]$NoStart,
    [switch]$NoTray     # autostart the injector directly, without the tray icon
)

$ErrorActionPreference = "Stop"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $PatcherRoot "tools\Common.ps1")
. (Join-Path $PatcherRoot "tools\Find-Client.ps1")
. (Join-Path $PatcherRoot "tools\Shortcuts.ps1")

$StateRoot = Get-StateRoot
$StatePath = Join-Path $StateRoot "state.json"
$DebugArgs = "--remote-debugging-port=9222 --remote-allow-origins=*"

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn2($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }

Write-Host ""
Write-Host "BSB Seamless Startup" -ForegroundColor Magenta
Write-Host ""

# --- resolve client exe ---------------------------------------------------
$exePath = $null
if (Test-Path $StatePath) {
    try { $exePath = (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).exePath } catch {}
}
if (-not $exePath -or -not (Test-Path $exePath)) {
    $root = if ($InstallRoot) { $InstallRoot } else { Find-BilibiliInstall -StatePath $StatePath }
    if ($root) {
        $f = Get-ChildItem $root -Filter "*.exe" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "bili|哔哩" -and $_.Name -notmatch "uninstall|卸载|elevate" } |
            Select-Object -First 1
        if ($f) { $exePath = $f.FullName }
    }
}
if (-not $exePath) { throw "Client exe not found. Run .\patch.ps1 first, or pass -InstallRoot." }
Write-Host "Client exe: $exePath"
Write-Host ""

if ($Uninstall) {
    Write-Step "Remove logon autostart"
    if (Remove-InjectorAutostart) { Write-Ok "Run entry 'BSBInjector' removed" }
    else { Write-Warn2 "no Run entry found" }

    Write-Step "Stop tray icon"
    $trays = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'BSB托盘.exe' -or ($_.Name -match '^(powershell|pwsh)\.exe$' -and $_.CommandLine -match "bsb-tray\.ps1") })
    foreach ($t in $trays) { try { Stop-Process -Id $t.ProcessId -Force -ErrorAction Stop } catch {} }
    if ($trays.Count) { Write-Ok "stopped $($trays.Count) tray process(es)" } else { Write-Ok "no tray running" }

    Write-Step "Stop injector"
    $shells = @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'bash.exe', 'sh.exe', 'wsl.exe', 'explorer.exe', 'windowsterminal.exe', 'conhost.exe')
    $stale = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "injector\.mjs" -and $shells -notcontains $_.Name }
    $stale | ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Write-Ok "stopped PID $($_.ProcessId)" } catch {} }

    Write-Host ""
    Write-Warn2 "Shortcuts were left as they are (they still pass the debug port)."
    Write-Host "  To strip the argument too, run: .\enable-seamless.ps1 -Uninstall -CleanShortcuts"
    Write-Host ""
    exit 0
}

# --- 1. shortcuts ---------------------------------------------------------
Write-Step "Add the debug port to every client shortcut"
$results = Update-BilibiliShortcutArgs -ExePath $exePath -Arguments $DebugArgs
if (-not $results) { Write-Warn2 "no client shortcut found (launch from the exe directly?)" }
$needsAdmin = @()
foreach ($r in $results) {
    $name = Split-Path $r.Path -Leaf
    $where = Split-Path (Split-Path $r.Path -Parent) -Leaf
    if ($r.Skipped) { $needsAdmin += "$name [$where]"; Write-Warn2 "$name [$where] : needs admin - skipped" }
    elseif ($r.Error) { Write-Warn2 "$name : $($r.Error)" }
    elseif ($r.Changed) { Write-Ok "$name [$where] -> $DebugArgs" }
    else { Write-Ok "$name [$where] already has the debug port" }
}
if ($needsAdmin.Count) {
    Write-Host "  Note: machine-wide shortcuts need one elevated run to patch:" -ForegroundColor Yellow
    Write-Host "        powershell -ExecutionPolicy Bypass -File .\enable-seamless.ps1" -ForegroundColor Yellow
}

# --- 2. autostart ---------------------------------------------------------
Write-Step "Register hidden startup at logon"
try {
    # 没有构建过托盘 exe（例如只克隆了源码）时自动退回「只起注入器」模式
    $trayExe = Join-Path $PatcherRoot "bin\BSB托盘.exe"
    $mode = if ($NoTray -or -not (Test-Path $trayExe)) { 'injector' } else { 'tray' }
    $cmd = Install-InjectorAutostart -PatcherRoot $PatcherRoot -Mode $mode
    Write-Ok "HKCU Run ($mode): $cmd"
    if ($mode -eq 'injector' -and -not $NoTray) {
        Write-Host "  (没找到 bin\BSB托盘.exe，先按无托盘模式注册；跑一次 build-apps.ps1 就有托盘图标)" -ForegroundColor DarkGray
    }
} catch {
    Write-Warn2 "autostart failed: $($_.Exception.Message)"
}

# --- 3. start it now ------------------------------------------------------
if (-not $NoStart) {
    if (-not $NoTray) {
        Write-Step "Start the tray icon now (it starts the injector itself)"
        $trayExe = Join-Path $PatcherRoot "bin\BSB托盘.exe"
        try {
            if (Test-Path $trayExe) {
                Start-Process -FilePath $trayExe -WindowStyle Hidden
            } else {
                Write-Warn2 "missing $trayExe - build the apps first"
            }
            Start-Sleep -Seconds 3
        } catch {
            Write-Warn2 "tray failed to start: $($_.Exception.Message)"
        }
    }
    Write-Step "Start the injector now (hidden)"
    $vbs = Join-Path $PatcherRoot "runtime\bsb-injector-hidden.vbs"
    try {
        Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbs`"" -WindowStyle Hidden
        Start-Sleep -Seconds 2
        $shells = @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'bash.exe', 'sh.exe', 'wsl.exe', 'explorer.exe', 'windowsterminal.exe', 'conhost.exe')
        $now = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -match "injector\.mjs" -and $shells -notcontains $_.Name })
        Write-Ok "injector processes: $($now.Count)"
    } catch {
        Write-Warn2 "could not start injector: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Launch the client the way you normally do - it now carries the debug port,"
Write-Host "  and the injector is already running in the background."
Write-Host "  Tray icon (空降助手): start/stop, installer, log."
Write-Host ""
Write-Host "  Status : .\status.ps1"
Write-Host "  Log    : $StateRoot\logs\injector.log"
Write-Host "  Undo   : .\enable-seamless.ps1 -Uninstall"
Write-Host ""
