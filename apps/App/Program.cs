// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
//
// Program.cs — 唯一入口：一个 exe 同时是托盘和设置窗口。
//
//   BSB.exe            双击：启动托盘 + 打开设置窗口
//   BSB.exe --tray     登录自启用：只起托盘，不开窗口
//   BSB.exe --ui       再次双击：把已在运行的那个实例的窗口叫到前台，自己退出
//
// 单实例：命名互斥体判定 + 命名事件通知（第二个进程设置事件后退出）。

using System.Threading;
using System.Windows;

namespace BsbApp;

internal static class Program
{
    private const string MutexName = @"Local\BSBSingleInstance";
    private const string ShowEventName = @"Local\BSBShowWindow";

    /// <summary>进程内唯一的事件句柄：第二个实例用它叫醒第一个实例显示窗口。</summary>
    private static EventWaitHandle _showEvent;
    private static RegisteredWaitHandle _showWait;

    [STAThread]
    public static void Main(string[] args)
    {
        var trayOnly = args.Any(a => string.Equals(a, "--tray", StringComparison.OrdinalIgnoreCase));

        using var mutex = new Mutex(true, MutexName, out var isFirst);
        if (!isFirst)
        {
            // 已有实例在跑：让它把窗口显示出来（--tray 不打扰它），然后退出
            if (!trayOnly)
            {
                try
                {
                    if (EventWaitHandle.TryOpenExisting(ShowEventName, out var ev))
                    {
                        ev.Set();
                        ev.Dispose();
                    }
                }
                catch { }
            }
            return;
        }

        // 第一个实例：等待「显示窗口」信号
        _showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        _showWait = ThreadPool.RegisterWaitForSingleObject(
            _showEvent, (_, _) => Application.Current?.Dispatcher.BeginInvoke(new Action(App.ShowMainWindow)),
            null, Timeout.Infinite, false);

        var app = new App();
        app.InitializeComponent();
        app.Run(trayOnly);
    }

    /// <summary>托盘「退出」时调用：真的结束进程，而不是隐藏窗口。</summary>
    public static void Shutdown()
    {
        try { App.Exiting = true; } catch { }
        try { _showWait?.Unregister(null); } catch { }
        try { _showEvent?.Dispose(); } catch { }
        Application.Current?.Shutdown();
    }
}
