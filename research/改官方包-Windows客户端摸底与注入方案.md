# 改官方包路线：哔哩哔哩 Windows PC 客户端摸底与注入方案

日期：2026-09-18  
样本：`bili_win-install.exe` v1.18.0（MD5 `1BE49BF448BB901E8A7F3CEF7BE174DF`，约 198MB，CDN 2026-07-30）  
本地材料：`research/client/`

---

## 1. 结论（一句话）

**Windows 官方 PC 客户端是 Electron 应用**（1.18.0，主逻辑混淆 + asar 完整性校验 + electron-updater）。  
技术上「改官方包注入 BSB」可行，但不能简单替换 asar——需要绕过/同步 `.appkey` 完整性机制，并处理官方自动更新覆盖。播放器页面疑似 `bilipc.bilibili.com` 自定义页，**不能默认套用网页版 `.bpx-*` 选择器**。

---

## 2. 安装包与应用结构

### 2.1 外层：NSIS 3

| 项 | 值 |
|----|----|
| 安装器 | Nullsoft Install System v3.04 Unicode |
| PE 版本 | FileVersion/ProductVersion **1.18.0.4968** / 1.18.0 |
| 产品信息 | 哔哩哔哩 / 哔哩哔哩PC客户端 / Copyright 2022 |
| 载荷 | `$PLUGINSDIR/app-64.7z`（91MB）+ `app-arm64.7z`（95MB） |
| 安装 UI | Qt5（仅安装器界面，不是播放器） |
| 配置 | `bili-config.json`: `{"chid":"official","preInstall":false,"cleanUninstall":false,"oldBuild":true}` |

解包路径：

```
bili_win-install.exe
  └─ NSIS $PLUGINSDIR
       ├─ app-64.7z / app-arm64.7z
       ├─ 卸载哔哩哔哩.exe
       └─ Qt5* / nsis7z.dll / bili-config.json
```

### 2.2 应用本体（app-64 解包后）

```
哔哩哔哩.exe                 # Electron 主程序（约 152MB，含打包运行时）
LICENSE.electron.txt
LICENSES.chromium.html
chrome_*.pak / icudtl.dat / ffmpeg.dll / libEGL / snapshot_blob.bin
locales/*.pak
resources/
  app.asar                  # 69MB，主代码
  app.asar.unpacked/        # @nut-tree、clipboardy 等 native
  app-update.yml
  elevate.exe
```

`app-update.yml`：

```yaml
provider: generic
url: https://api.bilibili.com/x/elec-frontend/update/
updaterCacheDirName: bilibili-updater
```

**结论：官方更新通道存在；任何 asar 改动都会被自动更新覆盖，除非禁用更新或同步打补丁。**

### 2.3 app.asar 内部

| 路径 | 大小 | 说明 |
|------|------|------|
| `package.json` | — | name=`bilibili`, version=`1.18.0`, **无 `main` 字段**（Electron 默认 `index.js`） |
| `index.js` | 38KB | **混淆 bootstrap**（资源完整性 / asar 修复 / 拉起 main） |
| `.appkey` | — | `3c1749ef41608c9df511c185885de4f9.ae76716472cb7197df` |
| `main/index.js` | 285KB | **重度混淆** Electron 主进程 |
| `main/.biliapp` | 3.2MB | 以 SHA256 十六进制串开头的封装数据（疑似加密/打包业务逻辑） |
| `main/assets/bili-preload.js` | 36KB | 混淆 preload；含 **IPC 通道明文**与页面域名判断 |
| `main/assets/bili-inject.js` | 33KB | 混淆注入脚本 |
| `main/assets/bili-bridge.js` | 33KB | 混淆 bridge |
| `main/assets/bili-helper.js` | 10KB | 系统信息采集 helper（systeminformation） |
| `node_modules/` | — | electron-store / electron-updater / electron-log / express / axios / @bilibili/* |

`app.asar.unpacked`：`@nut-tree/libnut-win32`（输入自动化）、`clipboardy`。

---

## 3. 运行时架构（已证实 / 高概率）

```
哔哩哔哩.exe (Electron)
    │
    ├─ index.js bootstrap
    │     · 校验 resources ctime / .appkey
    │     · 失败则修复 asar（glob **.asar）
    │     · process.noAsar 切换
    │     · require main/index.js
    │
    ├─ main/index.js + main/.biliapp   # 主进程（混淆）
    │
    └─ BrowserWindow / webContents
          preload: main/assets/bili-preload.js
          inject:  main/assets/bili-inject.js
          页面:    https://bilipc.bilibili.com/index.html
                   https://bilipc.bilibili.com/player.html
```

### 3.1 preload 暴露的事实（部分 hex 可还原）

- `contextBridge.exposeInMainWorld` → 渲染进程有桥接 API
- IPC 通道族（节选）：
  - `app/getAppInfo`, `app/isDev`, `app/isRelease`, `app/isDevMode`, `app/launchAction`
  - `store/*`, `system/getAppPath`, `system/getFontsInfo`, `system/checkIsGrayHit`
  - `config/*`（主题、快捷键、退出行为等）
  - `window/isPinned`, `window/isFullScreen`, `window/isMiniPlayerMode`
  - `window/isPlayerWindowVisible`, `window/isLiveRoomWindowOpened`, `window/isBiliPetVisible`
- **页面域名白名单判断**：`https://bilipc.bilibili.com/(index|player).html`
- 对 ENOENT 的 player/index 页有隐藏/重载逻辑

> 本环境 DNS 无法解析 `bilipc.bilibili.com`（可能仅国内可达）。安装客户端后需在本机抓包/DevTools 确认播放器 DOM。

### 3.2 对 BSB 移植的含义

| 假设 | 含义 |
|------|------|
| 播放页是 bilipc 自定义页 | `.bpx-player-*`、`window.__INITIAL_STATE__`、`player.getManifest()` **可能不存在或形态不同** |
| 播放页内嵌网页版播放器 | 可部分复用 BSB DOM 钩子，但仍需适配 URL/选择器 |
| 原生播放窗 | 只能做「逻辑层 + 原生 seek/mute API」，不能复用 previewBar UI |

**先决实验：安装官方客户端 → 打开视频 → 远程调试看真实 DOM 与全局变量。**

---

## 4. 完整性与反篡改

### 4.1 bootstrap（`index.js`）行为要点

混淆代码中可辨识的逻辑：

1. 计算 resources 相关路径的 **ctime hash**（`v(ctime)`）
2. 写入/比对 `.appInfo`
3. 读取 asar 内 `.appkey` 与外部文件比对
4. glob `**.asar`，删除 hash 名不匹配的 asar
5. 设置 `process.noAsar`
6. 最终 `require(.../main/index.js)`

同时存在 `resources/elevate.exe`、安装器 `requireAdministrator`，涉及提权与固定资源目录（代码中出现 fixed resource / `.testFixed` 一类路径分支）。

### 4.2 对「直接改 asar」的影响

| 操作 | 风险 |
|------|------|
| 只改 `app.asar` 内 preload/main | ctime/hash 失败 → bootstrap **可能自动修复/回滚** |
| 替换 asar 不改 `.appkey` | key 比对失败 |
| 删除 asar 放 `app/` 文件夹 | 可能被 bootstrap 当异常 asar 清理 |
| 改完不处理更新 | 官方 updater 覆盖补丁 |

### 4.3 可行绕过方向（研究级，需本机验证）

**方案 P1 — 改 bootstrap（推荐首选实验）**  
在 asar 内把 `index.js` 换成极简入口：直接 `require('./main/index.js')` 或 `require('./main/bootstrap-lite.js')`。  
完整性逻辑不再执行，后续 preload/inject 随便改。  
代价：需保证 Electron 仍能从 asar/unpacked 加载；更新后重打。

**方案 P2 — 同步伪造完整性**  
反混淆 hash（ctime + 算法），写回 `.appkey` / `.appInfo`。  
难点：算法混淆、可能还依赖 exe 路径/机器信息；工作量大。

**方案 P3 — 运行时注入（PoC 优先）**  
不改包，用官方 Electron 的调试面：
- 快捷方式加 `--remote-debugging-port=9222`
- 或在已安装目录旁挂 wrapper（`哔哩哔哩.exe` 同级启动脚本）  
用 CDP 注入 skip 脚本，验证 bilipc 播放器 DOM 后再固化进包。

**方案 P4 — 安装后「资源目录替换」**  
安装完成后、更新前，替换 `resources/app.asar` + 屏蔽更新域名（hosts / 防火墙）+ 保留修改后的 bootstrap。  
适合个人机；不适合对外分发改包安装器。

---

## 5. 与 BSB 集成的注入点设计

### 5.1 目标注入链（改包后）

```
[官方 Electron 主进程]
        │
        ├─（可选）main 进程：fetch bsbsb.top 片段（替代 chrome.runtime 代理）
        │
        ├─ preload 追加 / bsb-preload.js
        │     · contextBridge 暴露 bsb.getConfig / seek / mute
        │     · 复用或旁路官方 IPC
        │
        ├─ 页面脚本 bsb-content.js（document_start 等价）
        │     · 识别 bilipc player DOM / video 元素
        │     · 拉取 skipSegments
        │     · skip/mute 调度
        │
        └─ 配置：userData 目录 JSON / electron-store
```

### 5.2 MVP 模块映射（相对 BSB 源码）

| BSB 模块 | 改官方包策略 |
|----------|----------------|
| `skipScheduler` | 原样移植到页面脚本，video 控制改走真实 `<video>` 或桥接 API |
| `segmentRequest` + `ServerRouter` | 移到主进程或页面 fetch（注意 CORS/UA 头 `origin`/`x-ext-version`） |
| `hash` (SHA256 前缀) | 可在页面/主进程本地算，不依赖 chrome.runtime |
| `config.storage` | `electron-store` 或 userData JSON |
| `content.ts` DOM UI | **暂缓**；先确认 bilipc 是否有进度条可挂 |
| `document.ts` window 全局 | 需实测 bilipc 是否仍有 `__INITIAL_STATE__` |

### 5.3 必须先做的运行时探测清单

1. `哔哩哔哩.exe --remote-debugging-port=9222` 是否允许  
2. 播放窗 URL 是 `bilipc.bilibili.com/player.html` 还是 `www.bilibili.com/video/...`  
3. 是否存在 `HTMLVideoElement`、如何 seek  
4. 是否存在 `window.__INITIAL_STATE__` / `window.player`  
5. 进度条 DOM 结构（决定能否画 segment 条）  
6. CSP / contextIsolation / sandbox 设置  
7. 官方是否二次校验 asar（启动后 `.appInfo` 是否被重写）

---

## 6. 风险与合规（改包路线）

| 风险 | 级别 | 说明 |
|------|------|------|
| 自动更新覆盖 | 高 | updater 指向官方 API；需禁用或每次重打补丁 |
| 启动完整性回滚 | 高 | `.appkey`/ctime 校验可能还原 asar |
| 混淆代码升级 | 中 | 1.18.x 小版本也会改 index.js/preload |
| 播放器 DOM 变更 | 中 | bilipc 页面非标准网页，选择器脆弱 |
| 用户协议 / 商业冲突 | 中高 | 跳过恰饭与官方商业化冲突；对外分发改包风险更大 |
| GPL-3.0 | 中 | BSB 代码若打进改包分发，需评估传染与开源义务 |
| 签名/杀软 | 中 | 改 asar 后可能破坏原有签名链路，触发拦截 |

**定位建议：**  
- **个人本机、研究/PoC**：P3 运行时注入 → P1 改 bootstrap 改包，可接受。  
- **对外分发改包安装器**：技术+合规成本都高，不推荐作为第一阶段目标。

---

## 7. 建议实施阶段

### 阶段 A — 运行时确认（不改包）
1. 干净环境安装官方 1.18.0  
2. 开 `--remote-debugging-port`，播放测试视频（如 BV14741127BN）  
3. 记录：窗口 URL、DOM、video、CSP、preload 桥接对象  
4. 用 CDP 注入最小 skip 原型（查 `bsbsb.top/api/skipSegments` + `video.currentTime=`）

### 阶段 B — 本地改包 PoC
1. 7z 解包安装后目录 `resources/app.asar`  
2. 替换/简化 `index.js` bootstrap（跳过完整性）  
3. 在 `bili-preload.js` 末尾或新增 `bsb-preload.js` 挂钩  
4. 注入 `bsb-content.js`：ID 解析 → 拉片段 → skip  
5. 屏蔽 `api.bilibili.com/x/elec-frontend/update/`（hosts 或防火墙）  
6. 验证重启后补丁仍在

### 阶段 C — 功能收敛
1. 适配 bilipc 真实 DOM（进度条 / 提示条）  
2. 配置面板（类别开关）  
3. 用户数据目录持久化  
4. 文档化「官方更新后重打补丁」流程

### 阶段 D —（可选）安装器级重打包
- 仅在阶段 B 稳定后考虑：改 `app-64.7z` → 重打 NSIS  
- 需处理卸载器、更新器、杀软、分发合规

---

## 8. 本地材料索引

| 路径 | 内容 |
|------|------|
| `research/client/bili_win-install.exe` | 官方安装包 |
| `research/client/extracted/` | NSIS 解包（$PLUGINSDIR） |
| `research/client/app-64/` | Electron 应用目录 |
| `research/client/asar_extract/` | app.asar 完整解开 |
| `research/先期研究-BSB入官方电脑客户端.md` | 第一阶段总览 |
| `research/BilibiliSponsorBlock/` | 插件源码 |

---

## 9. 待决问题

1. 你本机是否已安装官方客户端？（有则可直接做阶段 A 运行时探测）  
2. 目标平台：仅 Windows，还是也要 Mac（`pc_electron_mac`，同样 Electron）？  
3. 验收标准：个人可用即可，还是要可分发的改包安装器？  
4. 播放器若为原生控件，是否接受 MVP 只有「自动跳过、无进度条 UI」？
