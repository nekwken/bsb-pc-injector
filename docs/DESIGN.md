# 架构说明

## 目标与约束

1. **不改官方客户端**：不碰 `app.asar`（改过会因完整性校验卡在启动页），官方更新后不需要重打补丁。
2. **无感**：用户照旧点原来的图标；注入器在后台自己活着。
3. **同一时间只能有一个注入器**：两个注入器各自按自己内存里的 payload 注入，会出现
   「旧 UI 建节点 / 新 UI 删节点」的对撞（表现为按钮闪烁、面板打不开）。
4. **热更新**：改 `payload/` 后，正在播放的页面要能自己换成新代码。

## 组件

```
哔哩哔哩.exe (官方 Electron)                 runtime/injector.mjs (Node)
  ├─ index.html      ◄──┐                       │
  └─ player.html     ◄──┤── CDP (9222) ─────────┤  轮询 /json/list
                        │                       │  注入 payload 三层
   payload/bsb-content.js   跳片段引擎           │
   payload/bsb-ui.js        播放页 UI           │  命令文件：command.json
   payload/bsb-settings.js  官方设置页面板       │  状态镜像：live-config.json
                                               │
   apps/Installer (WPF)  ──┐                   │
   apps/Tray     (WinForms)┴─► tools/InstallerActions.ps1（唯一后端）
```

## 注入器

- **轮询**：默认 1.5s；这一轮里有页面需要注入时降到 300ms。
- **不做「注入过就跳过」的本地表**：每轮直接问页面（比较页面里的版本号）。
  页面刷新后 target id 不变，本地表会让刷新过的页面永远被跳过。
- **版本门控**：注入的表达式比较 `__BSB_CONTENT_VERSION__` / `window.__bsbUI.version` /
  `__BSB_SETTINGS_VERSION__`，页面里是旧版本才重跑；否则返回 `already`（几乎零开销）。
- **单实例**：启动时按命令行里的 `injector.mjs` 杀掉其它注入器（**不能按进程名过滤**，
  注入器可能跑在宿主进程名下），并排除启动用的 shell。
- **热更新**：payload 文件签名（版本 + 大小 + mtime）变了就重载，下一次轮询生效。
- **命令文件**：安装器不直连 CDP，它写 `command.json`（`{id, cmd:"push-config", config}`），
  注入器执行后删除文件。这样安装器不需要实现 CDP 客户端。
- **状态镜像**：每 10s 把页面里生效的配置（`localStorage.bsb_config`）写进 `live-config.json`，
  安装器据此显示**真实生效值**而不是文件里的旧值。

## payload 三层

| 文件 | 职责 | 版本全局 |
|------|------|----------|
| `bsb-content.js` | 解析 URL 里的 bvid/cid、查 `bsbsb.top`、改 `video.currentTime` / `muted` | `__BSB_CONTENT_VERSION__` |
| `bsb-ui.js` | 进度条色条、控制栏按钮、悬浮面板、空降提示 | `window.__bsbUI.version` |
| `bsb-settings.js` | 官方设置页里的「空降助手」面板 | `__BSB_SETTINGS_VERSION__` |

跨版本复用的 DOM 节点（面板、按钮）会让旧实例的事件监听器残留，所以：

- 点击走**事件委托**，只交给当前版本的实例；
- 每个实例的维护定时器把 id 存在闭包常量里，发现自己不是当前版本就**只停自己**的
  （早期写成 `clearInterval(window.__bsbUIInterval)`，那个全局可能已被新实例占用，
  结果旧实例退休时把新实例的定时器杀了，页面从此没人维护）。

## 三条硬约束（改 UI 前必读）

1. **不要靠定时器维持 UI**：播放页窗口被遮挡时 `visibilityState === "hidden"`，
   Chromium 把定时器限流到约 1 次/秒。按钮/色条补挂必须用 `MutationObserver`。
2. **观察器回调里不要同步改 DOM**：会重新排队形成 live-lock，把渲染进程卡死
   （窗口点不动、CDP 30s 超时）。补挂动作统一 `setTimeout(…, 120)` 合并后执行，
   并且「已放置」判断要和插入用的父节点一致，否则每次回调都会重插。
3. **内容脚本的防护不要误伤自己**：早期为了对抗旧注入器，内容脚本按 class 拦截所有
   `bsb-ctrl-btn` 节点 —— 这会连自己的按钮一起拦。现在只清理「有 class 没 id」的外来节点，
   插入也改走旧版本从未包装过的 `anchor.before()` / `parent.prepend()`。

## 配置

优先级（后者覆盖前者）：

```
payload/bsb-config.default.json  <  %LOCALAPPDATA%\bsb-client-patcher\bsb-config.json  <  页面 localStorage
```

- 播放页面板与官方设置页写 `localStorage`；安装器保存时**两边都写**并即时下发到页面。
- 安装器读取时以**页面**为准（否则会显示旧值，保存时还会把面板里的改动覆盖掉）。

## 启动入口与提权

- 快捷方式（桌面 / 开始菜单 / 任务栏固定）**就地**加上
  `--remote-debugging-port=9222 --remote-allow-origins=*`，图标和名字不变。
- `C:\ProgramData` 下的系统级快捷方式需要管理员：后端用
  `Start-Process -Verb RunAs` 重新拉起自己，子进程把 JSON 结果写进临时文件由父进程读回，
  所以界面拿到的返回结构和非提权时一样。
  转发 `-Paths` 时必须显式加引号：`Start-Process -ArgumentList` 把数组按空格拼接且不加引号，
  `Start Menu` 这类路径会被拆成两个参数。
- 登录自启：`HKCU\Run` → `bin\BSB托盘.exe`（托盘自己再把注入器拉起来）；
  没构建 exe 时退回 `wscript.exe runtime\bsb-injector-hidden.vbs`。

## 演进史（为什么是现在这样）

| 阶段 | 做法 | 结果 |
|------|------|------|
| 一 | 改 `app.asar`：替换入口 `index.js`、注入 preload/hooks | 客户端卡在启动页（完整性校验），**废弃** |
| 二 | CDP 运行时注入 + 专用「哔哩哔哩-BSB」图标 | 可用，但每次要记得用那个图标、还要先起注入器 |
| 三 | 快捷方式就地带调试端口 + 登录隐藏自启 + 托盘 | 现在的形态：照旧点原图标即可 |
| 四 | 原生安装器 / 托盘（替换 Node 服务 + 网页 UI + PowerShell 托盘） | 无浏览器、无常驻服务，托盘私有用量约 11MB |

`payload/bootstrap-lite.js`、`bsb-hooks.js`、`bsb-preload.js` 是阶段一的遗留文件，
内容已清空，仅保留文件名供从旧版本升级的用户对照排查。
