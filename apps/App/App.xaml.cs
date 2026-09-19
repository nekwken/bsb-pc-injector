// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
//
// App.xaml.cs — 应用生命周期：托盘常驻，设置窗口按需显示/隐藏。

using System.IO;
using System.Windows;

namespace BsbApp;

public partial class App : Application
{
    /// <summary>true 表示真的要退出（托盘菜单「退出」），否则关窗口只是隐藏。</summary>
    public static bool Exiting { get; set; }

    private static MainWindow _window;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(args.Exception.Message, "空降助手", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };
    }

    /// <summary>由 Program.Main 调用：拉起托盘，并按参数决定是否开窗口。</summary>
    public void Run(bool trayOnly)
    {
        Tray.Start();
        if (!trayOnly) ShowMainWindow();
        base.Run();
    }

    /// <summary>显示（或唤醒）设置窗口；已在显示则激活到前台。</summary>
    public static void ShowMainWindow()
    {
        try
        {
            if (_window == null)
            {
                _window = new MainWindow();
                _window.Closed += (_, _) => _window = null;
                _window.Show();
                return;
            }
            if (!_window.IsVisible) _window.Show();
            if (_window.WindowState == WindowState.Minimized) _window.WindowState = WindowState.Normal;
            _window.Activate();
            _window.Topmost = true;    // 从托盘唤起时确保到前台
            _window.Topmost = false;
            _window.Focus();
        }
        catch (Exception ex)
        {
            // 静默失败会让「双击没反应」无从排查：写日志
            try
            {
                var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "bsb-client-patcher", "logs");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "app-error.log"),
                    $"[{DateTime.Now:HH:mm:ss}] 打开设置窗口失败：{ex}{Environment.NewLine}");
            }
            catch { }
        }
    }
}
