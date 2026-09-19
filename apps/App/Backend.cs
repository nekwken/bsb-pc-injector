// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 BSB PC client injector contributors
// 与 PowerShell 后端（tools\InstallerActions.ps1）通信。
// 安装器不自己实现业务逻辑：状态采集、快捷方式改写、提权、启停注入器/托盘、
// 更新插件、还原 asar 都在那个脚本里，命令行和 GUI 共用同一套。

using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;

namespace BsbApp;

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

    /// <summary>
    /// 动作名/参数名都来自本程序内部（不是用户输入）。这里断言一次，保证拼进命令行开关的
    /// 只可能是固定字母表：字母、数字，动作名另允许连字符（get-state 这种命名）。
    /// 目的：杜绝将来有人把用户文本当参数名传进来（那才可能夹带任意开关）。
    /// </summary>
    private static string AssertName(string value, string what, bool allowDash = false)
    {
        var pattern = allowDash ? "^[A-Za-z][A-Za-z0-9-]*$" : "^[A-Za-z][A-Za-z0-9]*$";
        if (string.IsNullOrEmpty(value) || !System.Text.RegularExpressions.Regex.IsMatch(value, pattern))
            throw new ArgumentException($"{what}非法：{value}");
        return value;
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
        psi.ArgumentList.Add(AssertName(action, "动作名", allowDash: true));
        if (args != null)
        {
            foreach (var kv in args)
            {
                // 安全模型：UseShellExecute=false 不经过任何 shell，ArgumentList 由 .NET
                // 逐元素转义（不是拼接命令行）。参数名来自本程序内部，这里再用白名单断言，
                // 保证 "-" + 名字 只能拼出固定字母表里的开关；用户选的值（路径等）一律
                // 作为独立 argv 元素传入，从不拼进字符串。
                psi.ArgumentList.Add("-" + AssertName(kv.Key, "参数名"));
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
