#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
  Shortcut + autostart helpers for the BSB runtime injector.

  The injector needs the client to run with --remote-debugging-port, so every
  entry point the user actually clicks has to carry the flag. We rewrite the
  existing shortcuts instead of asking the user to remember a special icon.
#>

function Get-BilibiliShortcutPaths {
    <#
      .SYNOPSIS
        Every .lnk that may launch the official client.
    #>
    [CmdletBinding()]
    param([string]$ExePath)

    $dirs = @()
    try { $dirs += [Environment]::GetFolderPath("Desktop") } catch {}
    try { $dirs += (Join-Path ([Environment]::GetFolderPath("StartMenu")) "Programs") } catch {}
    try { $dirs += (Join-Path ([Environment]::GetFolderPath("CommonStartMenu")) "Programs") } catch {}
    try { $dirs += (Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar") } catch {}

    $wsh = New-Object -ComObject WScript.Shell
    $out = @()
    foreach ($d in ($dirs | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)) {
        foreach ($f in (Get-ChildItem $d -Filter *.lnk -Recurse -ErrorAction SilentlyContinue)) {
            try {
                $sc = $wsh.CreateShortcut($f.FullName)
                if (-not $sc.TargetPath) { continue }
                $leaf = Split-Path $sc.TargetPath -Leaf
                # never touch uninstallers / updaters / other apps in the same folder
                if ($leaf -match "uninstall|卸载|elevate|update|必剪|bcut") { continue }
                $isClient = $false
                if ($ExePath) {
                    $isClient = ($sc.TargetPath -ieq $ExePath)
                } else {
                    $isClient = ($leaf -match "^(哔哩哔哩|bilibili)\.exe$")
                }
                if ($isClient) { $out += $f.FullName }
            } catch {}
        }
    }
    return $out | Select-Object -Unique
}

function Update-BilibiliShortcutArgs {
    <#
      .SYNOPSIS
        Add the debug-port arguments to every client shortcut that lacks them.
      .OUTPUTS
        Objects with Path / Changed / Arguments
    #>
    [CmdletBinding()]
    param(
        [string]$ExePath,
        [string]$Arguments = "--remote-debugging-port=9222 --remote-allow-origins=*"
    )

    $wsh = New-Object -ComObject WScript.Shell
    $results = @()
    foreach ($lnk in (Get-BilibiliShortcutPaths -ExePath $ExePath)) {
        $item = [ordered]@{ Path = $lnk; Changed = $false; Arguments = ""; Error = $null; Skipped = $false }
        try {
            $sc = $wsh.CreateShortcut($lnk)
            $item.Arguments = $sc.Arguments
            if ($sc.Arguments -notmatch "remote-debugging-port") {
                $sc.Arguments = ($sc.Arguments + " " + $Arguments).Trim()
                $sc.Save()
                $item.Changed = $true
                $item.Arguments = $sc.Arguments
            }
        } catch {
            $msg = $_.Exception.Message
            if ($lnk -like "*ProgramData*" -or $msg -match "无法保存|Access is denied|拒绝访问") {
                $item.Skipped = $true
            } else {
                $item.Error = $msg
            }
        }
        $results += [pscustomobject]$item
    }
    return $results
}

# --- logon autostart ------------------------------------------------------

$script:AutostartKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$script:AutostartName = "BSBInjector"

function Get-InjectorAutostart {
    <#
      .SYNOPSIS
        Current Run entry for the injector, or $null.
    #>
    [CmdletBinding()]
    param()
    try {
        $v = (Get-ItemProperty -Path $script:AutostartKey -Name $script:AutostartName -ErrorAction Stop).$script:AutostartName
        if ($v) { return $v }
    } catch {}
    return $null
}

function Install-InjectorAutostart {
    <#
      .SYNOPSIS
        Register a hidden, flash-free launcher at logon.
      .DESCRIPTION
        Defaults to the native tray app (bin\BSB托盘.exe), which starts the
        injector itself and gives the user a way back in. Use -Mode injector for
        the plain injector-only entry (wscript + .vbs, no tray icon).
        HKCU\Run, so no admin rights are needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PatcherRoot,
        [ValidateSet('tray', 'injector')][string]$Mode = 'tray'
    )

    if ($Mode -eq 'tray') {
        $exe = Join-Path $PatcherRoot "bin\BSB托盘.exe"
        if (-not (Test-Path $exe)) { throw "Missing $exe (build the apps first)" }
        $cmd = '"' + $exe + '"'
    } else {
        $vbs = Join-Path $PatcherRoot "runtime\bsb-injector-hidden.vbs"
        if (-not (Test-Path $vbs)) { throw "Missing $vbs" }
        $cmd = 'wscript.exe "' + $vbs + '"'
    }
    New-Item -Path $script:AutostartKey -Force | Out-Null
    New-ItemProperty -Path $script:AutostartKey -Name $script:AutostartName -Value $cmd -PropertyType String -Force | Out-Null
    return $cmd
}

function Remove-InjectorAutostart {
    [CmdletBinding()]
    param()
    try {
        Remove-ItemProperty -Path $script:AutostartKey -Name $script:AutostartName -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}
