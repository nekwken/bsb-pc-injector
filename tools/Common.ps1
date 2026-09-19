# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
#
# Common.ps1 — 各脚本共用的基础工具（与 asar 无关，asar 相关功能已全部移除）

function Get-PatcherRoot {
    if ($PSScriptRoot) {
        return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
    }
    return (Get-Location).Path
}

function Get-StateRoot {
    $local = $env:LOCALAPPDATA
    if (-not $local) { $local = Join-Path $HOME "AppData\Local" }
    return (Join-Path $local "bsb-client-patcher")
}

function Find-Node {
    if ($env:MIMO_NODE -and (Test-Path $env:MIMO_NODE)) { return $env:MIMO_NODE }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Compare-Version {
    <#
      .SYNOPSIS
        比较两个版本号字符串；返回 -1 / 0 / 1（"0.10.0" > "0.9.0"）。
    #>
    [CmdletBinding()]
    param([string]$Left, [string]$Right)
    $l = @(($Left -replace '[^0-9.]', '') -split '\.' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
    $r = @(($Right -replace '[^0-9.]', '') -split '\.' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt [Math]::Max($l.Count, $r.Count); $i++) {
        $a = if ($i -lt $l.Count) { $l[$i] } else { 0 }
        $b = if ($i -lt $r.Count) { $r[$i] } else { 0 }
        if ($a -ne $b) { return $(if ($a -gt $b) { 1 } else { -1 }) }
    }
    return 0
}
