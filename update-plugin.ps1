#requires -Version 5.1
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 BSB PC client injector contributors
<#
.SYNOPSIS
  更新（或自动更新）BSB 插件包 payload。

.DESCRIPTION
  三种来源：
    -PayloadDir <目录>   本地目录（含 manifest.json）
    -ZipPath <zip>       本地压缩包
    -Source <url|path>   远端更新源：目录（含 manifest.json）或 zip 的 URL/本地路径
    （都不给时用仓库里的 payload/）

  -Check   只检查是否有新版本，不安装（退出码 0=已最新, 10=有新版, 1=失败）
  -Auto    检查 + 有新版本就自动安装（供托盘/安装器/计划任务调用）

  更新源配置存在 %LOCALAPPDATA%\bsb-client-patcher\update.json：
    { "url": "...", "autoCheck": true }
  也可用环境变量 BSB_UPDATE_URL 覆盖。

.EXAMPLE
  .\update-plugin.ps1 -PayloadDir .\payload -Force
  .\update-plugin.ps1 -Check
  .\update-plugin.ps1 -Auto
#>
[CmdletBinding()]
param(
    [string]$PayloadDir,
    [string]$ZipPath,
    [string]$Source,
    [switch]$Force,
    [switch]$Check,
    [switch]$Auto,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"
$PatcherRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $PatcherRoot "tools\Common.ps1")

function Write-Step($m) { if (-not $Quiet) { Write-Host "==> $m" -ForegroundColor Cyan } }
function Write-Ok($m) { if (-not $Quiet) { Write-Host "  [OK] $m" -ForegroundColor Green } }
function Write-Warn2($m) { Write-Host "  [!] $m" -ForegroundColor Yellow }

$StateRoot = Get-StateRoot
$PayloadRuntime = Join-Path $StateRoot "payload"
$StatePath = Join-Path $StateRoot "state.json"
$UpdateCfgPath = Join-Path $StateRoot "update.json"
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null

# 默认更新源：仓库里的 payload 目录（发布到 GitHub 后改成 raw 地址即可）
$DefaultSource = "https://raw.githubusercontent.com/nekwken/bsb-pc-injector/main/payload"

function Get-UpdateConfig {
    $cfg = [ordered]@{ url = $DefaultSource; mirrors = @(); autoCheck = $true; lastCheck = $null; lastResult = $null; latestVersion = $null }
    if ($env:BSB_UPDATE_URL) { $cfg.url = $env:BSB_UPDATE_URL }
    if (Test-Path $UpdateCfgPath) {
        try {
            $saved = Get-Content $UpdateCfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @('url', 'mirrors', 'autoCheck', 'lastCheck', 'lastResult', 'latestVersion')) {
                if ($null -ne $saved.$k) { $cfg[$k] = $saved.$k }
            }
            if ($env:BSB_UPDATE_URL) { $cfg.url = $env:BSB_UPDATE_URL }
        } catch {}
    }
    return $cfg
}

function Save-UpdateConfig($cfg) {
    [System.IO.File]::WriteAllText($UpdateCfgPath, ($cfg | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
}

function Get-CurrentPayloadVersion {
    foreach ($p in @((Join-Path $PayloadRuntime "manifest.json"), (Join-Path $PatcherRoot "payload\manifest.json"))) {
        if (Test-Path $p) {
            try { return (Get-Content $p -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch {}
        }
    }
    return "0.0.0"
}

function Get-UpdateCandidates {
    <#
      .SYNOPSIS
        主源 + 自动推导的镜像列表。
      .DESCRIPTION
        GitHub raw 会按候选顺序尝试以下镜像（国内可达性依次兜底）：
        jsDelivr CDN → fastly → gcore → ghproxy。
        update.json 里还可以用 "mirrors": ["..."] 追加自定义镜像（排在最后）。
    #>
    [CmdletBinding()]
    param([string]$Url, [string[]]$ExtraMirrors)

    $list = @($Url)
    if ($Url -match '^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$') {
        $user = $Matches[1]; $repo = $Matches[2]; $branch = $Matches[3]; $path = $Matches[4]
        $list += "https://cdn.jsdelivr.net/gh/$user/$repo@$branch/$path"
        $list += "https://fastly.jsdelivr.net/gh/$user/$repo@$branch/$path"
        $list += "https://gcore.jsdelivr.net/gh/$user/$repo@$branch/$path"
        $list += "https://ghproxy.net/https://raw.githubusercontent.com/$user/$repo/$branch/$path"
    }
    if ($ExtraMirrors) { $list += $ExtraMirrors }
    return $list
}

$script:LastFetchError = $null

function Invoke-MirrorFetch {
    <#
      .SYNOPSIS
        依次尝试一组 URL，把第一个成功的下载到 OutFile；返回实际使用的 URL（全失败返回 $null）。
    #>
    [CmdletBinding()]
    param([string[]]$Urls, [string]$OutFile)

    foreach ($u in $Urls) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $OutFile -UseBasicParsing -TimeoutSec 25
            return $u
        } catch {
            $code = $null
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            $tag = if ($code) { "HTTP $code" } else { $_.Exception.Message }
            $script:LastFetchError = "$tag [$u]"
        }
    }
    return $null
}

function Get-RemoteManifest {
    <#
      取远端 manifest。支持 http(s)（主源 + 镜像回退）、本地目录、本地 zip。
      返回 @{ version; base; zip; candidates; viaHost }
    #>
    param([string]$Url, [string[]]$ExtraMirrors)

    if ($Url -notmatch '^https?://') {
        # 本地路径（便于离线测试 / 内网源）
        if (Test-Path $Url -PathType Container) {
            return [ordered]@{ manifestPath = (Join-Path $Url "manifest.json"); base = $Url; candidates = @($Url); viaHost = 'local' }
        }
        if (Test-Path $Url) {
            return [ordered]@{ zip = (Resolve-Path $Url).Path; candidates = @($Url); viaHost = 'local' }
        }
        throw "更新源不可用: $Url"
    }

    $tmp = Join-Path $StateRoot "update-cache"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $candidates = Get-UpdateCandidates -Url $Url -ExtraMirrors $ExtraMirrors

    foreach ($c in $candidates) {
        if ($c -match '\.zip($|\?)') {
            $zip = Join-Path $tmp "payload.zip"
            if (Invoke-MirrorFetch -Urls @($c) -OutFile $zip) {
                $hostName = ([uri]$c).Host
                return [ordered]@{ zip = $zip; candidates = $candidates; viaHost = $hostName }
            }
            continue
        }
        $base = $c.TrimEnd('/')
        $mf = Join-Path $tmp "manifest.json"
        $used = Invoke-MirrorFetch -Urls @("$base/manifest.json") -OutFile $mf
        if ($used) {
            $hostName = ([uri]$used).Host
            return [ordered]@{ manifestPath = $mf; base = $base; candidates = $candidates; viaHost = $hostName }
        }
    }
    throw "所有更新源都不可用（最后错误：$($script:LastFetchError)）"
}

function Get-ManifestVersion($remote) {
    if ($remote.zip) {
        $tmp = Join-Path $StateRoot "payload-incoming"
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
        Expand-Archive -Path $remote.zip -DestinationPath $tmp -Force
        $mf = Get-ChildItem $tmp -Recurse -Filter manifest.json | Select-Object -First 1
        if (-not $mf) { throw "压缩包里没有 manifest.json" }
        return [ordered]@{ version = (Get-Content $mf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).version; dir = $mf.Directory.FullName; viaHost = $remote.viaHost }
    }
    if (-not (Test-Path $remote.manifestPath)) { throw "更新源里没有 manifest.json" }
    $json = Get-Content $remote.manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $dir = Split-Path $remote.manifestPath -Parent

    # http(s) 目录源：把清单里的每个文件都下载到本地临时目录（每个文件单独走一遍镜像链）
    if ($remote.base -match '^https?://') {
        foreach ($f in (@("manifest.json") + @($json.files))) {
            $urls = Get-UpdateCandidates -Url ($remote.base.TrimEnd('/') + "/$f") -ExtraMirrors $remote.extraMirrors
            $dest = Join-Path $dir $f
            if (-not (Invoke-MirrorFetch -Urls $urls -OutFile $dest)) {
                throw "下载 $f 失败：$($script:LastFetchError)"
            }
        }
    }
    return [ordered]@{ version = $json.version; dir = $dir; viaHost = $remote.viaHost }
}

function Install-Payload {
    param([string]$FromDir, [string]$Version)

    $mf = Join-Path $FromDir "manifest.json"
    if (-not (Test-Path $mf)) { throw "payload 目录里没有 manifest.json: $FromDir" }
    if (-not (Test-Path (Join-Path $FromDir "bsb-content.js"))) { throw "payload 缺少 bsb-content.js" }

    Write-Step "安装 payload v$Version -> $PayloadRuntime"
    if (Test-Path $PayloadRuntime) { Remove-Item -Recurse -Force $PayloadRuntime }
    Copy-Item -Recurse -Force $FromDir $PayloadRuntime
    Write-Ok "已安装 v$Version（注入器会在下一轮轮询自动热加载）"

    if (Test-Path $StatePath) {
        try {
            $st = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $st | Add-Member -NotePropertyName payloadVersion -NotePropertyValue $Version -Force
            $st | Add-Member -NotePropertyName lastPluginUpdatedAt -NotePropertyValue (Get-Date).ToString("o") -Force
            [System.IO.File]::WriteAllText($StatePath, ($st | ConvertTo-Json), (New-Object System.Text.UTF8Encoding $false))
        } catch {}
    }
}

# ------------------------------------------------------------------ 主流程

$cfg = Get-UpdateConfig
$current = Get-CurrentPayloadVersion

if ($Auto -and -not $Check) { $Quiet = $true }

if (-not $Quiet) {
    Write-Host ""
    Write-Host "BSB 插件更新" -ForegroundColor Magenta
    Write-Host "  当前版本 : v$current"
    if ($Check -or $Auto -or $Source) {
        $srcLabel = if ($Source) { $Source } else { $cfg.url }
        Write-Host "  更新源   : $srcLabel"
    }
    Write-Host ""
}

# 1) 显式来源（-PayloadDir / -ZipPath / -Source）
if ($PayloadDir -or $ZipPath -or $Source) {
    if ($ZipPath) {
        $r = Get-ManifestVersion ([ordered]@{ zip = (Resolve-Path $ZipPath).Path })
        Install-Payload -FromDir $r.dir -Version $r.version
        exit 0
    }
    if ($PayloadDir) {
        $dir = (Resolve-Path $PayloadDir).Path
        $v = (Get-Content (Join-Path $dir "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json).version
        Install-Payload -FromDir $dir -Version $v
        exit 0
    }
    $remote = Get-RemoteManifest -Url $Source -ExtraMirrors $cfg.mirrors
    $r = Get-ManifestVersion $remote
    if ($Check) {
        $newer = (Compare-Version $r.version $current) -gt 0
        Write-Host "  远端版本 : v$($r.version)  →  $(if ($newer) { '有新版本' } else { '已是最新' })"
        exit $(if ($newer) { 10 } else { 0 })
    }
    Install-Payload -FromDir $r.dir -Version $r.version
    exit 0
}

# 2) 检查 / 自动更新（走配置里的更新源）
try {
    $remote = Get-RemoteManifest -Url $cfg.url -ExtraMirrors $cfg.mirrors
    $r = Get-ManifestVersion $remote
    $via = $remote.viaHost
    $cfg.lastCheck = (Get-Date).ToString("o")
    $cfg.latestVersion = $r.version
    $newer = (Compare-Version $r.version $current) -gt 0

    if ($Check) {
        $cfg.lastResult = $(if ($newer) { "有新版 v$($r.version)（via $via）" } else { "已是最新（via $via）" })
        Save-UpdateConfig $cfg
        if (-not $Quiet) { Write-Host "  远端版本 : v$($r.version)  →  $(if ($newer) { '有新版本' } else { '已是最新' })" }
        exit $(if ($newer) { 10 } else { 0 })
    }

    if (-not $newer -and -not $Force) {
        $cfg.lastResult = "已是最新（via $via）"
        Save-UpdateConfig $cfg
        if (-not $Quiet) { Write-Ok "已是最新（v$current），无需更新" }
        exit 0
    }

    $cfg.lastResult = "已更新到 v$($r.version)（via $via）"
    Save-UpdateConfig $cfg
    Install-Payload -FromDir $r.dir -Version $r.version
    exit 0
} catch {
    $cfg.lastCheck = (Get-Date).ToString("o")
    $cfg.lastResult = "检查失败：" + $_.Exception.Message
    Save-UpdateConfig $cfg
    if (-not $Quiet) { Write-Warn2 $cfg.lastResult }
    exit 1
}
