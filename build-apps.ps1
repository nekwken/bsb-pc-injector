#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  Build the two native apps into bin\.

.DESCRIPTION
  bin\BSB.exe  — 主程序：托盘常驻 + 设置窗口（WPF/Mica）同一进程
                 双击开窗口；--tray 只起托盘（登录自启用）；--ui 唤出已运行实例的窗口

  需要 .NET 8 SDK（含 Windows Desktop 运行时）。发布为框架依赖的单文件，
  所以 exe 很小（~200KB），运行需要本机的 .NET 8 Desktop 运行时。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\build-apps.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$bin = Join-Path $root "bin"
New-Item -ItemType Directory -Force -Path $bin | Out-Null

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "需要 .NET SDK：https://dotnet.microsoft.com/download"
}

$projects = @(
    @{ Dir = "apps\App"; Name = "主程序" }
)

foreach ($p in $projects) {
    $dir = Join-Path $root $p.Dir
    Write-Host "==> 构建 $($p.Name) ($($p.Dir))" -ForegroundColor Cyan
    # 关掉正在运行的旧实例，否则单文件发布无法覆盖 exe
    $exeName = "BSB"
    Get-Process -Name $exeName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400

    $proj = Get-ChildItem $dir -Filter *.csproj | Select-Object -First 1
    if (-not $proj) { throw "$dir 下找不到 .csproj" }

    & dotnet publish $proj.FullName -c Release -r win-x64 --self-contained false `
        -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true `
        -o $bin -v q --nologo
    if ($LASTEXITCODE -ne 0) { throw "$($p.Name) 构建失败" }
}

Write-Host ""
Get-ChildItem $bin -Filter *.exe | ForEach-Object {
    Write-Host ("  {0}  {1:N0} KB" -f $_.Name, ($_.Length / 1KB)) -ForegroundColor Green
}
Write-Host ""
Write-Host "主程序：双击 bin\BSB.exe（托盘常驻 + 设置窗口；登录自启用 BSB.exe --tray）" -ForegroundColor Yellow
Write-Host "" -ForegroundColor Yellow
