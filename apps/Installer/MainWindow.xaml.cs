// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// 空降助手安装器：Mica 背景 + 四个页面，所有实际操作都转发给 PowerShell 后端。

using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Globalization;
using Ellipse = System.Windows.Shapes.Ellipse;

namespace BsbInstaller;

public partial class MainWindow : Window
{
    private static readonly (string Key, string Label, string Color)[] Categories =
    {
        ("sponsor", "广告", "#00d400"),
        ("selfpromo", "无偿推广", "#ffff00"),
        ("interaction", "三连提醒", "#cc00ff"),
        ("intro", "开场动画", "#00ffff"),
        ("outro", "片尾鸣谢", "#0000ff"),
        ("preview", "预告回顾", "#008000"),
        ("filler", "离题闲聊", "#7300ff"),
        ("music_offtopic", "非音乐部分", "#ff9900"),
        ("poi_highlight", "精彩时刻", "#ff1684"),
        ("padding", "填充片段", "#c0c0c0")
    };

    private static readonly (string Key, string Label)[] Actions =
    {
        ("skip", "跳过"),
        ("mute", "静音"),
        ("full", "整段标签"),
        ("poi", "高光")
    };

    private readonly Dictionary<string, CheckBox> _catBoxes = new();
    private bool _updatingAutoToggle;   // 程序性赋值时不回写 update.json
    private readonly Dictionary<string, CheckBox> _actionBoxes = new();
    private readonly List<(CheckBox Box, string Path)> _shortcutBoxes = new();
    private JsonElement _state;
    private bool _busy;

    // ------------------------------------------------------------ Mica 背景

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("dwmapi.dll")]
    private static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref Margins margins);

    [StructLayout(LayoutKind.Sequential)]
    private struct Margins { public int Left, Right, Top, Bottom; }

    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaSystemBackdropType = 38;
    private const int DwmsbtMainWindow = 2;   // Mica

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var hwnd = new WindowInteropHelper(this).Handle;
        var dark = 1;
        DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref dark, sizeof(int));
        var backdrop = DwmsbtMainWindow;
        var ok = DwmSetWindowAttribute(hwnd, DwmwaSystemBackdropType, ref backdrop, sizeof(int));
        var margins = new Margins { Left = -1, Right = -1, Top = -1, Bottom = -1 };
        DwmExtendFrameIntoClientArea(hwnd, ref margins);
        if (ok != 0)
        {
            // 老系统没有 Mica：给一个接近的深色底，界面仍然可用
            Background = new SolidColorBrush(Color.FromRgb(0x1B, 0x1D, 0x24));
        }
    }

    // ---------------------------------------------------------------- 初始化

    public MainWindow()
    {
        InitializeComponent();
        Icon = LoadWindowIcon();
        BuildConfigLists();
        NavOverview.Checked += (_, _) => ShowPage(PageOverview);
        NavLaunch.Checked += (_, _) => ShowPage(PageLaunch);
        NavConfig.Checked += (_, _) => ShowPage(PageConfig);
        NavMaint.Checked += (_, _) => ShowPage(PageMaint);
        Loaded += async (_, _) =>
        {
            // 先渲染上次的状态（秒开），再后台刷新成实时值
            var cached = Backend.LoadCachedState();
            if (cached != null)
            {
                ApplyState(cached.Value);
                SetStatus("已显示上次缓存 · 正在刷新…", "wait");
            }
            await RefreshAsync();
        };
    }

    /// <summary>
    /// 上游插件自带的图标（编译进资源）；取不到时退回运行时画的徽标。
    /// 用 256px 原图而不是 ico：WPF 只解码 ico 的第 0 帧（16px），
    /// 任务栏会把 16px 放大到 32px，看起来又糊又小。
    /// </summary>
    private static ImageSource LoadWindowIcon()
    {
        foreach (var uri in new[] { "pack://application:,,,/Assets/bsb-256.png", "pack://application:,,,/Assets/bsb.ico" })
        {
            try { return new BitmapImage(new Uri(uri)); } catch { }
        }
        return BuildWindowIcon();
    }

    /// <summary>兜底：蓝底 B 徽标（与托盘一致）。</summary>
    private static ImageSource BuildWindowIcon()
    {
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            var accent = new SolidColorBrush(Color.FromRgb(0x00, 0xA1, 0xD6));
            dc.DrawEllipse(accent, null, new Point(16, 16), 15, 15);
            var typeface = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
            var text = new FormattedText("B", CultureInfo.InvariantCulture, FlowDirection.LeftToRight, typeface, 17, Brushes.White, 96);
            dc.DrawText(text, new Point(16 - text.Width / 2, 16 - text.Height / 2));
        }
        var bmp = new RenderTargetBitmap(32, 32, 96, 96, PixelFormats.Pbgra32);
        bmp.Render(visual);
        bmp.Freeze();
        return bmp;
    }

    private void BuildConfigLists()
    {
        foreach (var (key, label, color) in Categories)
        {
            var box = new CheckBox { Content = label, Style = (Style)FindResource("Check") };
            box.Tag = key;
            _catBoxes[key] = box;
            CategoryList.Items.Add(box);
        }
        foreach (var (key, label) in Actions)
        {
            var box = new CheckBox { Content = label, Style = (Style)FindResource("Check") };
            box.Tag = key;
            _actionBoxes[key] = box;
            ActionList.Items.Add(box);
        }
    }

    private void ShowPage(UIElement page)
    {
        PageOverview.Visibility = page == PageOverview ? Visibility.Visible : Visibility.Collapsed;
        PageLaunch.Visibility = page == PageLaunch ? Visibility.Visible : Visibility.Collapsed;
        PageConfig.Visibility = page == PageConfig ? Visibility.Visible : Visibility.Collapsed;
        PageMaint.Visibility = page == PageMaint ? Visibility.Visible : Visibility.Collapsed;
    }

    // ------------------------------------------------------------ 状态刷新

    private async Task RefreshAsync()
    {
        // 已经显示过缓存（或上次结果）时不要用「正在读取」盖掉它，保持信息可见
        if (_state.ValueKind != JsonValueKind.Object) SetStatus("正在读取状态…", "wait");
        var state = await Backend.CallAsync("get-state", null, 30000);
        if (state == null || !Backend.Bool(state.Value, "ok"))
        {
            SetStatus(Backend.Str(state ?? default, "error") ?? "读取状态失败", "bad");
            return;
        }
        Backend.SaveCachedState(state.Value);   // 供下次打开时秒开
        ApplyState(state.Value);
        SetStatus($"已刷新 · {DateTime.Now:HH:mm:ss}", "ok");
    }

    /// <summary>把一份状态渲染到界面（启动时的缓存与实时结果共用同一套）。</summary>
    private void ApplyState(JsonElement state)
    {
        _state = state;
        var s = _state;

        VersionText.Text = "插件 v" + (Backend.Str(Nested(s, "payload"), "projectVersion") ?? "?");

        var client = Nested(s, "client");
        ClientVersion.Text = Backend.Str(client, "exeVersion") ?? "未知";
        ClientPath.Text = Backend.Str(client, "installRoot") ?? "未找到";
        var asarInPlace = !string.IsNullOrEmpty(Backend.Str(client, "asarPath"));
        Paint(AsarPill, AsarDot, AsarText, asarInPlace ? "在位（未修改）" : "未找到", asarInPlace ? "ok" : "bad");

        var inj = Nested(s, "injector");
        var injCount = Backend.Int(inj, "count");
        Paint(InjectorPill, InjectorDot, InjectorText, injCount > 0 ? $"运行中 · {injCount} 进程" : "未运行", injCount > 0 ? "ok" : "bad");

        var portOpen = IsPortOpen(9222);
        Paint(PortPill, PortDot, PortText, portOpen ? "已连接" : "未连接", portOpen ? "ok" : "warn");

        var auto = Backend.Bool(Nested(s, "autostart"), "enabled");
        Paint(AutoPill, AutoDot, AutoText, auto ? "已启用" : "未启用", auto ? "ok" : "warn");

        var trayCount = Backend.Int(Nested(s, "tray"), "count");
        Paint(TrayPill, TrayDot, TrayText, trayCount > 0 ? "运行中" : "未运行", trayCount > 0 ? "ok" : "warn");

        AutostartBox.IsChecked = auto;

        // 插件更新状态
        var upd = Nested(s, "updateInfo");
        UpdCurrent.Text = "v" + (Backend.Str(Nested(s, "payload"), "runtimeVersion") ?? "?");
        UpdLatest.Text = Backend.Str(upd, "latestVersion") != null ? "v" + Backend.Str(upd, "latestVersion") : "—";
        var lastCheck = Backend.Str(upd, "lastCheck");
        var lastResult = Backend.Str(upd, "lastResult");
        UpdHint.Text = lastCheck != null
            ? "上次检查：" + lastCheck + " · " + (lastResult ?? "")
            : "尚未检查过更新（更新源可在 %LOCALAPPDATA%\\bsb-client-patcher\\update.json 配置）";
        _updatingAutoToggle = true;   // 程序性赋值不应触发事件回写
        UpdAutoCheck.IsChecked = Backend.Bool(upd, "autoCheck", true);
        _updatingAutoToggle = false;

        BuildLivePages();
        BuildShortcutList();
        LoadConfigIntoForm();
    }

    private static JsonElement Nested(JsonElement parent, string name)
        => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var v) ? v : default;

    private static bool IsPortOpen(int port)
    {
        try
        {
            using var c = new System.Net.Sockets.TcpClient();
            return c.ConnectAsync("127.0.0.1", port).Wait(400);
        }
        catch { return false; }
    }

    private void BuildLivePages()
    {
        PageList.Items.Clear();
        var live = Nested(_state, "live");
        var pages = live.ValueKind == JsonValueKind.Object && live.TryGetProperty("pages", out var p) ? p : default;
        if (pages.ValueKind != JsonValueKind.Array || pages.GetArrayLength() == 0)
        {
            PageList.Items.Add(new TextBlock
            {
                Text = "没有检测到页面（客户端未运行或未带调试端口）",
                Foreground = (Brush)FindResource("FaintBrush")
            });
            return;
        }
        foreach (var page in pages.EnumerateArray())
        {
            var grid = new Grid { Margin = new Thickness(0, 2, 0, 2) };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(70) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(90) });
            var kind = Backend.Str(page, "kind") == "player" ? "播放页" : "主界面";
            var isPlayer = Backend.Str(page, "kind") == "player";
            AddCell(grid, 0, kind, null);
            AddCell(grid, 1, "v" + (Backend.Str(page, "ui") ?? "—"), Backend.Str(page, "ui") == Backend.Str(page, "content") ? "ok" : "warn");
            AddCell(grid, 2, Backend.Str(page, "bvid") ?? "—", null);
            AddCell(grid, 3, isPlayer ? $"按钮 {Backend.Int(page, "button")} · 色条 {Backend.Int(page, "segs")}" : "—", null);
            PageList.Items.Add(grid);
        }
    }

    private static void AddCell(Grid grid, int column, string text, string tone)
    {
        var tb = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
        if (tone == "ok") tb.Foreground = new SolidColorBrush(Color.FromRgb(0x4E, 0xC9, 0x7A));
        else if (tone == "warn") tb.Foreground = new SolidColorBrush(Color.FromRgb(0xFF, 0xD1, 0x66));
        Grid.SetColumn(tb, column);
        grid.Children.Add(tb);
    }

    private void BuildShortcutList()
    {
        ShortcutList.Items.Clear();
        _shortcutBoxes.Clear();
        var list = Nested(_state, "shortcuts");
        if (list.ValueKind != JsonValueKind.Array) return;
        var needsAdmin = 0;
        foreach (var sc in list.EnumerateArray())
        {
            var path = Backend.Str(sc, "path");
            var hasPort = Backend.Bool(sc, "hasPort");
            var scope = Backend.Str(sc, "scope");
            if (Backend.Bool(sc, "needsAdmin") && !hasPort) needsAdmin++;

            var row = new Grid { Margin = new Thickness(0, 5, 0, 5) };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(24) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(96) });

            var box = new CheckBox
            {
                IsChecked = !hasPort,
                Style = (Style)FindResource("CheckTight"),
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Left
            };
            Grid.SetColumn(box, 0);
            row.Children.Add(box);
            _shortcutBoxes.Add((box, path));

            var name = System.IO.Path.GetFileName(path);
            var place = Backend.Str(sc, "place") ?? (scope == "machine" ? "系统级" : "其他位置");

            var head = new StackPanel { Orientation = Orientation.Horizontal };
            head.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(0x22, 0x00, 0xA1, 0xD6)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x55, 0x00, 0xA1, 0xD6)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(4),
                Padding = new Thickness(6, 0, 6, 1),
                Margin = new Thickness(0, 0, 8, 0),
                VerticalAlignment = VerticalAlignment.Center,
                Child = new TextBlock
                {
                    Text = place,
                    FontSize = 11.5,
                    Foreground = new SolidColorBrush(Color.FromRgb(0x8F, 0xD8, 0xF4))
                }
            });
            head.Children.Add(new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center });

            var stack = new StackPanel { Margin = new Thickness(10, 0, 10, 0) };
            stack.Children.Add(head);
            stack.Children.Add(new TextBlock
            {
                Text = Backend.Str(sc, "args") is { Length: > 0 } a ? a : "（无参数）",
                Foreground = (Brush)FindResource("FaintBrush"),
                FontSize = 11.5,
                Margin = new Thickness(0, 2, 0, 0),
                TextTrimming = TextTrimming.CharacterEllipsis
            });
            Grid.SetColumn(stack, 1);
            row.Children.Add(stack);

            var pill = new Border
            {
                Style = (Style)FindResource("Pill"),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center
            };
            var inner = new StackPanel { Orientation = Orientation.Horizontal };
            inner.Children.Add(new Ellipse { Style = (Style)FindResource("Dot"), Fill = hasPort ? (Brush)FindResource("OkBrush") : (Brush)FindResource("BadBrush") });
            inner.Children.Add(new TextBlock { Text = hasPort ? "已带端口" : "缺失", Margin = new Thickness(7, 0, 0, 0) });
            pill.Child = inner;
            Grid.SetColumn(pill, 2);
            row.Children.Add(pill);

            ShortcutList.Items.Add(row);
        }
        ShortcutHint.Text = needsAdmin > 0 ? "系统级快捷方式需要授权，应用时会弹出 UAC" : "";
    }

    private void LoadConfigIntoForm()
    {
        var info = Nested(_state, "configInfo");
        var cfg = Nested(info, "config");
        if (cfg.ValueKind != JsonValueKind.Object)
        {
            SetStatus("没有找到插件配置（先运行一次客户端）", "warn");
            return;
        }
        CfgEnabled.IsChecked = Backend.Bool(cfg, "enabled", true);
        CfgNotice.IsChecked = Backend.Bool(cfg, "showSkipNotice", true);
        CfgDebug.IsChecked = Backend.Bool(cfg, "debug");
        CfgApi.Text = Backend.Str(cfg, "apiBase") ?? "";
        CfgBuffer.Text = (Backend.Str(cfg, "skipBufferSec") ?? "0.15");
        CfgVotes.Text = (Backend.Str(cfg, "minVotes") ?? "0");

        var cats = Nested(cfg, "categories");
        foreach (var (key, box) in _catBoxes)
        {
            var on = true;
            if (cats.ValueKind == JsonValueKind.Object && cats.TryGetProperty(key, out var v))
                on = v.ValueKind != JsonValueKind.False;
            box.IsChecked = on;
        }
        var acts = Nested(cfg, "actionPreferences");
        foreach (var (key, box) in _actionBoxes)
        {
            var on = false;
            if (acts.ValueKind == JsonValueKind.Object && acts.TryGetProperty(key, out var v))
                on = v.ValueKind == JsonValueKind.True;
            box.IsChecked = on;
        }

        CategoryChips.Children.Clear();
        foreach (var (key, label, color) in Categories)
        {
            if (_catBoxes[key].IsChecked != true) continue;
            var chip = new Border
            {
                Style = (Style)FindResource("Pill"),
                Margin = new Thickness(0, 0, 8, 8)
            };
            var sp = new StackPanel { Orientation = Orientation.Horizontal };
            sp.Children.Add(new Border
            {
                Width = 9,
                Height = 9,
                CornerRadius = new CornerRadius(2),
                Background = (Brush)new BrushConverter().ConvertFromString(color),
                VerticalAlignment = VerticalAlignment.Center
            });
            sp.Children.Add(new TextBlock { Text = label, Margin = new Thickness(7, 0, 0, 0) });
            chip.Child = sp;
            CategoryChips.Children.Add(chip);
        }
        if (CategoryChips.Children.Count == 0)
            CategoryChips.Children.Add(new TextBlock { Text = "无", Foreground = (Brush)FindResource("FaintBrush") });
    }

    // ------------------------------------------------------------ 状态条

    private void SetStatus(string text, string tone = null)
    {
        StatusText.Text = text;
        StatusDot.Fill = tone switch
        {
            "ok" => (Brush)FindResource("OkBrush"),
            "bad" => (Brush)FindResource("BadBrush"),
            "warn" => (Brush)FindResource("WarnBrush"),
            "wait" => (Brush)FindResource("AccentBrush"),
            _ => (Brush)FindResource("FaintBrush")
        };
    }

    private static void Paint(Border pill, System.Windows.Shapes.Ellipse dot, TextBlock text, string label, string tone)
    {
        text.Text = label;
        dot.Fill = tone switch
        {
            "ok" => new SolidColorBrush(Color.FromRgb(0x4E, 0xC9, 0x7A)),
            "bad" => new SolidColorBrush(Color.FromRgb(0xFF, 0x6B, 0x6B)),
            _ => new SolidColorBrush(Color.FromRgb(0xFF, 0xD1, 0x66))
        };
    }

    // ------------------------------------------------------------ 动作执行

    private async Task RunAsync(string busyText, string action, IEnumerable<KeyValuePair<string, string>> args,
        string doneText, Func<JsonElement, string> extra = null)
    {
        if (_busy) return;
        _busy = true;
        SetStatus(busyText, "wait");
        try
        {
            var result = await Backend.CallAsync(action, args);
            if (result == null) { SetStatus("后端没有响应", "bad"); return; }
            var r = result.Value;
            if (!Backend.Bool(r, "ok"))
            {
                SetStatus(Backend.Str(r, "error") ?? "操作失败", "bad");
                return;
            }
            if (Backend.Bool(r, "ok") && r.TryGetProperty("ok", out _) && !Backend.Bool(r, "ok"))
            {
                SetStatus("操作失败", "bad");
                return;
            }
            var note = extra != null ? extra(r) : null;
            SetStatus(string.IsNullOrEmpty(note) ? doneText : doneText + " · " + note, "ok");
        }
        finally
        {
            _busy = false;
        }
        await RefreshAsync();
    }

    private async void OnRefresh(object sender, RoutedEventArgs e) => await RefreshAsync();

    private async void OnInjectorStart(object sender, RoutedEventArgs e)
        => await RunAsync("正在启动注入器…", "injector-start", null, "注入器已启动");

    private async void OnInjectorStop(object sender, RoutedEventArgs e)
        => await RunAsync("正在停止注入器…", "injector-stop", null, "注入器已停止");

    private async void OnInjectorRestart(object sender, RoutedEventArgs e)
    {
        await RunAsync("正在重启注入器…", "injector-stop", null, "已停止");
        await RunAsync("正在启动注入器…", "injector-start", null, "注入器已重启");
    }

    private async void OnShortcutsApply(object sender, RoutedEventArgs e)
    {
        var paths = _shortcutBoxes.Where(x => x.Box.IsChecked == true).Select(x => x.Path).ToList();
        if (paths.Count == 0) { SetStatus("先勾选要处理的快捷方式", "warn"); return; }
        var args = new List<KeyValuePair<string, string>>
        {
            new("Port", string.IsNullOrWhiteSpace(PortBox.Text) ? "9222" : PortBox.Text.Trim())
        };
        if (AllowOriginsBox.IsChecked == true) args.Add(new("AllowOrigins", null));
        foreach (var p in paths) args.Add(new("Paths", p));
        await RunAsync("正在改写快捷方式（系统级会弹出授权窗口）…", "shortcut-args", args, "快捷方式已更新",
            r => paths.Count + " 项");
    }

    private async void OnShortcutsRemove(object sender, RoutedEventArgs e)
    {
        var paths = _shortcutBoxes.Where(x => x.Box.IsChecked == true).Select(x => x.Path).ToList();
        if (paths.Count == 0) { SetStatus("先勾选要处理的快捷方式", "warn"); return; }
        var args = new List<KeyValuePair<string, string>> { new("Remove", null) };
        foreach (var p in paths) args.Add(new("Paths", p));
        await RunAsync("正在移除调试端口…", "shortcut-args", args, "已移除");
    }

    private async void OnAutostartToggle(object sender, RoutedEventArgs e)
    {
        var enable = AutostartBox.IsChecked == true;
        var args = enable ? new List<KeyValuePair<string, string>> { new("Enable", null) } : null;
        await RunAsync(enable ? "正在启用登录自启…" : "正在停用登录自启…", "autostart", args,
            enable ? "登录自启已启用" : "登录自启已停用");
    }

    private async void OnConfigSave(object sender, RoutedEventArgs e)
    {
        var cfg = new Dictionary<string, object>
        {
            ["enabled"] = CfgEnabled.IsChecked == true,
            ["showSkipNotice"] = CfgNotice.IsChecked == true,
            ["debug"] = CfgDebug.IsChecked == true,
            ["apiBase"] = CfgApi.Text.Trim(),
            ["skipBufferSec"] = double.TryParse(CfgBuffer.Text, out var b) ? b : 0.15,
            ["minVotes"] = int.TryParse(CfgVotes.Text, out var v) ? v : 0,
            ["showBadge"] = false,
            ["categories"] = _catBoxes.ToDictionary(kv => kv.Key, kv => (object)(kv.Value.IsChecked == true)),
            ["actionPreferences"] = _actionBoxes.ToDictionary(kv => kv.Key, kv => (object)(kv.Value.IsChecked == true))
        };
        var tmp = System.IO.Path.Combine(Path.GetTempPath(), "bsb-config-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".json");
        File.WriteAllText(tmp, JsonSerializer.Serialize(cfg, new JsonSerializerOptions { WriteIndented = true }), new System.Text.UTF8Encoding(false));
        await RunAsync("正在保存并下发到已打开的页面…", "config-save",
            new[] { new KeyValuePair<string, string>("Path", tmp) }, "设置已保存",
            r => Backend.Bool(r, "queued") ? "已下发到页面" : "注入器未运行，下次启动生效");
        try { File.Delete(tmp); } catch { }
        ConfigSaved.Text = "已保存 ✓";
        await Task.Delay(4000);
        ConfigSaved.Text = "";
    }

    private async void OnPatch(object sender, RoutedEventArgs e)
        => await RunAsync("正在适配客户端…", "patch", null, "适配完成");

    private async void OnClientScan(object sender, RoutedEventArgs e)
    {
        SetStatus("正在扫描客户端安装位置（注册表 / 进程 / 各磁盘）…", "wait");
        var r = await Backend.CallAsync("client-scan", null, 120000);
        if (r == null || !Backend.Bool(r.Value, "ok")) { SetStatus("扫描失败", "bad"); return; }
        var n = 0;
        if (r.Value.TryGetProperty("candidates", out var arr) && arr.ValueKind == System.Text.Json.JsonValueKind.Array)
            n = arr.GetArrayLength();
        await RefreshAsync();
        SetStatus(n > 0 ? $"扫描到 {n} 个候选位置，已采用第一个有效项" : "未扫描到客户端，可用「更改目录…」手动指定", n > 0 ? "ok" : "warn");
    }

    private async void OnClientPick(object sender, RoutedEventArgs e)
    {
        var picked = await PickPathAsync("folder");
        if (picked == null) return;
        try
        {
            if (!File.Exists(System.IO.Path.Combine(picked, "resources", "app.asar")))
            {
                SetStatus("该目录不是客户端安装根目录（缺 resources\\app.asar）", "bad");
                return;
            }
        }
        catch { }
        SetStatus("正在保存客户端位置…", "wait");
        var r = await Backend.CallAsync("client-set", new[] { new KeyValuePair<string, string>("Path", picked) }, 60000);
        if (r == null) { SetStatus("保存失败", "bad"); return; }
        if (!Backend.Bool(r.Value, "ok")) { SetStatus(Backend.Str(r.Value, "error") ?? "保存失败", "bad"); return; }
        SetStatus("客户端位置已更新：" + Backend.Str(r.Value, "installRoot"), "ok");
        await RefreshAsync();
    }

    // ---- 插件自动更新 ------------------------------------------------------

    private async void OnUpdateCheck(object sender, RoutedEventArgs e)
    {
        SetStatus("正在检查插件更新…", "wait");
        var r = await Backend.CallAsync("plugin-check", null, 60000);
        if (r == null || !Backend.Bool(r.Value, "ok")) { SetStatus("检查失败", "bad"); return; }
        var hasUpdate = Backend.Bool(r.Value, "hasUpdate");
        var info = Nested(r.Value, "info");
        UpdLatest.Text = Backend.Str(info, "latest") ?? "—";
        UpdHint.Text = "上次检查：" + (Backend.Str(info, "lastCheck") ?? "—") + " · " + (Backend.Str(info, "lastResult") ?? "");
        SetStatus(hasUpdate
            ? "有新版本 v" + Backend.Str(info, "latest") + "，点「自动更新」安装"
            : "已是最新版本", hasUpdate ? "warn" : "ok");
    }

    private async void OnUpdateAuto(object sender, RoutedEventArgs e)
    {
        SetStatus("正在自动更新插件…", "wait");
        var r = await Backend.CallAsync("plugin-auto", null, 180000);
        if (r == null || !Backend.Bool(r.Value, "ok")) { SetStatus("自动更新失败", "bad"); return; }
        var res = Backend.Str(r.Value, "result");
        var ver = Backend.Str(r.Value, "version");
        SetStatus((res ?? "完成") + (ver != null ? " · 当前 v" + ver : ""), "ok");
        await RefreshAsync();
    }

    private async void OnUpdateAutoToggle(object sender, RoutedEventArgs e)
    {
        if (_updatingAutoToggle) return;   // 程序性赋值触发的事件直接忽略
        // 开关状态持久化到 update.json 的 autoCheck
        var on = UpdAutoCheck.IsChecked == true;
        SetStatus(on ? "已开启：打开安装器时自动检查更新" : "已关闭自动检查", null);
        await Task.Run(() =>
        {
            try
            {
                var path = Path.Combine(Backend.StateRoot, "update.json");
                var cfg = new Dictionary<string, object>();
                if (File.Exists(path))
                {
                    var json = System.Text.Json.JsonDocument.Parse(File.ReadAllText(path)).RootElement.Clone();
                    foreach (var p in json.EnumerateObject())
                    {
                        cfg[p.Name] = p.Value.ValueKind switch
                        {
                            System.Text.Json.JsonValueKind.True => true,
                            System.Text.Json.JsonValueKind.False => false,
                            System.Text.Json.JsonValueKind.Number => p.Value.GetDouble(),
                            System.Text.Json.JsonValueKind.String => p.Value.GetString(),
                            _ => (object)p.Value.ToString()
                        };
                    }
                }
                cfg["autoCheck"] = on;
                File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(cfg, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }), new System.Text.UTF8Encoding(false));
            }
            catch { }
        });
    }

    private async void OnUpdateRepo(object sender, RoutedEventArgs e)
        => await RunAsync("正在用仓库 payload 更新…", "update-plugin",
            new[] { new KeyValuePair<string, string>("Source", "repo") }, "插件已更新");

    private async void OnUpdateFolder(object sender, RoutedEventArgs e)
    {
        var picked = await PickPathAsync("folder");
        if (picked == null) return;
        PickedPath.Text = picked;
        await RunAsync("正在从目录更新…", "update-plugin", new[]
        {
            new KeyValuePair<string, string>("Source", "folder"),
            new KeyValuePair<string, string>("Path", picked)
        }, "插件已更新");
    }

    private async void OnUpdateZip(object sender, RoutedEventArgs e)
    {
        var picked = await PickPathAsync("zip");
        if (picked == null) return;
        PickedPath.Text = picked;
        await RunAsync("正在从 zip 更新…", "update-plugin", new[]
        {
            new KeyValuePair<string, string>("Source", "zip"),
            new KeyValuePair<string, string>("Path", picked)
        }, "插件已更新");
    }

    private async Task<string> PickPathAsync(string which)
    {
        SetStatus("等待选择…", "wait");
        var r = await Backend.CallAsync("pick-path", new[] { new KeyValuePair<string, string>("Which", which) }, 120000);
        if (r == null || !Backend.Bool(r.Value, "ok")) { SetStatus("选择失败", "bad"); return null; }
        if (Backend.Bool(r.Value, "cancelled")) { SetStatus("已取消", null); return null; }
        return Backend.Str(r.Value, "path");
    }

    private async void OnTrayStart(object sender, RoutedEventArgs e)
        => await RunAsync("正在启动托盘…", "tray-start", null, "托盘已启动");

    private async void OnTrayStop(object sender, RoutedEventArgs e)
        => await RunAsync("正在停止托盘…", "tray-stop", null, "托盘已停止");

    private async void OnOpenLogs(object sender, RoutedEventArgs e)
        => await RunAsync("正在打开…", "open-path", new[] { new KeyValuePair<string, string>("Which", "logs") }, "已打开日志目录");

    private async void OnOpenProject(object sender, RoutedEventArgs e)
        => await RunAsync("正在打开…", "open-path", new[] { new KeyValuePair<string, string>("Which", "project") }, "已打开项目目录");

    private async void OnCopyDiagnostics(object sender, RoutedEventArgs e)
    {
        SetStatus("正在生成诊断信息…", "wait");
        var r = await Backend.CallAsync("diagnostics", null, 30000);
        var text = r != null && Backend.Bool(r.Value, "ok") ? Backend.Str(r.Value, "text") : null;
        if (string.IsNullOrEmpty(text)) { SetStatus("生成失败", "bad"); return; }
        try
        {
            Clipboard.SetText(text);
            SetStatus("诊断信息已复制到剪贴板", "ok");
        }
        catch { SetStatus("复制失败", "bad"); }
    }
}
