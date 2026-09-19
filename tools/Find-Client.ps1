# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
# Find-Client.ps1 - locate official Bilibili PC client
#
# 查找顺序（可信度从高到低）：
#   1. state.json 里记录的位置（上次用过且仍有效）
#   2. 正在运行的客户端进程路径（最可靠：用户装在哪、进程就在哪）
#   3. 注册表卸载信息
#   4. 常见安装路径
#   5. 所有固定磁盘的受限扫描（深度 2，目录名含 bili/哔哩）

function Test-ClientRoot {
    param([string]$Path)
    if (-not $Path) { return $false }
    return (Test-Path (Join-Path $Path "resources\app.asar"))
}

function Find-ClientFromProcess {
    foreach ($n in @("哔哩哔哩", "bilibili")) {
        foreach ($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try {
                $exe = $p.MainModule.FileName
            } catch { continue }
            if (-not $exe -or $exe -notmatch "(哔哩哔哩|bilibili)\.exe$") { continue }
            $dir = Split-Path $exe -Parent
            for ($i = 0; $i -lt 3 -and $dir; $i++) {
                if (Test-ClientRoot $dir) { return $dir }
                $dir = Split-Path $dir -Parent
            }
        }
    }
    return $null
}

function Get-FixedDriveRoots {
    $roots = @()
    try {
        $disks = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        foreach ($d in $disks) { $roots += $d.DeviceID + "\" }
    } catch {
        $roots = @("C:\")
    }
    return $roots
}

function Find-BilibiliInstalls {
    <#
      返回所有候选根目录（去重，按发现顺序）。
      注意：候选收集必须用 List 引用 + 独立函数 —— 若用闭包脚本块，$found += 会改在
      脚本块自己的作用域里，外层数组永远是空的（PowerShell 经典坑）。
    #>
    $found = [System.Collections.Generic.List[string]]::new()
    $seen = @{}

    function Add-Candidate {
        param([System.Collections.Generic.List[string]]$List, [hashtable]$Seen, [string]$Path)
        if (-not $Path) { return }
        $key = $Path.TrimEnd('\').ToLowerInvariant()
        if ($Seen.ContainsKey($key)) { return }
        if (-not (Test-ClientRoot $Path)) { return }
        $Seen[$key] = $true
        $List.Add($Path.TrimEnd('\'))
    }

    # 运行中的客户端进程（最可靠的信号之一）
    foreach ($n in @("哔哩哔哩", "bilibili")) {
        foreach ($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            try {
                $exe = $p.MainModule.FileName
            } catch { continue }
            if (-not $exe -or $exe -notmatch "(哔哩哔哩|bilibili)\.exe$") { continue }
            $dir = Split-Path $exe -Parent
            for ($i = 0; $i -lt 3 -and $dir; $i++) {
                Add-Candidate -List $found -Seen $seen -Path $dir
                $dir = Split-Path $dir -Parent
            }
        }
    }

    # 注册表卸载信息
    foreach ($root in @(
            "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        )) {
        if (-not (Test-Path $root)) { continue }
        foreach ($item in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            try {
                $p = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
                if ([string]$p.DisplayName -match "bilibili|哔哩") {
                    Add-Candidate -List $found -Seen $seen -Path $p.InstallLocation
                }
            } catch {}
        }
    }

    # 常见安装路径
    $common = @(
        "$env:LOCALAPPDATA\Programs\bilibili",
        "$env:LOCALAPPDATA\Programs\Bilibili",
        "$env:LOCALAPPDATA\bilibili",
        "${env:ProgramFiles}\bilibili",
        "${env:ProgramFiles}\Bilibili",
        "${env:ProgramFiles(x86)}\bilibili"
    )
    foreach ($c in $common) {
        if ($c -and (Test-Path $c)) {
            Add-Candidate -List $found -Seen $seen -Path $c
            foreach ($s in (Get-ChildItem $c -Directory -ErrorAction SilentlyContinue)) {
                Add-Candidate -List $found -Seen $seen -Path $s.FullName
            }
        }
    }

    # 固定磁盘受限扫描：盘根与常见父目录下名字含 bili/哔哩 的文件夹（深度 2）
    foreach ($drive in (Get-FixedDriveRoots)) {
        $bases = @($drive, (Join-Path $drive "Program Files"), (Join-Path $drive "Program Files (x86)"), (Join-Path $drive "Programs"))
        foreach ($base in $bases) {
            if (-not (Test-Path $base)) { continue }
            foreach ($d in (Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)) {
                if ($d.Name -notmatch "bili|哔哩") { continue }
                Add-Candidate -List $found -Seen $seen -Path $d.FullName
                foreach ($n in (Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                    Add-Candidate -List $found -Seen $seen -Path $n.FullName
                }
            }
        }
    }
    return $found
}

function Find-BilibiliInstall {
    param([string]$StatePath)

    # 1) state.json
    if ($StatePath -and (Test-Path $StatePath)) {
        try {
            $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.installRoot -and (Test-ClientRoot $st.installRoot)) {
                return $st.installRoot
            }
        } catch {}
    }

    # 2) 运行中的客户端进程
    $fromProc = Find-ClientFromProcess
    if ($fromProc) { return $fromProc }

    # 3-5) 注册表 / 常见路径 / 磁盘扫描
    $all = Find-BilibiliInstalls
    if ($all.Count -gt 0) { return $all[0] }
    return $null
}
