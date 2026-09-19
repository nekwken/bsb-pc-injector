# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
# Find-Client.ps1 - locate official Bilibili PC client

function Get-CommonBilibiliPaths {
    $paths = @()
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\bilibili",
        "$env:LOCALAPPDATA\Programs\Bilibili",
        "$env:LOCALAPPDATA\bilibili",
        "${env:ProgramFiles}\bilibili",
        "${env:ProgramFiles}\Bilibili",
        "${env:ProgramFiles(x86)}\bilibili"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { $paths += $c }
    }
    return $paths
}

function Test-ClientRoot {
    param([string]$Path)
    if (-not $Path) { return $false }
    return (Test-Path (Join-Path $Path "resources\app.asar"))
}

function Find-BilibiliInstall {
    param([string]$StatePath)

    if ($StatePath -and (Test-Path $StatePath)) {
        try {
            $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($st.installRoot -and (Test-ClientRoot $st.installRoot)) {
                return $st.installRoot
            }
        } catch {}
    }

    $regRoots = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $regRoots) {
        if (-not (Test-Path $root)) { continue }
        $items = Get-ChildItem $root -ErrorAction SilentlyContinue
        foreach ($item in $items) {
            try {
                $p = Get-ItemProperty $item.PSPath -ErrorAction SilentlyContinue
                $name = [string]$p.DisplayName
                if ($name -match "bilibili") {
                    $loc = $p.InstallLocation
                    if ($loc -and (Test-ClientRoot $loc)) { return $loc }
                }
            } catch {}
        }
    }

    foreach ($base in (Get-CommonBilibiliPaths)) {
        if (Test-ClientRoot $base) { return $base }
        $subs = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue
        foreach ($s in $subs) {
            if (Test-ClientRoot $s.FullName) { return $s.FullName }
        }
    }

    $scanRoots = @($env:LOCALAPPDATA, $env:ProgramFiles) | Where-Object { $_ }
    foreach ($r in $scanRoots) {
        $dirs = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "bili" }
        foreach ($d in $dirs) {
            if (Test-ClientRoot $d.FullName) { return $d.FullName }
            $nested = Get-ChildItem $d.FullName -Directory -ErrorAction SilentlyContinue
            foreach ($n in $nested) {
                if (Test-ClientRoot $n.FullName) { return $n.FullName }
            }
        }
    }

    return $null
}

function Get-ClientVersionFromAsarExtract {
    param([string]$ExtractedRoot)
    $pkg = Join-Path $ExtractedRoot "package.json"
    if (Test-Path $pkg) {
        try {
            $j = Get-Content $pkg -Raw -Encoding UTF8 | ConvertFrom-Json
            return $j.version
        } catch {}
    }
    return $null
}

function Test-AsarPatched {
    param([string]$ExtractedRoot)
    $bsb = Join-Path $ExtractedRoot "bsb\manifest.json"
    $boot = Join-Path $ExtractedRoot "index.js"
    if (-not (Test-Path $bsb)) { return $false }
    return $true
}
