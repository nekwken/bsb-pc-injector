# NOTICE / 第三方来源与修改说明

本项目是 [BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)（「小电视空降助手」，
GPL-3.0）在 **哔哩哔哩官方 Windows 客户端**上的移植与运行方式实现。

## 上游来源

| 内容 | 来源 | 许可 |
|------|------|------|
| 跳片段的协议与引擎思路、类别定义、`bsbsb.top` 接口用法 | [hanydd/BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock) | GPL-3.0 |
| `payload/bsb-content.js`、`payload/bsb-ui.js`、`payload/bsb-settings.js` | 由上游扩展的 content/UI 逻辑改写而来（去掉 `chrome.*`，改走 CDP 注入） | GPL-3.0 |
| `apps/Assets/bsb.ico` | 上游 `public/icons/IconSponsorBlocker*.png`（盾牌图标） | GPL-3.0 |

上游版权归其作者与贡献者所有。本仓库不包含上游源码副本，需要时请自行 clone。

## 本项目的修改（GPL-3.0 §5a 要求声明）

相对上游扩展，本项目做了以下改动：

1. **运行方式**：不再作为浏览器扩展运行，改为通过 CDP（`--remote-debugging-port`）
   注入官方 Electron 客户端的页面；删除全部 `chrome.*` 扩展 API 依赖。
2. **页面适配**：`bvid`/`cid` 从播放页 URL 解析（官方客户端没有 `window.__INITIAL_STATE__`）；
   UI 从扩展弹窗改为播放器控制栏按钮 + 悬浮面板 + 官方设置页内嵌面板。
3. **配置**：从 `chrome.storage` 改为 `localStorage` + `%LOCALAPPDATA%` 下的 JSON 文件。
4. **新增**（上游没有的部分）：注入器、安装器/托盘两个原生应用、安装与适配脚本。

## 本项目不包含

- 哔哩哔哩官方客户端的任何二进制、安装包或解包产物（`research/client/` 仅存在于开发者本机，
  已在 `.gitignore` 中排除）。
- 任何账号凭据、Cookie 或用户数据。

## 许可

本项目整体以 **GPL-3.0** 发布，见 `LICENSE`。因为它是上游 GPL-3.0 作品的衍生作品，
分发时必须同样以 GPL-3.0 提供源码。
