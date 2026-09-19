// LEGACY — 早期「改 asar」方案的 preload 桥，运行时注入模式不使用。
//
// 该方案需要改官方 app.asar，实测会让客户端卡在启动页，已废弃。
// 现在页面脚本由 runtime/injector.mjs 通过 CDP 直接注入（见 docs/DESIGN.md），不需要 preload。
//
// 保留文件名是为了让从旧版本升级的用户能对照排查；内容已清空，请勿引用。
