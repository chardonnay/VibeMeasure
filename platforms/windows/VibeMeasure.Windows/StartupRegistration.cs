using Microsoft.Win32;

namespace VibeMeasure.Windows;

internal sealed class StartupRegistration(RegistryKey userHive, string executable)
{
    internal const string BackgroundArgument = "--background";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string EntryName = "VibeMeasure";

    public bool IsEnabled
    {
        get
        {
            using var key = userHive.OpenSubKey(RunKey);
            return key?.GetValue(EntryName) is string { Length: > 0 };
        }
    }

    public void SetEnabled(bool enabled)
    {
        if (!enabled)
        {
            using var existing = userHive.OpenSubKey(RunKey, writable: true);
            existing?.DeleteValue(EntryName, throwOnMissingValue: false);
            return;
        }

        var command = $"\"{executable}\" {BackgroundArgument}";
        if (!File.Exists(executable) || command.Length > 260)
            throw new IOException("Autostart requires an executable at a valid Windows startup path.");

        using var key = userHive.CreateSubKey(RunKey)
            ?? throw new IOException("Could not open the Windows startup settings.");
        key.SetValue(EntryName, command, RegistryValueKind.String);
    }
}
