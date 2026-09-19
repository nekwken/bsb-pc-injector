// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
//
// Tray.cs — 托盘图标（WinForms NotifyIcon 跑在 WPF 的 dispatcher 线程上）。
// 与设置窗口同进程：菜单里的「打开设置窗口」直接显示窗口，不再另起进程。
//
// 注意：后端调用一律 await，绝不在 UI 线程上 .Result/.GetResult() 阻塞——
// WPF 线程上 sync-over-async 会死锁（continuation 排回被阻塞的 dispatcher）。

using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows.Forms;
using Application = System.Windows.Application;

namespace BsbApp;

internal static class Tray
{
    private static NotifyIcon _icon;
    private static ToolStripMenuItem _statusItem;
    private static ToolStripMenuItem _updateItem;
    private static ToolStripMenuItem _checkItem;
    private static ToolStripMenuItem _startItem;
    private static ToolStripMenuItem _restartItem;
    private static ToolStripMenuItem _stopItem;
    private static bool _busy;

    public static void Start()
    {
        var menu = new ContextMenuStrip { ShowImageMargin = false };

        _statusItem = new ToolStripMenuItem("状态：读取中…") { Enabled = false };
        _updateItem = new ToolStripMenuItem("发现新版本（点击自动更新）") { Visible = false };
        _checkItem = new ToolStripMenuItem("检查插件更新");
        menu.Items.Add(_statusItem);
        menu.Items.Add(_updateItem);
        menu.Items.Add(_checkItem);
        menu.Items.Add(new ToolStripSeparator());

        var windowItem = new ToolStripMenuItem("打开设置窗口");
        _startItem = new ToolStripMenuItem("启动注入器");
        _restartItem = new ToolStripMenuItem("重启注入器");
        _stopItem = new ToolStripMenuItem("停止注入器");
        menu.Items.Add(windowItem);
        menu.Items.Add(_startItem);
        menu.Items.Add(_restartItem);
        menu.Items.Add(_stopItem);
        menu.Items.Add(new ToolStripSeparator());

        var logItem = new ToolStripMenuItem("打开日志");
        var projectItem = new ToolStripMenuItem("打开项目目录");
        menu.Items.Add(logItem);
        menu.Items.Add(projectItem);
        menu.Items.Add(new ToolStripSeparator());

        var exitItem = new ToolStripMenuItem("退出");
        menu.Items.Add(exitItem);

        windowItem.Click += (_, _) => App.ShowMainWindow();
        _startItem.Click += async (_, _) => await RunAsync("injector-start");
        _restartItem.Click += async (_, _) => { await RunAsync("injector-stop"); await RunAsync("injector-start"); };
        _stopItem.Click += async (_, _) => await RunAsync("injector-stop");
        logItem.Click += (_, _) => OpenPath("logs");
        projectItem.Click += (_, _) => OpenPath("project");
        exitItem.Click += (_, _) => { if (_icon != null) _icon.Visible = false; Program.Shutdown(); };

        _updateItem.Click += async (_, _) =>
        {
            _updateItem.Text = "正在更新…";
            await RunAsync("plugin-auto");
            _updateItem.Visible = false;
            await RefreshStatusAsync();
        };
        _checkItem.Click += async (_, _) =>
        {
            _checkItem.Enabled = false;
            var has = await CheckForUpdateAsync(showBalloon: true);
            _checkItem.Enabled = true;
            ShowUpdateItem(has);
        };

        menu.Opening += async (_, _) => await RefreshStatusAsync();

        _icon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "空降助手",
            Visible = true,
            ContextMenuStrip = menu
        };
        _icon.DoubleClick += (_, _) => App.ShowMainWindow();

        // 启动后的初始化放到后台，别拖住主窗口显示
        _ = Task.Run(async () =>
        {
            if (!await InjectorRunningAsync()) await RunAsync("injector-start");
            await RefreshStatusAsync();
            if (AutoCheckEnabled())
            {
                var has = await CheckForUpdateAsync(showBalloon: true);
                OnUi(() => ShowUpdateItem(has));
            }
        });
    }

    // ---------------------------------------------------------------- 状态

    private static void OnUi(Action action)
    {
        try
        {
            var app = Application.Current;
            if (app?.Dispatcher != null) app.Dispatcher.BeginInvoke(action);
            else action();
        }
        catch { action(); }
    }

    private static async Task<bool> InjectorRunningAsync()
    {
        var state = await Backend.CallAsync("get-state", null, 15000);
        return state != null && state.Value.TryGetProperty("injector", out var inj)
            && inj.GetProperty("count").GetInt32() > 0;
    }

    private static async Task RefreshStatusAsync()
    {
        if (_statusItem == null) return;
        OnUi(() => _statusItem.Text = "状态：读取中…");
        var portOpen = PortOpen(9222);
        var running = await InjectorRunningAsync();

        OnUi(() =>
        {
            _statusItem.Text = running
                ? (portOpen ? "状态：注入器运行中 · 客户端已连接" : "状态：注入器运行中 · 等待客户端")
                : "状态：注入器已停止";
            if (_icon != null) _icon.Text = "空降助手 · " + _statusItem.Text.Substring(3);
            _startItem.Enabled = !running && !_busy;
            _restartItem.Enabled = running && !_busy;
            _stopItem.Enabled = running && !_busy;
        });
    }

    private static bool PortOpen(int port)
    {
        try
        {
            using var c = new System.Net.Sockets.TcpClient();
            return c.ConnectAsync("127.0.0.1", port).Wait(400);
        }
        catch { return false; }
    }

    // ---------------------------------------------------------------- 动作

    private static async Task RunAsync(string action)
    {
        if (_busy) return;
        _busy = true;
        try
        {
            await Backend.CallAsync(action, null, 30000);
            if (action == "injector-start") await Task.Delay(2000);
        }
        catch { }
        finally { _busy = false; }
        await RefreshStatusAsync();
    }

    private static void OpenPath(string which)
    {
        var p = which == "logs"
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "bsb-client-patcher", "logs")
            : Backend.Root;
        if (Directory.Exists(p))
            Process.Start(new ProcessStartInfo("explorer.exe", "\"" + p + "\"") { UseShellExecute = true });
    }

    // ---------------------------------------------------------------- 更新

    private static bool AutoCheckEnabled()
    {
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "bsb-client-patcher", "update.json");
            if (!File.Exists(path)) return true;
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.TryGetProperty("autoCheck", out var v))
                return v.ValueKind == JsonValueKind.True;
            return true;
        }
        catch { return true; }
    }

    private static async Task<bool> CheckForUpdateAsync(bool showBalloon)
    {
        try
        {
            var state = await Backend.CallAsync("plugin-check", null, 90000);
            if (state == null || !state.Value.TryGetProperty("hasUpdate", out var has)) return false;
            if (has.ValueKind != JsonValueKind.True) return false;
            var latest = "";
            if (state.Value.TryGetProperty("info", out var info) && info.TryGetProperty("latest", out var lv))
                latest = lv.ValueKind == JsonValueKind.String ? lv.GetString() : lv.ToString();
            if (showBalloon)
            {
                OnUi(() =>
                {
                    try { _icon?.ShowBalloonTip(6000, "空降助手", "插件有新版本 v" + latest + "，右键托盘可自动更新", ToolTipIcon.Info); } catch { }
                });
            }
            return true;
        }
        catch { return false; }
    }

    private static void ShowUpdateItem(bool has)
    {
        if (_updateItem == null) return;
        if (!has) { _updateItem.Visible = false; return; }
        var latest = "";
        try
        {
            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "bsb-client-patcher", "update.json");
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (doc.RootElement.TryGetProperty("latestVersion", out var v))
                latest = v.ValueKind == JsonValueKind.String ? v.GetString() : v.ToString();
        }
        catch { }
        _updateItem.Text = string.IsNullOrEmpty(latest)
            ? "发现新版本（点击自动更新）"
            : "发现新版本 v" + latest + "（点击自动更新）";
        _updateItem.Visible = true;
    }

    // ---------------------------------------------------------------- 图标

    /// <summary>上游插件自带的图标（编译进资源）；取不到时退回运行时画一个。</summary>
    private static System.Drawing.Icon LoadIcon()
    {
        try
        {
            var uri = new Uri("pack://application:,,,/Assets/bsb.ico");
            using var stream = Application.GetResourceStream(uri)?.Stream;
            if (stream != null) return new System.Drawing.Icon(stream, SystemInformation.SmallIconSize);
        }
        catch { }
        return BuildIcon();
    }

    private static System.Drawing.Icon BuildIcon()
    {
        using var bmp = new System.Drawing.Bitmap(32, 32);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(System.Drawing.Color.Transparent);
            using var brush = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(255, 0, 161, 214));
            g.FillEllipse(brush, 1, 1, 30, 30);
            using var font = new System.Drawing.Font("Segoe UI", 15, System.Drawing.FontStyle.Bold, System.Drawing.GraphicsUnit.Pixel);
            using var fmt = new System.Drawing.StringFormat { Alignment = System.Drawing.StringAlignment.Center, LineAlignment = System.Drawing.StringAlignment.Center };
            g.DrawString("B", font, System.Drawing.Brushes.White, new System.Drawing.RectangleF(0, 1, 32, 32), fmt);
        }
        return System.Drawing.Icon.FromHandle(bmp.GetHicon());
    }
}
