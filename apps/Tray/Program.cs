// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// BSB 托盘 — 空降助手托盘图标（原生，低占用）
//
// 只做三件事：显示状态、启停注入器、打开安装器/日志。
// 状态与操作都交给 tools\InstallerActions.ps1（唯一的事实来源），
// 这样托盘、安装器、命令行脚本不会各自实现一套逻辑。

using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Text;
using System.Text.Json;
using System.Windows.Forms;

namespace BsbTray;

internal static class Program
{
    private const string MutexName = "Local\\BSBTrayIcon";

    private static string _root;
    private static NotifyIcon _icon;
    private static ToolStripMenuItem _statusItem;
    private static ToolStripMenuItem _startItem;
    private static ToolStripMenuItem _restartItem;
    private static ToolStripMenuItem _stopItem;
    private static bool _busy;

    [STAThread]
    private static void Main()
    {
        using var mutex = new Mutex(false, MutexName, out bool isNew);
        if (!isNew) return;   // 已经有一个托盘在跑

        _root = AppContext.BaseDirectory.TrimEnd('\\');
        // bin\ 在项目下，往上找到项目根（含 tools\InstallerActions.ps1 的那层）
        while (_root.Length > 3 && !File.Exists(Path.Combine(_root, "tools", "InstallerActions.ps1")))
        {
            var parent = Path.GetDirectoryName(_root);
            if (string.IsNullOrEmpty(parent)) break;
            _root = parent;
        }

        ApplicationConfiguration.Initialize();

        var menu = new ContextMenuStrip { ShowImageMargin = false };
        _statusItem = new ToolStripMenuItem("状态：读取中…") { Enabled = false };
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());

        var installerItem = new ToolStripMenuItem("打开安装器");
        _startItem = new ToolStripMenuItem("启动注入器");
        _restartItem = new ToolStripMenuItem("重启注入器");
        _stopItem = new ToolStripMenuItem("停止注入器");
        menu.Items.Add(installerItem);
        menu.Items.Add(_startItem);
        menu.Items.Add(_restartItem);
        menu.Items.Add(_stopItem);
        menu.Items.Add(new ToolStripSeparator());

        var logItem = new ToolStripMenuItem("打开日志");
        var projectItem = new ToolStripMenuItem("打开项目目录");
        menu.Items.Add(logItem);
        menu.Items.Add(projectItem);
        menu.Items.Add(new ToolStripSeparator());

        var exitItem = new ToolStripMenuItem("退出托盘图标");
        menu.Items.Add(exitItem);

        installerItem.Click += (_, _) => OpenInstaller();
        _startItem.Click += (_, _) => Run("injector-start");
        _restartItem.Click += (_, _) => { Run("injector-stop"); Run("injector-start"); };
        _stopItem.Click += (_, _) => Run("injector-stop");
        logItem.Click += (_, _) => OpenPath("logs");
        projectItem.Click += (_, _) => OpenPath("project");
        exitItem.Click += (_, _) => { _icon.Visible = false; Application.Exit(); };

        menu.Opening += (_, _) => RefreshStatus();

        _icon = new NotifyIcon
        {
            Icon = LoadIcon(),
            Text = "空降助手",
            Visible = true,
            ContextMenuStrip = menu
        };
        _icon.DoubleClick += (_, _) => OpenInstaller();

        // 登录自启时也把注入器拉起来（托盘是常驻的，交给它最省事）
        if (!InjectorRunning()) Run("injector-start", quiet: true);
        RefreshStatus();

        Application.Run();
        _icon.Dispose();
    }

    // ---------------------------------------------------------------- 状态

    private static bool InjectorRunning()
    {
        try
        {
            var state = Call("get-state", 8000);
            return state != null && state.Value.TryGetProperty("injector", out var inj)
                && inj.GetProperty("count").GetInt32() > 0;
        }
        catch { return false; }
    }

    private static void RefreshStatus()
    {
        _statusItem.Text = "状态：读取中…";
        var portOpen = PortOpen(9222);
        var state = Call("get-state", 8000);
        bool running = false;
        if (state != null && state.Value.TryGetProperty("injector", out var inj))
            running = inj.GetProperty("count").GetInt32() > 0;

        _statusItem.Text = running
            ? (portOpen ? "状态：注入器运行中 · 客户端已连接" : "状态：注入器运行中 · 等待客户端")
            : "状态：注入器已停止";
        _icon.Text = "空降助手 · " + _statusItem.Text.Substring(3);
        _startItem.Enabled = !running && !_busy;
        _restartItem.Enabled = running && !_busy;
        _stopItem.Enabled = running && !_busy;
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

    private static void Run(string action, bool quiet = false)
    {
        if (_busy) return;
        _busy = true;
        try
        {
            Call(action, 20000);
            Thread.Sleep(action == "injector-start" ? 2000 : 500);
            RefreshStatus();
        }
        finally { _busy = false; }
        if (!quiet) RefreshStatus();
    }

    private static void OpenInstaller()
    {
        var exe = Path.Combine(_root, "bin", "BSB安装器.exe");
        if (File.Exists(exe))
            Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true, WorkingDirectory = _root });
        else
            Process.Start(new ProcessStartInfo(Path.Combine(_root, "打开安装器.cmd")) { UseShellExecute = true });
    }

    private static void OpenPath(string which)
    {
        var p = which == "logs"
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "bsb-client-patcher", "logs")
            : _root;
        if (Directory.Exists(p))
            Process.Start(new ProcessStartInfo("explorer.exe", "\"" + p + "\"") { UseShellExecute = true });
    }

    /// <summary>调用 PowerShell 后端并解析它输出的 JSON。</summary>
    private static JsonElement? Call(string action, int timeoutMs)
    {
        var script = Path.Combine(_root, "tools", "InstallerActions.ps1");
        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = _root
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(script);
        psi.ArgumentList.Add("-Action");
        psi.ArgumentList.Add(action);

        using var proc = Process.Start(psi);
        var stdout = proc.StandardOutput.ReadToEnd();
        proc.StandardError.ReadToEnd();
        if (!proc.WaitForExit(timeoutMs)) { try { proc.Kill(); } catch { } return null; }

        var start = stdout.IndexOf('{');
        if (start < 0) return null;
        try { return JsonDocument.Parse(stdout.Substring(start)).RootElement.Clone(); }
        catch { return null; }
    }

    // ---------------------------------------------------------------- 图标

    /// <summary>上游插件自带的图标（编译时内嵌）；取不到时退回运行时画一个。</summary>
    private static Icon LoadIcon()
    {
        try
        {
            using var stream = typeof(Program).Assembly.GetManifestResourceStream("bsb.ico");
            if (stream != null) return new Icon(stream, SystemInformation.SmallIconSize);
        }
        catch { }
        return BuildIcon();
    }

    private static Icon BuildIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var brush = new SolidBrush(Color.FromArgb(255, 0, 161, 214));
            g.FillEllipse(brush, 1, 1, 30, 30);
            using var font = new Font("Segoe UI", 15, FontStyle.Bold, GraphicsUnit.Pixel);
            using var fmt = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            g.DrawString("B", font, Brushes.White, new RectangleF(0, 1, 32, 32), fmt);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}
