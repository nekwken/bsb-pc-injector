# 先期研究：BilibiliSponsorBlock 内置入哔哩哔哩官方电脑客户端

日期：2026-09-17  
源码：`research/BilibiliSponsorBlock`（GitHub hanydd/BilibiliSponsorBlock @ master，已 shallow clone）

---

## 1. 目标澄清

「内置入官方电脑客户端」至少有四种含义，技术难度与合规风险完全不同：

| 路径 | 含义 | 可行性 |
|------|------|--------|
| A. 官方合作/上游集成 | B 站在官方客户端内原生支持空降 | 极低（涉及广告/商单收入） |
| B. 修改官方客户端 | 解包 asar/安装包，注入脚本或改包 | 中等，但破坏更新、签名与合规风险高 |
| C. 第三方桌面客户端内置 | 自研/改开源 Electron/Tauri 壳，内置 skip 逻辑 | 最可控，社区已有 Android 先例 |
| D. 浏览器扩展保持现状 | 继续网页端使用 | 已成熟 |

**推荐先期默认目标：C（可控验证）+ 对 B 做技术摸底**，不建议一上来就做 A 或硬改官方闭源包。

---

## 2. 插件本体（BilibiliSponsorBlock）

### 2.1 基本信息

- 名称：小电视空降助手 / BilibiliSponsorBlock
- 版本：manifest 0.14.0；package.json 0.1.10
- 许可：**GPL-3.0**（分发改包时传染风险高）
- 服务端：`https://www.bsbsb.top`（测试 `https://www.bsbsb.top/test`）
- API 兼容 SponsorBlock 协议，B 站侧以 `videoID=BVID` + `cid` 标识
- 数据库可全量下载：`https://download.bsbsb.top/database.zip`
- 第三方移植（官方 wiki 收录）目前全是 **Android**：BiliRoamingX、BiliSponsorSkip、BBZQ、PipePipe  
  → **尚无官方电脑客户端移植项目**

### 2.2 运行时架构

```
┌─────────────────────────────────────────────┐
│ MAIN world (document.js)                    │
│  window.__INITIAL_STATE__ / player.getManifest() │
│  postMessage ───────────────────────────┐   │
├─────────────────────────────────────────┼───┤
│ ISOLATED content.js                     ▼   │
│  content.ts 事件总线 / skipScheduler / UI   │
│  video 发现 (bpx DOM + Navigation API)      │
├─────────────────────────────────────────────┤
│ background.ts (MV3 SW)                      │
│  消息路由 + fetch 代理 + ServerRouter 缓存   │
└─────────────────────────────────────────────┘
```

关键源码：

- 双 world 注入：`src/document/document.ts`、`src/content.ts`
- Skip 调度：`src/content/skipScheduler.ts`（直接改 `video.currentTime` / `muted`）
- 播放器定位：`src/utils/pageUtils.ts`、`src/utils/video.ts`
- 服务端：`src/requests/serverRouter.ts`、`src/requests/background/segmentRequest.ts`

### 2.3 对浏览器扩展 API 的依赖（移植核心耦合）

**强依赖（必须替换）：**

- `chrome.storage.sync/local` — 配置与缓存（`src/config/config.ts`）
- `chrome.runtime.sendMessage/onMessage` — content ↔ background
- `chrome.runtime.getURL` — 图标 / beep 音频
- `chrome.runtime.getManifest` — 版本号 / UA
- i18n / tabs / scripting / permissions — 次要

全库约 **463 处** `chrome.*` / `browser.*` 引用。

**可抽象、低耦合：**

- `src/utils/browserApi.ts` 只是 chrome/browser shim
- 服务端真实调用是 `fetch`（`background-request-proxy.ts`）
- `ServerRouter` 已注入 `executeRequest` / `loadState` / `saveState`
- hash 用 `crypto.subtle`，可本地执行

### 2.4 对 B 站网页播放器的依赖

**DOM 选择器（深绑 bpx 播放器）：**

- `#bilibili-player`
- `.bpx-player-video-wrap`
- `.bpx-player-control-bottom-left/right`
- `.bpx-player-progress-schedule`
- `.bpx-player-ctrl-time(-label)`
- `.bpx-player-shadow-progress-area` / `.bpx-player-progress-popup`
- `.bpx-player-video-area`
- 动态/评论：`.bili-dyn-*`、`bili-comments` shadow DOM

**Window 全局：**

- `__INITIAL_STATE__`（bvid / aid / cid / upData / videoData）
- `player.getManifest()`
- `__playinfo__`
- Vue `__vue__` / `__vue_app__`（用于 ready 探测）

**视频控制：** 标准 `HTMLMediaElement`（`currentTime` / `muted` / `playbackRate`）

### 2.5 功能范围（类别 / 动作）

类别：sponsor, selfpromo, exclusive_access, interaction, poi_highlight, intro, outro, preview, padding, filler, music_offtopic  

动作：skip / mute / full / poi / chapter  

MVP 优先：**查询片段 + 自动 skip/mute**；UI（进度条色条、提示条、投稿/投票）可后置。

---

## 3. 官方电脑客户端技术摸底

### 3.1 官方下载页（app.bilibili.com）

| 渠道 | URL | 技术线索 |
|------|-----|----------|
| Windows 客户端 | `dl.hdslb.com/mobile/fixed/bili_win/bili_win-install.exe` | ~198 MB，2026-07-30；PE 头采样见 nsis/inno 字节噪声，**未见 electron/asar 字符串**；完整包未拆 |
| Mac 客户端 | `dl.hdslb.com/mobile/fixed/pc_electron_mac/bili_mac.dmg` | ~182 MB；路径 **`pc_electron_mac`** → **Electron 确认** |
| UWP（旧/并行） | `dl.hdslb.com/mobile/appinstaller/bilibili_win.appinstaller` | 2.14.81.0，包名 `36699Atelier39.forWin10`，上海幻电；依赖 **.NET Native 2.2 + WinUI/Microsoft.UI.Xaml 2.7** |

### 3.2 待验证（下一步硬摸底）

1. Windows 安装包完整下载 + 7-Zip/asar 列表，确认是否 Electron / CEF / Qt 原生
2. 安装后目录：是否有 `resources/app.asar`、`electron.asar`、`ffmpeg.dll` 等
3. 播放器形态：网页版 bpx 播放器（webview）还是原生播放器 + 自绘 UI
   - **这是可行性分水岭**：若为网页播放器，插件 DOM 路线可复用；若原生播放器，只能移植逻辑层 + 对接原生 seek/mute API
4. 是否暴露可注入面：`--remote-debugging-port`、preload、CEF command line

### 3.3 参考生态

- BiliRoamingX：Android + ReVanced，集成 BSB 公开 API（wiki 3rd Party Ports）
- hlbmerge：支持 Windows/Mac **客户端缓存文件**解析，说明客户端有本地缓存目录可研究
- 第三方桌面壳：bbhouse-tauri、bilibili-desktop（vue3+electron）、bilidesk —— 适合路径 C 的宿主

---

## 4. 移植可行性评估

### 4.1 风险

| 风险 | 说明 |
|------|------|
| 官方客户端非网页 DOM | `.bpx-*` 与 `__INITIAL_STATE__` 全失效 |
| chrome.* 渗透 | 不能「原样塞扩展」，需宿主适配层 |
| GPL-3.0 | 分发含本代码的改包/客户端，可能触发传染合规问题 |
| ToS / 商业 | 跳过恰饭/软广，与官方商业化冲突；改包可能违反用户协议 |
| 更新覆盖 | 官方客户端自动更新会冲掉注入 |
| 签名校验 | 改包可能无法通过完整性校验 |

### 4.2 模块可复用性

**可直接复用（纯逻辑）：**

- types / 类别配置
- skip 调度核心（`getNextSkipIndex` / `shouldSkip` / skipToTime）
- BVID/AID/CID 换算、hash 前缀
- `ServerRouter` + segment 请求过滤（已注入存储）

**需适配：**

- video 发现、页面路由监听
- DOM UI（progress bar / notices）
- storage → 本地文件 / SQLite / electron-store
- content↔background 消息 → IPC / 同进程调用

**难移植 / MVP 可砍：**

- PreviewBar、SkipNotice、popup/options 页
- 投稿/投票/搬运视频绑定
- 动态/评论/缩略图标注
- 完整 i18n

### 4.3 推荐 MVP 边界

1. **ID 解析**：从宿主播放信息拿 `bvid + cid`（不要依赖 window/DOM）
2. **片段服务**：`skipSegments/:sha256HashPrefix` + 本地缓存
3. **Skip 引擎**：拿到 video 或播放器 API 后执行 skip/mute
4. **最小配置**：类别开关 + 总开关
5. **暂缓**：进度条 UI、提示条、投稿闭环

### 4.4 注入策略（若坚持碰官方客户端）

| 宿主形态 | 策略 |
|----------|------|
| Electron + 网页播放器 | preload 注入等价「双 world」；或 `session.loadExtension` 加载已打包扩展（若未禁用） |
| Electron + 原生播放器 | 仅移植逻辑层，对接原生 player 控制 |
| CEF / 其他 | command line / 注入 JS，难度更高 |
| UWP | 基本不可行（.NET Native，无浏览器扩展模型） |

更稳妥的工程化路线：**先做路径 C 的 Electron/Tauri 宿主验证 skip 引擎与 API，再评估是否/如何接触官方客户端。**

---

## 5. 建议的下一步

1. **确认目标路径**（B 改官方包 / C 第三方客户端内置 / 先做可运行原型）
2. 若继续摸官方 Windows 客户端：完整下载 `bili_win-install.exe`，解包确认技术栈与播放器形态
3. 在 Mac Electron 客户端上做只读探测（目录结构、是否有 asar、webview URL）
4. 抽出 skip-core（types + hash + segment fetch + scheduler）为独立 TS 包
5. 用最小 Electron demo（加载 bilibili 网页或 API）验证「查片段 → 自动跳过」
6. 评估 GPL 与 ToS：决定是「个人本地注入」还是「对外分发改包」

---

## 6. 本地材料

插件源码：`research/BilibiliSponsorBlock`（上游 GPL-3.0 项目的本地克隆，未随本仓库分发）
- Windows 安装包 PE 头采样：`research/client/bili_win-head.bin`（4 MB）
- 官方下载页：https://app.bilibili.com/
- API 文档：https://github.com/hanydd/BilibiliSponsorBlock/wiki/API
- 第三方移植列表：https://github.com/hanydd/BilibiliSponsorBlock/wiki/3rd-Party-Ports
