#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Backend for the local installer UI (installer/server.mjs).

.DESCRIPTION
  Every action the UI can trigger lives here, so the Node server only ever
  invokes a fixed, whitelisted set. Output is JSON on stdout.

.EXAMPLE
  powershell -File .\tools\InstallerActions.ps1 -Action get-state
  powershell -File .\tools\InstallerActions.ps1 -Action shortcut-args -Port 9222 -AllowOrigins -Paths "C:\...\哔哩哔哩.lnk"
  powershell -File .\tools\InstallerActions.ps1 -Action shortcut-args -Remove -Paths "C:\...\哔哩哔哩.lnk"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('get-state', 'shortcut-args', 'autostart', 'injector-start', 'injector-stop', 'open-path', 'diagnostics',
        'patch', 'update-plugin', 'unpatch', 'pick-path', 'tray-start', 'tray-stop', 'config-save')]
    [string]$Action,

    [string]$Port = '9222',
    [switch]$AllowOrigins,
    [switch]$Remove,
    [string[]]$Paths,
    [string]$Which = 'project',
    [switch]$Enable,

    # elevated re-entry (see Invoke-Elevated)
    [switch]$Elevated,
    [string]$OutFile,
    [string]$Source = 'repo',
    [string]$Path
)

$ErrorActionPreference = 'Stop'

# the Node server reads our stdout as UTF-8; without this, PS 5.1 emits the
# console codepage and Chinese paths turn into mojibake
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$PatcherRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PatcherRoot "tools\Asar.ps1")
. (Join-Path $PatcherRoot "tools\Shortcuts.ps1")

$StateRoot = Get-StateRoot
$StatePath = Join-Path $StateRoot "state.json"
$Shells = @('powershell.exe', 'pwsh.exe', 'cmd.exe', 'bash.exe', 'sh.exe', 'wsl.exe', 'explorer.exe', 'windowsterminal.exe', 'conhost.exe')

function Get-InjectorProcs {
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match "injector\.mjs" -and $Shells -notcontains $_.Name })
}

function Get-TrayExe {
    $exe = Join-Path $PatcherRoot "bin\BSB托盘.exe"
    if (-not (Test-Path $exe)) { throw "missing $exe (build the tray app first)" }
    return $exe
}

function Get-TrayProcs {
    # the tray is a small native exe now
    @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'BSB托盘.exe' -or $_.CommandLine -match "bsb-tray\.ps1" })
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-QuotedPathArgs {
    <#
      .SYNOPSIS
        -Paths <p1> -Paths <p2> with each value quoted.
      .DESCRIPTION
        Start-Process -ArgumentList joins an array with spaces and does not quote
        elements, so an unquoted "C:\...\Start Menu\..." would split in two.
    #>
    [CmdletBinding()]
    param([string[]]$Paths)
    $out = @()
    foreach ($p in $Paths) { $out += @('-Paths', ('"' + $p + '"')) }
    return $out
}

function Invoke-Elevated {
    <#
      .SYNOPSIS
        Re-run this script elevated (UAC prompt) and return its parsed JSON.
      .DESCRIPTION
        The child writes its JSON to a temp file; the parent reads it back, so the
        caller sees the same shape whether or not elevation was needed.
    #>
    [CmdletBinding()]
    param([string[]]$ChildArgs)

    $tmp = Join-Path $env:TEMP ("bsb-elev-{0}.json" -f ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"") +
        $ChildArgs + @('-Elevated', '-OutFile', "`"$tmp`"")
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList $argList | Out-Null
    } catch {
        return [ordered]@{ ok = $false; error = 'elevation declined or failed: ' + $_.Exception.Message }
    }
    if (Test-Path $tmp) {
        try {
            $json = Get-Content $tmp -Raw -Encoding UTF8
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            return ($json | ConvertFrom-Json)
        } catch {
            return [ordered]@{ ok = $false; error = 'elevated run produced unreadable output' }
        }
    }
    return [ordered]@{ ok = $false; error = 'elevated run produced no result' }
}

function Invoke-Script {
    <#
      .SYNOPSIS
        Run one of the project scripts and capture its output.
    #>
    [CmdletBinding()]
    param(
        [string]$Script,
        [string[]]$ScriptArgs = @(),
        [switch]$ElevatedRun
    )
    $path = Join-Path $PatcherRoot $Script
    if (-not (Test-Path $path)) { throw "missing $path" }

    if ($ElevatedRun -and -not (Test-IsAdmin)) {
        $r = Invoke-Elevated -ChildArgs (@('-Action', 'run-script', '-Path', $Script) + $ScriptArgs)
        return $r
    }

    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1
    $code = $LASTEXITCODE
    $text = ($out | Out-String).Trim()
    return [ordered]@{ ok = ($code -eq 0); exitCode = $code; output = $text; elevated = (Test-IsAdmin) }
}

function Get-ConfigInfo {
    <#
      .SYNOPSIS
        生效中的插件配置 + 来源。
      .DESCRIPTION
        页面里跑的是 localStorage 里的配置，注入器每 10 秒把它镜像到
        live-config.json；有它就以它为准，否则用文件。
    #>
    $live = Join-Path $StateRoot "live-config.json"
    $file = Join-Path $StateRoot "bsb-config.json"
    foreach ($p in @($live, $file)) {
        if (Test-Path $p) {
            try {
                $cfg = Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json
                return [ordered]@{ config = $cfg; source = $(if ($p -eq $live) { 'live' } else { 'file' }); path = $p }
            } catch {}
        }
    }
    return [ordered]@{ config = $null; source = 'none'; path = $null }
}

function Get-ClientInfo {
    $info = [ordered]@{ installRoot = $null; exePath = $null; exeVersion = $null; asarPath = $null; asarHash = $null; officialHash = $null; asarOfficial = $null }
    $st = $null
    if (Test-Path $StatePath) {
        try { $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    }
    if ($st) {
        $info.installRoot = $st.installRoot
        $info.exePath = $st.exePath
    }
    if ($info.exePath -and (Test-Path $info.exePath)) {
        try { $info.exeVersion = (Get-Item $info.exePath).VersionInfo.FileVersion } catch {}
    }
    if ($info.installRoot) {
        $asar = Join-Path $info.installRoot "resources\app.asar"
        if (Test-Path $asar) {
            $info.asarPath = $asar
            $info.asarHash = Get-FileSha256 -Path $asar
            $bak = Join-Path $StateRoot "backups\app.asar.bak"
            if (Test-Path $bak) {
                $info.officialHash = Get-FileSha256 -Path $bak
                $info.asarOfficial = ($info.asarHash -eq $info.officialHash)
            }
        }
    }
    return $info
}

function Get-PayloadInfo {
    $project = Join-Path $PatcherRoot "payload"
    $runtime = Join-Path $StateRoot "payload"
    $pv = $null; $rv = $null
    try { $pv = (Get-Content (Join-Path $project "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
    try { $rv = (Get-Content (Join-Path $runtime "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
    return [ordered]@{ projectVersion = $pv; runtimeVersion = $rv; projectPath = $project; runtimePath = $runtime }
}

function Get-ShortcutPlace {
    <#
      .SYNOPSIS
        快捷方式所在位置的人话标签（桌面 / 开始菜单 / 任务栏固定 …）。
      .DESCRIPTION
        同一台机器上常有多个同名 .lnk（桌面、开始菜单、任务栏固定各一份），
        列表里必须能区分出用户是从哪儿点的。
    #>
    [CmdletBinding()]
    param([string]$Path)

    $pairs = @(
        @{ dir = [Environment]::GetFolderPath('Desktop'); label = '桌面' },
        @{ dir = (Join-Path ([Environment]::GetFolderPath('CommonStartMenu')) 'Programs'); label = '开始菜单（所有用户）' },
        @{ dir = (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'); label = '开始菜单' },
        @{ dir = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); label = '任务栏固定' }
    )
    foreach ($p in $pairs) {
        if ($p.dir -and $Path.StartsWith($p.dir, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $p.label
        }
    }
    # 认不出来就退回上一层目录名，至少能看出个大概
    $parent = Split-Path (Split-Path $Path -Parent) -Leaf
    if ($parent) { return $parent }
    return '其他位置'
}

function Get-ShortcutInfo {
    $client = Get-ClientInfo
    $wsh = New-Object -ComObject WScript.Shell
    $out = @()
    foreach ($l in (Get-BilibiliShortcutPaths -ExePath $client.exePath)) {
        $item = [ordered]@{ path = $l; place = (Get-ShortcutPlace -Path $l); target = $null; args = $null; hasPort = $false; needsAdmin = $false; scope = '' }
        try {
            $sc = $wsh.CreateShortcut($l)
            $item.target = $sc.TargetPath
            $item.args = $sc.Arguments
            $item.hasPort = ($sc.Arguments -match 'remote-debugging-port')
        } catch {}
        if ($l -like '*ProgramData*') {
            $item.scope = 'machine'
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            $p = New-Object Security.Principal.WindowsPrincipal($id)
            $item.needsAdmin = -not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } else {
            $item.scope = 'user'
        }
        $out += [pscustomobject]$item
    }
    return $out
}

function Build-Diagnostics {
    $sb = New-Object System.Text.StringBuilder
    $null = $sb.AppendLine("BSB diagnostics " + (Get-Date).ToString('s'))
    $null = $sb.AppendLine("state root : $StateRoot")
    $c = Get-ClientInfo
    $null = $sb.AppendLine("client     : $($c.installRoot)  exe=$($c.exePath)  v=$($c.exeVersion)")
    $null = $sb.AppendLine("asar       : official=$($c.asarOfficial) hash=$($c.asarHash)")
    $p = Get-PayloadInfo
    $null = $sb.AppendLine("payload    : project=$($p.projectVersion) runtime=$($p.runtimeVersion)")
    $procs = @(Get-InjectorProcs)
    $null = $sb.AppendLine("injectors  : $($procs.Count)")
    foreach ($pr in $procs) { $null = $sb.AppendLine("   pid $($pr.ProcessId) $($pr.Name)") }
    $null = $sb.AppendLine("autostart  : $(if (Get-InjectorAutostart) { Get-InjectorAutostart } else { '(none)' })")
    foreach ($s in (Get-ShortcutInfo)) {
        $null = $sb.AppendLine("shortcut   : $($s.path)  port=$($s.hasPort)  args=$($s.args)")
    }
    $log = Join-Path $StateRoot "logs\injector.log"
    if (Test-Path $log) {
        $null = $sb.AppendLine("--- injector.log (tail) ---")
        $null = $sb.AppendLine((Get-Content $log -Tail 40 -Encoding UTF8 | Out-String))
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------- dispatch

function Invoke-Action {
    param([string]$Action)

    switch ($Action) {
        'get-state' {
            return [ordered]@{
                ok        = $true
                now       = (Get-Date).ToString('s')
                stateRoot = $StateRoot
                admin     = (Test-IsAdmin)
                client    = Get-ClientInfo
                payload   = Get-PayloadInfo
                injector  = [ordered]@{
                    count = @(Get-InjectorProcs).Count
                    procs = @(Get-InjectorProcs | ForEach-Object {
                            [ordered]@{ pid = $_.ProcessId; name = $_.Name; started = (Get-Date $_.CreationDate -Format 'HH:mm:ss') }
                        })
                    logFile = (Join-Path $StateRoot "logs\injector.log")
                }
                tray      = [ordered]@{ count = @(Get-TrayProcs).Count }
                configInfo = Get-ConfigInfo
                autostart = [ordered]@{ enabled = [bool](Get-InjectorAutostart); command = (Get-InjectorAutostart) }
                shortcuts = @(Get-ShortcutInfo)
            }
        }

        'shortcut-args' {
            $wsh = New-Object -ComObject WScript.Shell
            $client = Get-ClientInfo
            $all = Get-BilibiliShortcutPaths -ExePath $client.exePath
            $targets = if ($Paths -and $Paths.Count) { $Paths } else { $all }
            $newArgs = "--remote-debugging-port=$Port --remote-allow-origins=*"

            # machine-wide shortcuts (C:\ProgramData) can only be written elevated
            $machine = @($targets | Where-Object { $_ -like '*ProgramData*' })
            $mine = @($targets | Where-Object { $_ -notlike '*ProgramData*' })

            $done = @()
            foreach ($l in $mine) {
                if ($all -notcontains $l) { $done += [pscustomobject]@{ path = $l; ok = $false; error = 'not a client shortcut' }; continue }
                try {
                    $sc = $wsh.CreateShortcut($l)
                    $a = ($sc.Arguments -replace '\s*--remote-debugging-port=\d+', '' -replace '\s*--remote-allow-origins=\*', '').Trim()
                    if (-not $Remove) { $a = ($a + ' ' + $newArgs).Trim() }
                    $sc.Arguments = $a
                    $sc.Save()
                    $done += [pscustomobject]@{ path = $l; ok = $true; args = $a }
                } catch {
                    $done += [pscustomobject]@{ path = $l; ok = $false; error = $_.Exception.Message }
                }
            }

            $elevation = 'not-needed'
            if ($machine.Count -and -not $Elevated) {
                if (Test-IsAdmin) {
                    $childArgs = @('-Action', 'shortcut-args', '-Port', "$Port") + (Get-QuotedPathArgs -Paths $machine)
                    if (-not $Remove) { $childArgs += '-AllowOrigins' }
                    if ($Remove) { $childArgs += '-Remove' }
                    $r = Invoke-Elevated -ChildArgs $childArgs
                    $elevation = 'already-admin'
                } else {
                    $childArgs = @('-Action', 'shortcut-args', '-Port', "$Port") + (Get-QuotedPathArgs -Paths $machine)
                    if (-not $Remove) { $childArgs += '-AllowOrigins' }
                    if ($Remove) { $childArgs += '-Remove' }
                    $r = Invoke-Elevated -ChildArgs $childArgs
                    $elevation = 'requested'
                }
                if ($r -and $r.results) { $done += @($r.results) }
                elseif ($r -and -not $r.ok) { $done += [pscustomobject]@{ path = ($machine -join ', '); ok = $false; error = $r.error } }
            } elseif ($machine.Count -and $Elevated) {
                foreach ($l in $machine) {
                    try {
                        $sc = $wsh.CreateShortcut($l)
                        $a = ($sc.Arguments -replace '\s*--remote-debugging-port=\d+', '' -replace '\s*--remote-allow-origins=\*', '').Trim()
                        if (-not $Remove) { $a = ($a + ' ' + $newArgs).Trim() }
                        $sc.Arguments = $a
                        $sc.Save()
                        $done += [pscustomobject]@{ path = $l; ok = $true; args = $a }
                    } catch {
                        $done += [pscustomobject]@{ path = $l; ok = $false; error = $_.Exception.Message }
                    }
                }
            }

            return [ordered]@{
                ok        = $true
                action    = $(if ($Remove) { 'remove' } else { 'add' })
                elevation = $elevation
                results   = @($done)
            }
        }

        'autostart' {
            if ($Enable) {
                $cmd = Install-InjectorAutostart -PatcherRoot $PatcherRoot
                return [ordered]@{ ok = $true; enabled = $true; command = $cmd }
            }
            $removed = Remove-InjectorAutostart
            return [ordered]@{ ok = $true; enabled = $false; removed = $removed }
        }

        'injector-start' {
            $vbs = Join-Path $PatcherRoot "runtime\bsb-injector-hidden.vbs"
            if (-not (Test-Path $vbs)) { throw "missing $vbs" }
            Start-Process -FilePath 'wscript.exe' -ArgumentList "`"$vbs`"" -WindowStyle Hidden
            Start-Sleep -Seconds 2
            return [ordered]@{ ok = $true; count = @(Get-InjectorProcs).Count }
        }

        'injector-stop' {
            $procs = @(Get-InjectorProcs)
            foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }
            Start-Sleep -Milliseconds 400
            return [ordered]@{ ok = $true; stopped = $procs.Count; count = @(Get-InjectorProcs).Count }
        }

        'tray-start' {
            $exe = Get-TrayExe
            Start-Process -FilePath $exe -WindowStyle Hidden
            Start-Sleep -Seconds 2
            return [ordered]@{ ok = $true; count = @(Get-TrayProcs).Count; exe = $exe }
        }

        'tray-stop' {
            $procs = @(Get-TrayProcs)
            foreach ($p in $procs) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {} }
            Start-Sleep -Milliseconds 300
            return [ordered]@{ ok = $true; stopped = $procs.Count; count = @(Get-TrayProcs).Count }
        }

        'patch' {
            $r = Invoke-Script -Script "patch.ps1"
            if (-not $r.ok -and -not (Test-IsAdmin) -and ($r.output -match 'admin|Access is denied|拒绝访问|Cannot write')) {
                $r2 = Invoke-Elevated -ChildArgs @('-Action', 'run-script', '-Path', 'patch.ps1')
                if ($r2 -is [hashtable] -or $r2 -is [System.Management.Automation.PSCustomObject]) {
                    $r2 | Add-Member -NotePropertyName elevation -NotePropertyValue 'requested' -Force
                }
                return $r2
            }
            return $r
        }

        'update-plugin' {
            $scriptArgs = @()
            switch ($Source) {
                'repo' { $scriptArgs = @('-PayloadDir', (Join-Path $PatcherRoot 'payload'), '-Force') }
                'folder' {
                    if (-not $Path -or -not (Test-Path $Path)) { throw "folder not found: $Path" }
                    $scriptArgs = @('-PayloadDir', $Path, '-Force')
                }
                'zip' {
                    if (-not $Path -or -not (Test-Path $Path)) { throw "zip not found: $Path" }
                    $scriptArgs = @('-ZipPath', $Path, '-Force')
                }
                default { throw "unknown source: $Source" }
            }
            return Invoke-Script -Script "update-plugin.ps1" -ScriptArgs $scriptArgs
        }

        'unpatch' {
            return Invoke-Script -Script "unpatch.ps1" -ElevatedRun
        }

        'run-script' {
            # only ever reached from an elevated re-entry; keep the surface tiny
            $allowed = @('patch.ps1', 'unpatch.ps1')
            if ($allowed -notcontains $Path) { throw "script not allowed: $Path" }
            return Invoke-Script -Script $Path
        }

        'config-save' {
            if (-not $Path -or -not (Test-Path $Path)) { throw "config file not found: $Path" }
            $cfg = Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $target = Join-Path $StateRoot "bsb-config.json"
            [System.IO.File]::WriteAllText($target, ($cfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding $false))

            # the app has no CDP client; the injector owns the page connections and
            # picks this command up on its next poll
            $cmdFile = Join-Path $StateRoot "command.json"
            $payload = [ordered]@{
                id     = [guid]::NewGuid().ToString('N')
                cmd    = 'push-config'
                config = $cfg
                at     = (Get-Date).ToString('o')
            }
            [System.IO.File]::WriteAllText($cmdFile, ($payload | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding $false))

            $running = @(Get-InjectorProcs).Count -gt 0
            return [ordered]@{ ok = $true; configPath = $target; queued = $running; injectorRunning = $running }
        }

        'pick-path' {
            Add-Type -AssemblyName System.Windows.Forms | Out-Null
            $owner = New-Object System.Windows.Forms.Form
            $owner.TopMost = $true
            $owner.ShowInTaskbar = $false
            $owner.WindowState = 'Minimized'
            $owner.Opacity = 0
            $owner.Show()
            try {
                if ($Which -eq 'zip') {
                    $dlg = New-Object System.Windows.Forms.OpenFileDialog
                    $dlg.Title = '选择插件包 (zip)'
                    $dlg.Filter = 'Payload zip (*.zip)|*.zip|所有文件|*.*'
                    $dlg.CheckFileExists = $true
                    $res = $dlg.ShowDialog($owner)
                    if ($res -ne [System.Windows.Forms.DialogResult]::OK) {
                        return [ordered]@{ ok = $true; cancelled = $true; path = $null }
                    }
                    return [ordered]@{ ok = $true; cancelled = $false; path = $dlg.FileName }
                }
                $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                $dlg.Description = '选择插件包目录（应包含 manifest.json）'
                $dlg.ShowNewFolderButton = $false
                $res = $dlg.ShowDialog($owner)
                if ($res -ne [System.Windows.Forms.DialogResult]::OK) {
                    return [ordered]@{ ok = $true; cancelled = $true; path = $null }
                }
                return [ordered]@{ ok = $true; cancelled = $false; path = $dlg.SelectedPath }
            } finally {
                $owner.Close()
                $owner.Dispose()
            }
        }

        'open-path' {
            $map = @{
                project = $PatcherRoot
                logs    = (Join-Path $StateRoot "logs")
                payload = (Join-Path $PatcherRoot "payload")
                state   = $StateRoot
            }
            $p = $map[$Which]
            if (-not $p) { throw "unknown path: $Which" }
            if (-not (Test-Path $p)) { throw "not found: $p" }
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$p`""
            return [ordered]@{ ok = $true; path = $p }
        }

        'diagnostics' {
            return [ordered]@{ ok = $true; text = (Build-Diagnostics) }
        }

        default { throw "unhandled action: $Action" }
    }
}

$result = Invoke-Action -Action $Action
$json = $result | ConvertTo-Json -Depth 8 -Compress
if ($OutFile) {
    [System.IO.File]::WriteAllText($OutFile, $json, (New-Object System.Text.UTF8Encoding $false))
} else {
    $json
}
