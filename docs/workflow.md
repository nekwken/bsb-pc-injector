# 个人使用工作流（CDP 运行时注入）

当前方案**不修改官方 `app.asar`**：注入器通过 `--remote-debugging-port=9222` 连接到官方客户端，
把 `payload/` 里的脚本注进页面。官方客户端升级后无需重打包。

## 首次安装 / 环境准备

```powershell
cd E:\B站客户端内置插件

# 需要 Node 18+（打包/注入脚本都用它）
# winget install OpenJS.NodeJS.LTS

# 安装运行时模式：生成桌面快捷方式，不动官方 asar
powershell -ExecutionPolicy Bypass -File .\patch.ps1
# 自动定位失败时：
# .\patch.ps1 -InstallRoot "C:\Program Files\bilibili"
```

会生成两个桌面快捷方式：

| 快捷方式 | 作用 |
|----------|------|
| **BSB注入器** | 运行 `start-injector.ps1`，启动 CDP 注入器 |
| **哔哩哔哩-BSB** | 带 `--remote-debugging-port=9222` 启动官方客户端 |

## 每次使用（无感模式）

先做一次配置：

```powershell
powershell -ExecutionPolicy Bypass -File .\enable-seamless.ps1
# 建议用管理员身份再跑一次，才能改写 C:\ProgramData 下的系统级开始菜单快捷方式
```

它做三件事（都可以撤销，且**不改客户端文件**）：

1. 给所有客户端快捷方式就地加上 `--remote-debugging-port=9222 --remote-allow-origins=*`
   （桌面、开始菜单、任务栏固定项；卸载程序、必剪等其它 exe 会被跳过）
2. 注册登录自启：`HKCU\...\Run` → `wscript.exe runtime\bsb-injector-hidden.vbs`
   （用 wscript + 隐藏窗口启动，登录时不会闪控制台）
3. 立刻隐藏启动一次注入器

之后照旧打开哔哩哔哩即可。撤销：`.\enable-seamless.ps1 -Uninstall`。

## 主程序（托盘 + 设置窗口）

```powershell
# 直接运行（托盘 + 设置窗口）
.\bin\BSB.exe
# 只起托盘（登录自启用的形态）
.\bin\BSB.exe --tray
# 从源码重建（需要 .NET 8 SDK）
powershell -ExecutionPolicy Bypass -File .\build-apps.ps1
```

- **打开时先显示上次状态**：每次刷新成功都会把状态快照写到
  `%LOCALAPPDATA%\bsb-client-patcher\state-cache.json`，下次打开窗口先渲染它（秒开，
  状态栏显示「已显示上次缓存 · 正在刷新…」），约 2 秒后换成实时值。删掉这个文件只是让
  下次打开重新等一次。

- `apps\Installer\`：WPF 单文件 exe。窗口用 `DwmSetWindowAttribute(38, Mica)` +
  `DwmExtendFrameIntoClientArea(-1)` + `Background=Transparent` 得到真云母背景；
  系统不支持时回退到深色底。图标在运行时用 `DrawingVisual` 画（不打包位图资源）。
- `apps\Tray\`：WinForms 托盘 exe，私有用量约 11MB。
- 图标：`apps\Assets\bsb.ico` 由上游的 `IconSponsorBlocker256px.png` 生成（多尺寸），
  两个项目都用 `<ApplicationIcon>` 作为文件图标；安装器再用 WPF `Resource` 作窗口图标，
  托盘用 `EmbeddedResource LogicalName="bsb.ico"` 运行时读取（读不到就退回运行时画的 B 徽标）。
  改图标只需替换 `apps\Assets\bsb.ico` 后重跑 `build-apps.ps1`。
- **界面不实现业务逻辑**：所有状态和动作都调 `tools\InstallerActions.ps1`，
  和命令行、`status.ps1` 共用同一套代码路径，不会各自漂移。
- **界面不直连 CDP**：配置下发靠命令文件 —— 安装器写
  `%LOCALAPPDATA%sb-client-patcher\command.json`（`{id, cmd:"push-config", config}`），
  注入器在下一轮轮询里读到就写进各页面的 localStorage 并刷新，然后删掉文件。
  注入器另外每 10 秒把页面里生效的配置镜像到 `live-config.json`，安装器据此显示**真实生效值**。
- 提权：`Invoke-Elevated` 用 `Start-Process -Verb RunAs` 重新拉起自己，子进程把 JSON 写进
  临时文件由父进程读回；`-Paths` 的值显式加引号（`-ArgumentList` 数组按空格拼接且不加引号，
  `Start Menu` 这类路径会被拆开）。

## 托盘图标（与设置窗口同一个进程）

`bin\BSB.exe --tray` 是登录自启用的形态：只起托盘不开窗口（私有用量约 17MB）。
托盘菜单：状态、打开设置窗口、启动/重启/停止注入器、检查插件更新、打开日志/项目目录、退出。

- 双击 `bin\BSB.exe`（不带参数）= 托盘 + 设置窗口；关窗口只是隐藏，托盘菜单「退出」才结束进程。
- 再次双击不会开第二个进程，只会把已运行的窗口唤到前台（命名互斥体 + 命名事件）。
- 不想要托盘：`.\enable-seamless.ps1 -NoTray`（自启改为 `runtimesb-injector-hidden.vbs` 直接拉注入器）。

## 手动模式（排查用）

```powershell
# 前台注入器，带控制台输出
powershell -ExecutionPolicy Bypass -File .\start-injector.ps1
# 隐藏后台模式（等同登录自启时的行为，日志写文件）
powershell -ExecutionPolicy Bypass -File .\start-injector.ps1 -Background
```

再用桌面 **哔哩哔哩-BSB** 打开客户端。注入器日志：`%LOCALAPPDATA%\bsb-client-patcher\logs\injector.log`
（超过 1MB 自动轮转成 `.log.1`）。

## 官方客户端更新后

**什么都不用做**。运行时注入与 asar 无关；照旧点原来的图标即可。

若官方更新重建了快捷方式（丢掉调试端口），跑一次 `.\patch.ps1` 重新改写即可。
注意它默认**不再创建**「哔哩哔哩-BSB」专用图标（无感模式下不需要），需要旧图标时加 `-WithLaunchers`。

## 插件更新（含自动更新）

```powershell
# 检查更新（走更新源；退出码 10 = 有新版本）
powershell -ExecutionPolicy Bypass -File .\update-plugin.ps1 -Check

# 自动更新：有新版本就下载安装（托盘和安装器里都是这一个动作）
powershell -ExecutionPolicy Bypass -File .\update-plugin.ps1 -Auto

# 方式 A：用仓库内 payload 目录
powershell -ExecutionPolicy Bypass -File .\update-plugin.ps1 -PayloadDir .\payload -Force

# 方式 B：用打包好的 zip
powershell -ExecutionPolicy Bypass -File .\update-plugin.ps1 -ZipPath .\bsb-payload-x.y.z.zip -Force
```

- 更新源配置在 `%LOCALAPPDATA%\bsb-client-patcher\update.json`（`url` 指向一个含
  `manifest.json` 的目录或 zip，http(s) 或本地路径均可；也可用环境变量 `BSB_UPDATE_URL`）。
- **镜像回退**：主源是 GitHub raw 时会自动推导镜像（jsDelivr CDN → fastly → gcore → ghproxy），
  逐个尝试，任一成功即用（`update.json` 的 lastResult 会显示 via 来源）；404、超时、
  连接失败都会触发回退。还可以在 `update.json` 里加 `"mirrors": ["https://..."]`
  追加自定义镜像（排在自动推导之后）。
- 「自动检查」默认开启：托盘启动时会静默检查一次，有新版本会弹气泡，菜单里出现
  「发现新版本（点击自动更新）」。
- 安装后注入器自动热加载，正在播放的页面在下一次轮询时换成新版，**不需要重启客户端**。
  前提是 `manifest.json` 的 `version` 与 `payload/bsb-ui.js` 里的 `VERSION` 一起 +1；
  版本没变则页面继续跑已注入的那份（版本门控只升级、不降级；降级后刷新页面即可）。

## 还原官方状态

**没有「还原」这一步**——本项目从不修改官方客户端文件，停掉注入器就是原版：

```powershell
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'injector\.mjs' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

# 并移除登录自启 / 托盘
powershell -ExecutionPolicy Bypass -File .\enable-seamless.ps1 -Uninstall
```

## 插件包格式（payload）

```
payload/
  manifest.json           # name/version/文件清单/兼容性
  bsb-content.js          # 页面内 skip 引擎（识别 bvid+cid、查表、跳/静音）
  bsb-ui.js               # 播放页 UI（进度条色条、BSB 按钮、悬浮面板、空降提示）
  bsb-settings.js         # 官方设置页里的「空降助手」面板
  bsb-config.default.json # 默认配置
```

`manifest.json` 的 `version` 同时用于状态展示、注入器的 payload 选择与版本接管。

## 配置

运行时配置优先级：

1. 页面同域 `localStorage.bsb_config`（设置页写入）
2. `%LOCALAPPDATA%\bsb-client-patcher\bsb-config.json`
3. payload 内 `bsb-config.default.json`

常用项见 `payload/bsb-config.default.json`：`enabled`、`categories`、`apiBase`、`debug`。

## 故障排查

| 现象 | 处理 |
|------|------|
| 播放页出现**闪烁的蓝色 BSB 按钮** | 有**多个注入器**在同时跑：旧注入器注入的旧 UI 造按钮，新 UI 删按钮。跑一次 `.\start-injector.ps1`（它会先杀掉所有注入器），再完全退出客户端重开 |
| 面板关掉后自己又打开 / 按钮点一下没反应 | 旧版本 UI 残留的监听器在抢状态。已从 0.3.0 起改为**单实例自退役**（每个实例发现页面已被更新版本接管就停掉自己的定时器），并用事件委托绑定点击。若仍复现：重启注入器，并把 `payload/` 版本号 +1（页面里跑的是老代码时才会出现） |
| 面板里的类别改完没生效 | 类别开关是**暂存**的，点面板底部 **保存更改** 才写入；保存成功时标题栏右侧显示「已保存 ✓」并自动按新类别重新查询（状态文字放在标题栏，底部按钮位置不会随文字长短变动） |
| 完全没反应 | `.\status.ps1` 看注入器是否在跑、9222 是否 open、各快捷方式是否带调试端口；确认不是从**未改写的系统级开始菜单**启动的（用管理员跑一次 `enable-seamless.ps1`） |
| 进度条没有色条 | 该视频在 `bsbsb.top` 上确实没有片段（面板里会显示「当前视频暂无片段」）；若片段数 > 0 但条不见了，说明播放器刚重建了进度条，观察器会在 1 秒内补回 |
| 设置页没有「空降助手」 | 设置页刷新一次；或重启注入器后再进设置 |
| 找不到 BSB 按钮 | 按钮在控制栏里、分辨率控件左侧，跟着控制栏显隐 —— 鼠标移到画面上，控制栏出现就能看到。按钮**只在识别到视频的页面**出现（首页/动态/设置等页面本来就没有） |
| 悬浮面板在非播放页出现 / 没点它自己冒出来 | 0.4.8 起已修：面板与按钮都以「当前页面识别到 BV 号」为前提，离开视频页或换视频时面板自动关闭。若仍复现，用安装器「总览 → 已打开的页面」确认页面的 `ui` 版本是最新的 |
| 客户端自己更新后 | 快捷方式可能被重建、丢失调试端口：再跑一次 `.\patch.ps1`（会重新改写快捷方式并确保自启存在） |
| 安装器打不开 / 界面空白 | 需要 .NET 8 Desktop 运行时；用 `.\build-apps.ps1` 重建，或先跑 `dotnet --list-runtimes` 确认有 `Microsoft.WindowsDesktop.App 8.x` |
| 云母背景没生效 | 只有 Win11 22H2+ 支持；老系统会自动退回深色底，功能不受影响 |
| 设置页里「空降助手」不见了 | 0.4.3 起已修：设置页重新渲染后由 800ms 维护 ticker 自动补挂，并会在打开设置页时自动显示一次。若仍不见，看安装器「总览 → 实时页面」里主界面的 `settings` 版本是否为最新 |
| 页面刷新后插件消失 | 0.4.3 起已修：注入器改为**每轮直接问页面**（不再用「这个 target 注入过」的本地表，那张表在页面刷新后不会失效，导致漏注入） |
| Node/asar 报错 | 安装 Node LTS；或设置 `MIMO_NODE` |
| 找不到客户端 | `.\patch.ps1 -InstallRoot <路径>`（目录下应有 `resources\app.asar`） |

排查注入器进程（只看不带 `.mjs` 的启动 shell，会误伤）：

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'injector\.mjs' } |
  Select-Object ProcessId, Name, CommandLine
```

正常应该**只有一条**记录。

## 机制说明：为什么强调「只能有一个注入器」

- 页面拿到的是**第一份到达的脚本**；两个注入器同时存在时，各自按自己内存里的 payload 版本注入，
  就会出现「旧 UI 建节点 / 新 UI 删节点」的对撞 —— 表现就是按钮一闪一闪、面板打不开。
- 因此：
  - `start-injector.ps1` 启动前会按**命令行**（不是进程名，注入器可能跑在宿主 App 自带的 node 里）
    杀掉所有其他注入器；
  - `runtime/injector.mjs` 启动时也会做同样的自查自清（`BSB_NO_KILL=1` 可关闭）；
  - `bsb-content.js` / `bsb-ui.js` / `bsb-settings.js` 都带版本号，页面里已有更旧版本时由新版本接管：
    旧实例的定时器会**自己停掉**（发现 `window.__bsbUI.version` 不是自己就退出），
    样式表、按钮、面板、提示条都按版本号重新绑定事件，避免旧监听器继续生效。

## 两个实现约束（改 UI 前先看）

1. **不要靠定时器维持 UI。** 播放页窗口被遮挡时 `document.visibilityState === "hidden"`，
   Chromium 会把定时器限流到约 1 次/秒，400ms 的 ticker 基本不再触发。
   按钮的补挂靠 `MutationObserver`（监听控制栏重绘）完成，timer 只是兜底。
2. **观察者回调里不要同步改 DOM。** `MutationObserver` 回调中改 DOM 会重新排队，形成
   live-lock 把渲染进程卡死（表现为整个窗口点不动、CDP 也连不上）。补挂动作一律走
   `setTimeout(…, 120)` 合并后再执行。

## 边界说明

- 本工具**只服务个人本机**，不重分发官方安装包。
- 官方播放器若改为非 DOM 原生控件，`bsb-content.js` 的识别逻辑可能失效，需要改探测方式。
- BSB 数据协议来自 [hanydd/BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)（GPL-3.0）。
- 跳过恰饭片段可能与平台商业化冲突；请自行评估使用风险。
