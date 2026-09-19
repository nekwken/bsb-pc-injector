#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Update BSB plugin payload for CDP runtime injector.
#>
[CmdletBinding()]
param(
    [string]$PayloadDir,
    [string]$ZipPath,
    [switch]$Force,
    [switch]$SkipClient  # ignored in runtime mode; kept for compat
)

$ErrorActionPreference = "Stop"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $PatcherRoot "tools\Asar.ps1")

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok($m) { Write-Host "  [OK] $m" -ForegroundColor Green }

$StateRoot = Get-StateRoot
$PayloadRuntime = Join-Path $StateRoot "payload"
$StatePath = Join-Path $StateRoot "state.json"
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

Write-Host ""
Write-Host "BSB Plugin Updater (runtime mode)" -ForegroundColor Magenta
Write-Host ""

if ($ZipPath) {
    if (-not (Test-Path $ZipPath)) { throw "Zip not found: $ZipPath" }
    $tmp = Join-Path $StateRoot "payload-incoming"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    Expand-Archive -Path $ZipPath -DestinationPath $tmp -Force
    $mfFile = Get-ChildItem $tmp -Recurse -Filter manifest.json | Select-Object -First 1
    if (-not $mfFile) { throw "manifest.json not in zip" }
    $incoming = $mfFile.Directory.FullName
} elseif ($PayloadDir) {
    $incoming = (Resolve-Path $PayloadDir).Path
} else {
    $incoming = Join-Path $PatcherRoot "payload"
}

$mf = Join-Path $incoming "manifest.json"
if (-not (Test-Path $mf)) { throw "Invalid payload" }
$manifest = Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json
# 运行时注入只需要内容脚本；UI/设置脚本缺失也能跑（只是没有界面）
foreach ($f in @("bsb-content.js")) {
    if (-not (Test-Path (Join-Path $incoming $f))) { throw "Payload missing $f" }
}

Write-Step "Install payload -> state dir"
if (Test-Path $PayloadRuntime) { Remove-Item -Recurse -Force $PayloadRuntime }
Copy-Item -Recurse -Force $incoming $PayloadRuntime
Write-Ok "payload v$($manifest.version)"

# also copy into repo payload if injector uses it as fallback
Write-Ok "If injector is running, restart it to load new payload."

if (Test-Path $StatePath) {
    try {
        $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        $st | Add-Member -NotePropertyName payloadVersion -NotePropertyValue $manifest.version -Force
        $st | Add-Member -NotePropertyName lastPluginUpdatedAt -NotePropertyValue (Get-Date).ToString("o") -Force
        [System.IO.File]::WriteAllText($StatePath, ($st | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
    } catch {}
}

Write-Host ""
Write-Ok "Done. Restart injector if it was running."
