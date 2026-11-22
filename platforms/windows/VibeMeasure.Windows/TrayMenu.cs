using System.Drawing;
using System.Security;
using System.Runtime.InteropServices;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using Forms = System.Windows.Forms;

namespace VibeMeasure.Windows;

internal sealed class TrayMenu : IDisposable
{
    private readonly StartupRegistration startup;
    private readonly Icon icon;
    private readonly Forms.NotifyIcon notification;
    private readonly Forms.ContextMenuStrip menu;
    private bool registered;
    private bool useTrayNotifications;
    private readonly Forms.ToolStripMenuItem startWithWindows = new("Start with Windows");

    public TrayMenu(StartupRegistration startup, Action showDashboard, Action quit)
    {
        this.startup = startup;
        menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open VibeMeasure", null, (_, _) => showDashboard());
        menu.Items.Add(startWithWindows);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => quit());
        menu.Opening += (_, _) => ReadStartupSetting();
        startWithWindows.Click += (_, _) => ToggleStartup();

        using var stream = typeof(TrayMenu).Assembly.GetManifestResourceStream("VibeMeasure.TrayIcon")
            ?? throw new InvalidOperationException("The VibeMeasure notification icon is missing.");
        icon = new Icon(stream);
        notification = new Forms.NotifyIcon
        {
            Icon = icon,
            Text = "VibeMeasure",
            ContextMenuStrip = menu,
            Visible = true,
        };
        notification.BalloonTipClicked += (_, _) => showDashboard();
        notification.MouseDoubleClick += (_, args) =>
        {
            if (args.Button == Forms.MouseButtons.Left) showDashboard();
        };
    }

    internal void ShowAlert(string message)
    {
        if (!useTrayNotifications)
        {
            try
            {
                if (!registered)
                {
                    AppNotificationManager.Default.Register();
                    registered = true;
                }
                var toast = new AppNotificationBuilder().AddText("VibeMeasure").AddText(message).BuildNotification();
                AppNotificationManager.Default.Show(toast);
                return;
            }
            catch (Exception error) when (error is COMException or UnauthorizedAccessException)
            {
                // Some unpackaged installations lack the App SDK notification COM server.
                useTrayNotifications = true;
            }
        }
        notification.ShowBalloonTip(10000, "VibeMeasure", message, Forms.ToolTipIcon.Info);
    }

    private void ReadStartupSetting()
    {
        try
        {
            startWithWindows.Checked = startup.IsEnabled;
            startWithWindows.Enabled = true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException)
        {
            startWithWindows.Enabled = false;
        }
    }

    private void ToggleStartup()
    {
        try
        {
            startup.SetEnabled(!startup.IsEnabled);
            ReadStartupSetting();
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException)
        {
            notification.ShowBalloonTip(5000, "VibeMeasure", "Could not change the Windows startup setting.",
                Forms.ToolTipIcon.Warning);
        }
    }

    public void Dispose()
    {
        if (registered) AppNotificationManager.Default.Unregister();
        notification.Visible = false;
        notification.Dispose();
        menu.Dispose();
        icon.Dispose();
    }
}
