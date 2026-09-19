# 发布检查清单

给「准备把本仓库公开」时用的清单。做完这些再 push。

## 1. 绝对不能进仓库的内容（已在 `.gitignore`）

| 路径 | 为什么 |
|------|--------|
| `research/client/` | 官方客户端安装包与解包产物 —— **哔哩哔哩的专有代码**，分发即侵权 |
| `research/_archive-work-patcher/` | 早期调试日志，含本机路径 |
| `research/BilibiliSponsorBlock/` | 上游 GPL 项目的完整 clone，3.8MB；让使用者自己 clone，不要 vendoring |
| `bin/`、`apps/*/obj|bin` | 构建产物（exe 走 Releases，不进 git 历史） |
| `我想将这个插件*.md` | 个人聊天记录导出，含本机路径与对话内容 |

发布前确认：

```powershell
git status --porcelain | Select-String "research/client|_archive|BilibiliSponsorBlock|^.. bin/"   # 应为空
git grep -n "Users\\\\"                                                                          # 只应出现在文档示例里
```

## 2. 授权与合规

- [x] `LICENSE` —— GPL-3.0 全文（衍生自上游 GPL-3.0 作品，必须同许可分发）
- [x] `NOTICE.md` —— 上游来源、图标来源、以及 GPL-3.0 §5a 要求的**修改说明**
- [x] 源码文件头带 `SPDX-License-Identifier: GPL-3.0-or-later`
- [ ] 如果你想署真名/ID，替换掉各文件头的 `BSB PC client injector contributors`

## 3. 仓库元信息（GitHub 上填）

- 名称建议：`bilibili-pc-sponsorblock` / `bsb-pc-injector`
- 描述：`在官方哔哩哔哩 PC 客户端里使用 SponsorBlock（空降助手）：CDP 运行时注入，不改客户端文件`
- Topics：`bilibili` `sponsorblock` `electron` `cdp` `windows` `gpl-3-0`
- Releases：附上 `bin/BSB安装器.exe`、`bin/BSB托盘.exe`（从 `build-apps.ps1` 产出），
  说明里写清「需要 .NET 8 Desktop 运行时」
- 建议关闭 Issues 里的空模板，或加一个 `config.yml` 引导先看 `docs/workflow.md`

## 4. 发布前自查

- [ ] `README.md` 里的截图路径存在（`docs/images/installer.png`）
- [ ] 全新克隆跑一遍：`build-apps.ps1` → `enable-seamless.ps1` → 打开客户端 → 播放视频有片段
- [ ] `status.ps1` 输出正常
- [ ] 没有硬编码的个人路径：`git grep -n "C:\\\\Users\\\\"` 只应出现在文档的示例里
- [ ] 免责声明在位（README 末尾）：非官方、可能违反 ToS、风险自负、不修改客户端

## 5. 还可以补的东西（可选）

- 播放页 UI 的截图（按钮 / 色条 / 悬浮面板）—— 需要在播放有片段的视频时截取播放器窗口
- 英文 README（`README.en.md`），方便非中文用户
- GitHub Actions：只做 `dotnet build` + PowerShell 语法检查（`Parser::ParseFile`），
  不需要 Windows 客户端也能跑
- 一个 `CHANGELOG.md`（本项目 payload 版本从 0.1.x 到 0.4.x 的演进其实挺有故事）

## 6. 不要做的事

- 不要把官方客户端安装包、解包产物、`app.asar` 放进仓库或 Release
- 不要在仓库里放账号 Cookie / 抓包数据
- 不要提供「改包安装器」——本项目刻意只做运行时注入，改官方包会破坏其完整性校验并卡启动页
