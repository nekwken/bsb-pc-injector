# 研究与参考资料（已收拢）

| 路径 | 说明 |
|------|------|
| `BilibiliSponsorBlock/` | 上游插件源码 clone（GPL-3.0） |
| `client/` | 官方 Windows 安装包解包样本（约 0.8GB+） |
| `先期研究-BSB入官方电脑客户端.md` | 第一阶段调研 |
| `改官方包-Windows客户端摸底与注入方案.md` | 官方包结构/注入方案 |
| `_archive-work-patcher/` | 旧 work 目录遗留日志/临时文件 |

正式脚本与插件包在项目根目录：`payload/` `runtime/` `tools/` `*.ps1`。

运行时状态不在本目录：`%LOCALAPPDATA%\bsb-client-patcher\`（备份、配置、日志、payload 副本）。
