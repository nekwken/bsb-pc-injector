// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// 与 PowerShell 后端（tools\InstallerActions.ps1）通信。
// 安装器不自己实现业务逻辑：状态采集、快捷方式改写、提权、启停注入器/托盘、
// 更新插件、还原 asar 都在那个脚本里，命令行和 GUI 共用同一套。

using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace BsbInstaller;

internal static class Backend
{
    public static string Root { get; } = FindRoot();

    private static string FindRoot()
    {
        var dir = AppContext.BaseDirectory.TrimEnd('\\');
        while (dir.Length > 3 && !File.Exists(Path.Combine(dir, "tools", "InstallerActions.ps1")))
        {
            var parent = Path.GetDirectoryName(dir);
            if (string.IsNullOrEmpty(parent)) break;
            dir = parent;
        }
        return dir;
    }

    public static string StateRoot => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "bsb-client-patcher");

    /// <summary>上次成功读取的状态快照：打开窗口时先显示它，避免空等 PowerShell。</summary>
    private static string CachePath => Path.Combine(StateRoot, "state-cache.json");

    public static JsonElement? LoadCachedState()
    {
        try
        {
            if (!File.Exists(CachePath)) return null;
            using var doc = JsonDocument.Parse(File.ReadAllText(CachePath));
            return doc.RootElement.Clone();
        }
        catch { return null; }
    }

    public static void SaveCachedState(JsonElement state)
    {
        try
        {
            Directory.CreateDirectory(StateRoot);
            File.WriteAllText(CachePath,
                JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = false }),
                new UTF8Encoding(false));
        }
        catch { }
    }

    /// <summary>运行一个后端动作，返回它输出的 JSON（失败时 error 非空）。</summary>
    public static async Task<JsonElement?> CallAsync(string action, IEnumerable<KeyValuePair<string, string>> args = null, int timeoutMs = 180000)
    {
        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Root
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-File");
        psi.ArgumentList.Add(Path.Combine(Root, "tools", "InstallerActions.ps1"));
        psi.ArgumentList.Add("-Action");
        psi.ArgumentList.Add(action);
        if (args != null)
        {
            foreach (var kv in args)
            {
                psi.ArgumentList.Add("-" + kv.Key);
                if (kv.Value != null) psi.ArgumentList.Add(kv.Value);   // null = 开关参数
            }
        }

        using var proc = Process.Start(psi);
        var stdoutTask = proc.StandardOutput.ReadToEndAsync();
        var stderrTask = proc.StandardError.ReadToEndAsync();
        var exited = await Task.Run(() => proc.WaitForExit(timeoutMs));
        if (!exited)
        {
            try { proc.Kill(true); } catch { }
            return Error("后端超时（可能需要你在弹出的授权窗口里确认）");
        }
        var stdout = await stdoutTask;
        var stderr = await stderrTask;

        var start = stdout.IndexOf('{');
        if (start < 0)
        {
            var msg = (stdout + "\n" + stderr).Trim();
            return Error(string.IsNullOrWhiteSpace(msg) ? "后端没有返回结果" : msg);
        }
        try { return JsonDocument.Parse(stdout.Substring(start)).RootElement.Clone(); }
        catch (Exception ex) { return Error("无法解析后端输出：" + ex.Message); }
    }

    private static JsonElement Error(string message)
    {
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(new { ok = false, error = message }));
        return doc.RootElement.Clone();
    }

    public static string Str(JsonElement e, string name)
        => e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind != JsonValueKind.Null
            ? (v.ValueKind == JsonValueKind.String ? v.GetString() : v.ToString())
            : null;

    public static bool Bool(JsonElement e, string name, bool fallback = false)
    {
        if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(name, out var v)) return fallback;
        return v.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            JsonValueKind.String => v.GetString() == "True" || v.GetString() == "true",
            _ => fallback
        };
    }

    public static int Int(JsonElement e, string name, int fallback = 0)
    {
        if (e.ValueKind != JsonValueKind.Object || !e.TryGetProperty(name, out var v)) return fallback;
        if (v.ValueKind == JsonValueKind.Number) return v.GetInt32();
        return int.TryParse(v.ToString(), out var n) ? n : fallback;
    }
}
