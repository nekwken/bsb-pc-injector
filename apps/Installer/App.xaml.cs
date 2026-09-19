// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
using System.Windows;

namespace BsbInstaller;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show(args.Exception.Message, "空降助手安装器", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };
    }
}
