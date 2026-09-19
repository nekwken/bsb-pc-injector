# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
# Asar.ps1 - asar pack/unpack helpers (Node @electron/asar)

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

function Initialize-AsarTool {
    param([string]$PatcherRoot)
    $node = Find-Node
    if (-not $node) {
        throw "Node.js not found. Install Node 18+ or set MIMO_NODE."
    }
    $toolDir = Join-Path $PatcherRoot "tools\npm"
    $asarJs = Join-Path $toolDir "node_modules\@electron\asar\bin\asar.mjs"
    if (-not (Test-Path $asarJs)) {
        New-Item -ItemType Directory -Force -Path $toolDir | Out-Null
        $npm = $env:MIMO_NPM
        if (-not $npm) {
            $cand = Join-Path (Split-Path $node -Parent) "node_modules\npm\bin\npm-cli.js"
            if (Test-Path $cand) { $npm = $cand }
        }
        if ($npm -and (Test-Path $npm)) {
            & $node $npm install "@electron/asar" --no-fund --no-audit --prefix $toolDir
        } else {
            $npmCmd = Get-Command npm -ErrorAction SilentlyContinue
            if ($npmCmd) {
                & $node $npmCmd.Source install "@electron/asar" --no-fund --no-audit --prefix $toolDir
            } else {
                throw "npm not found; cannot install @electron/asar"
            }
        }
    }
    if (-not (Test-Path $asarJs)) {
        throw "Failed to install @electron/asar into $toolDir"
    }
    return @{ Node = $node; AsarJs = $asarJs }
}

function Expand-AsarFile {
    param(
        [Parameter(Mandatory)]$Tool,
        [Parameter(Mandatory)][string]$AsarPath,
        [Parameter(Mandatory)][string]$DestDir
    )
    if (Test-Path $DestDir) {
        Remove-Item -Recurse -Force $DestDir
    }
    New-Item -ItemType Directory -Force -Path $DestDir | Out-Null
    & $Tool.Node $Tool.AsarJs extract $AsarPath $DestDir
    if ($LASTEXITCODE -ne 0) {
        throw "asar extract failed: $AsarPath"
    }
}

function Compress-AsarFile {
    param(
        [Parameter(Mandatory)]$Tool,
        [Parameter(Mandatory)][string]$SrcDir,
        [Parameter(Mandatory)][string]$OutAsar
    )
    if (Test-Path $OutAsar) {
        Remove-Item -Force $OutAsar
    }
    $outDir = Split-Path $OutAsar -Parent
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }
    & $Tool.Node $Tool.AsarJs pack $SrcDir $OutAsar
    if ($LASTEXITCODE -ne 0) {
        throw "asar pack failed: $OutAsar"
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
}
