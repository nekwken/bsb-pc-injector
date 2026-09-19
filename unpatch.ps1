#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Restore official app.asar (undo BSB patch)
#>
[CmdletBinding()]
param(
    [string]$InstallRoot,
    [string]$BackupPath,
    [switch]$RestoreUpdateYml
)

$ErrorActionPreference = "Stop"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $PatcherRoot "tools\Asar.ps1")
. (Join-Path $PatcherRoot "tools\Find-Client.ps1")

$StateRoot = Get-StateRoot
$StatePath = Join-Path $StateRoot "state.json"
$BackupDir = Join-Path $StateRoot "backups"

Write-Host "==> Restore official client" -ForegroundColor Cyan

$root = $InstallRoot
if (-not $root -and (Test-Path $StatePath)) {
    try { $root = (Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json).installRoot } catch {}
}
if (-not $root) {
    $root = Find-BilibiliInstall -StatePath $StatePath
}
if (-not $root) { throw "Client install root not found" }

$asarPath = Join-Path $root "resources\app.asar"
if (-not (Test-Path $asarPath)) { throw "app.asar not found: $asarPath" }

$bak = $BackupPath
if (-not $bak) { $bak = Join-Path $BackupDir "app.asar.bak" }
if (-not (Test-Path $bak)) { throw "Backup not found: $bak" }

Write-Host "  InstallRoot: $root"
Write-Host "  Backup:      $bak"
Copy-Item -Force $bak $asarPath
Write-Host "  [OK] app.asar restored" -ForegroundColor Green

if ($RestoreUpdateYml) {
    $ymlBak = Join-Path $BackupDir "app-update.yml.bak"
    $yml = Join-Path $root "resources\app-update.yml"
    if (Test-Path $ymlBak) {
        Copy-Item -Force $ymlBak $yml
        Write-Host "  [OK] app-update.yml restored" -ForegroundColor Green
    }
}

if (Test-Path $StatePath) {
    try {
        $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $st | Add-Member -NotePropertyName lastPatchedAsarHash -NotePropertyValue $null -Force
        $st | Add-Member -NotePropertyName unpatchedAt -NotePropertyValue (Get-Date).ToString("o") -Force
        $st | ConvertTo-Json | Set-Content -Path $StatePath -Encoding UTF8
    } catch {}
}

Write-Host "Quit and reopen Bilibili client." -ForegroundColor Yellow
