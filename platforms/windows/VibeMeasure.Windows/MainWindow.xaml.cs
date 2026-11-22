using System.ComponentModel;
using System.Diagnostics;
using System.Security;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace VibeMeasure.Windows;

public sealed partial class MainWindow : Window
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly AccessibilitySettings accessibility = new();
    private readonly StartupRegistration startup;
    private readonly Dictionary<(string ToolId, bool Dark), ProviderMark> marks = new();
    private readonly string db;
    private readonly string codexHome = Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } home
        ? home : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
    private CancellationTokenSource? pending;
    private CancellationTokenSource? providerSync;
    private string? syncStatus;
    private string? syncDetails;
    private UsageSnapshot? snapshot;
    private bool ready;
    private bool layoutReady;
    private bool wide;
    private bool sizedForData;
    private bool readingStartup;

    internal MainWindow(string database, StartupRegistration startup)
    {
        db = database;
        this.startup = startup;
        InitializeComponent();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "pegelbot.ico"));
        timer.Tick += (_, _) => _ = SyncAndRefreshAsync();
        Closed += (_, _) =>
        {
            ready = false;
            timer.Stop();
            pending?.Cancel();
            providerSync?.Cancel();
        };
    }

    internal void StartUpdates()
    {
        if (ready) return;
        ready = true;
        timer.Start();
        if (File.Exists(db)) _ = RefreshAsync();
        _ = SyncAndRefreshAsync();
    }

    private void DashboardLoaded(object sender, RoutedEventArgs args)
    {
        if (layoutReady) return;
        layoutReady = true;
        ApplyLayout();
        ResizeForLayout(center: true);
        sizedForData = snapshot is not null;
    }

    private void ModeChanged(object sender, SelectionChangedEventArgs args)
    {
        if (ready) _ = RefreshAsync();
    }

    private void RefreshClicked(object sender, RoutedEventArgs args) => _ = SyncAndRefreshAsync();

    private async void SettingsOpened(object sender, object args)
    {
        ReadStartupSetting();
        if (snapshot is not null) return;
        try
        {
            using var lookup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var output = await RunCliAsync(lookup.Token, ["catalog"]);
            if (ready && snapshot is null && output.ExitCode == 0)
            {
                var catalog = JsonSerializer.Deserialize<CatalogProvider[]>(output.Output, UsageSnapshot.JsonOptions);
                var dark = UseDarkMarks();
                SettingsProviders.ItemsSource = catalog?.Select(provider => ProviderItem(provider.Id, provider.DisplayName, dark)).ToArray();
            }
        }
        catch (Exception error) when (error is Win32Exception or IOException or InvalidOperationException
            or JsonException or OperationCanceledException)
        {
            if (ready && snapshot is null) SettingsProviders.ItemsSource = null;
        }
    }

    private void ReadStartupSetting()
    {
        readingStartup = true;
        try
        {
            SettingsAutostart.IsOn = startup.IsEnabled;
            SettingsAutostart.IsEnabled = true;
            AutostartError.Visibility = Visibility.Collapsed;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException)
        {
            SettingsAutostart.IsEnabled = false;
            ShowStartupError("Could not read the Windows startup setting.");
        }
        finally
        {
            readingStartup = false;
        }
    }

    private void SettingsAutostartToggled(object sender, RoutedEventArgs args)
    {
        if (readingStartup || !ready) return;
        try
        {
            startup.SetEnabled(SettingsAutostart.IsOn);
            AutostartError.Visibility = Visibility.Collapsed;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or SecurityException)
        {
            ReadStartupSetting();
            ShowStartupError("Could not change the Windows startup setting.");
        }
    }

    private void ShowStartupError(string details)
    {
        AutostartError.Text = details;
        AutostartError.Visibility = Visibility.Visible;
    }

    private void LayoutClicked(object sender, RoutedEventArgs args)
    {
        wide = !wide;
        MoreProviders.IsExpanded = false;
        ApplyLayout();
        if (snapshot is not null) RenderProviders(snapshot);
        ResizeForLayout(center: false);
        BodyScroll.ChangeView(null, 0, null, disableAnimation: true);
    }

    private void ApplyLayout()
    {
        Dashboard.RequestedTheme = wide ? ElementTheme.Light : ElementTheme.Dark;
        Heading.Text = wide ? "VibeMeasure" : "Usage Monitor";
        ProviderLayout.Orientation = wide ? Orientation.Horizontal : Orientation.Vertical;
        ProviderScroll.HorizontalScrollMode = wide ? ScrollMode.Enabled : ScrollMode.Disabled;
        ProviderScroll.HorizontalScrollBarVisibility = wide
            ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled;
        MoreProviderScroll.MaxHeight = wide ? 110 : 170;
        if (!wide) ProviderScroll.ChangeView(0, null, null, disableAnimation: true);

        LayoutIcon.Glyph = wide ? "\uE8FD" : "\uECA5";
        var action = wide ? "Switch to compact view" : "Switch to wide view";
        AutomationProperties.SetName(LayoutButton, action);
        ToolTipService.SetToolTip(LayoutButton, action);

        if (AppWindowTitleBar.IsCustomizationSupported() && !accessibility.HighContrast)
        {
            var background = wide ? Color.FromArgb(255, 246, 247, 249) : Color.FromArgb(255, 32, 36, 38);
            var foreground = wide ? Color.FromArgb(255, 30, 35, 38) : Color.FromArgb(255, 245, 246, 246);
            AppWindow.TitleBar.PreferredTheme = wide ? TitleBarTheme.Light : TitleBarTheme.Dark;
            AppWindow.TitleBar.BackgroundColor = background;
            AppWindow.TitleBar.InactiveBackgroundColor = background;
            AppWindow.TitleBar.ButtonBackgroundColor = background;
            AppWindow.TitleBar.ButtonInactiveBackgroundColor = background;
            AppWindow.TitleBar.ForegroundColor = foreground;
            AppWindow.TitleBar.InactiveForegroundColor = foreground;
            AppWindow.TitleBar.ButtonForegroundColor = foreground;
            AppWindow.TitleBar.ButtonInactiveForegroundColor = foreground;
        }
    }

    private void ResizeForLayout(bool center)
    {
        var workArea = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var scale = Dashboard.XamlRoot.RasterizationScale;
        int Pixels(int value) => (int)Math.Round(value * scale);

        var measured = snapshot?.Providers.Where(ShowProvider).ToArray() ?? [];
        int QuotaHeight(ProviderSnapshot provider) =>
            provider.Windows.Length * 27 + (provider.Reported?.Quotas.Length ?? 0) * 49;
        var compactHeight = Math.Clamp(250 + measured.Sum(provider => 66 + QuotaHeight(provider)), 365, 900);
        var wideHeight = Math.Clamp(265 + measured.Select(provider => 66 + QuotaHeight(provider)
            + (provider.Plan is null ? 0 : 26))
            .DefaultIfEmpty(0).Max(), 340, 560);
        var width = Math.Min(workArea.Width, Pixels(wide ? 960 : 635));
        var height = Math.Min(workArea.Height, Pixels(wide ? wideHeight : compactHeight));
        var position = AppWindow.Position;
        var x = center ? workArea.X + (workArea.Width - width) / 2
            : Math.Clamp(position.X, workArea.X, workArea.X + workArea.Width - width);
        var y = center ? workArea.Y + (workArea.Height - height) / 2
            : Math.Clamp(position.Y, workArea.Y, workArea.Y + workArea.Height - height);
        AppWindow.MoveAndResize(new RectInt32(x, y, width, height));
    }

    private async Task RefreshAsync()
    {
        pending?.Cancel();
        using var request = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        pending = request;
        var mode = (string)((ComboBoxItem)Mode.SelectedItem).Tag;
        var currency = (string)((ComboBoxItem)Currency.SelectedItem).Tag;

        try
        {
            if (!File.Exists(db))
            {
                ShowMessage("No usage database", $"Open Codex to record a session, or import usage with vibemeasure-cli.\n{db}");
                return;
            }

            var output = await RunCliAsync(request.Token, currency == "USD"
                ? ["snapshot", "--db", db, "--mode", mode]
                : ["snapshot", "--db", db, "--mode", mode, "--currency", currency]);
            if (output.ExitCode != 0)
            {
                ShowMessage("Snapshot unavailable", "Could not read the usage database.", InfoBarSeverity.Error);
                return;
            }

            snapshot = UsageSnapshot.Parse(output.Output);
            RenderProviders(snapshot);
            if (layoutReady && !sizedForData)
            {
                sizedForData = true;
                ResizeForLayout(center: true);
            }
        }
        catch (OperationCanceledException)
        {
            if (ready && pending == request)
                ShowMessage("Refresh timed out", "Try refreshing the usage snapshot again.", InfoBarSeverity.Warning);
        }
        catch (Exception error) when (error is Win32Exception or IOException or InvalidOperationException or JsonException)
        {
            if (ready && pending == request)
                ShowMessage("Snapshot unavailable", error is Win32Exception
                    ? "Check that vibemeasure-cli.exe is beside the application or on PATH."
                    : "Could not read the usage snapshot.", InfoBarSeverity.Error);
        }
        finally
        {
            if (pending == request) pending = null;
        }
    }

    private async Task SyncAndRefreshAsync()
    {
        if (providerSync is not null) return;

        using var running = new CancellationTokenSource();
        providerSync = running;
        try
        {
            SetSyncStatus("Checking provider usage…");
            var issues = new List<string>();
            await SyncProvidersAsync(running.Token, issues);
            if (!ready) return;
            await SyncCodexAsync(running.Token, issues);
            if (!ready) return;
            SetSyncStatus(issues.Count == 0 ? null : "Some provider sources unavailable",
                issues.Count == 0 ? "Provider usage is checked automatically every minute."
                    : string.Join(Environment.NewLine, issues));
        }
        catch (OperationCanceledException) when (running.IsCancellationRequested) { }
        finally
        {
            providerSync = null;
        }
        if (ready) await RefreshAsync();
    }

    private async Task SyncProvidersAsync(CancellationToken cancellation, List<string> issues)
    {
        try
        {
            var output = await RunSyncCliAsync(cancellation, ["sync-providers", "--db", db]);
            var summary = ProviderSyncResult.Parse(output);
            if (summary.UnreadableFiles > 0)
                issues.Add($"{summary.UnreadableFiles} provider files or folders could not be read.");
            if (summary.DeferredAccounts > 0)
                issues.Add($"{summary.DeferredAccounts} account readings could not be refreshed.");
        }
        catch (Exception error) when (error is OperationCanceledException or Win32Exception
            or IOException or InvalidOperationException or JsonException)
        {
            cancellation.ThrowIfCancellationRequested();
            issues.Add("The additional provider import will be retried on the next refresh.");
        }
    }

    private async Task SyncCodexAsync(CancellationToken cancellation, List<string> issues)
    {
        try
        {
            CodexSyncResult summary;
            do
            {
                var output = await RunSyncCliAsync(cancellation, ["sync-codex", "--db", db, "--codex-home", codexHome]);
                summary = CodexSyncResult.Parse(output);
                if (summary.MoreWork && ready) await RefreshAsync();
            } while (summary.MoreWork && ready);

            if (summary.UnreadableFiles > 0)
                issues.Add($"{summary.UnreadableFiles} Codex files or folders could not be read.");
            if (summary.DeferredFiles > 0)
                issues.Add("Incomplete or changing Codex logs will be checked again.");
        }
        catch (Exception error) when (error is OperationCanceledException or Win32Exception
            or IOException or InvalidOperationException or JsonException)
        {
            cancellation.ThrowIfCancellationRequested();
            issues.Add("The Codex import will be retried on the next refresh.");
        }
    }

    private static async Task<string> RunSyncCliAsync(CancellationToken cancellation, string[] arguments)
    {
        using var batch = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        batch.CancelAfter(TimeSpan.FromMinutes(2));
        var output = await RunCliAsync(batch.Token, arguments);
        return output.ExitCode == 0 ? output.Output : throw new InvalidOperationException("Usage import failed.");
    }

    private static async Task<(int ExitCode, string Output)> RunCliAsync(
        CancellationToken cancellation, params string[] arguments)
    {
        var bundledCli = Path.Combine(AppContext.BaseDirectory, "vibemeasure-cli.exe");
        var start = new ProcessStartInfo(File.Exists(bundledCli) ? bundledCli : "vibemeasure-cli.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            StandardOutputEncoding = Encoding.UTF8,
        };
        foreach (var argument in arguments) start.ArgumentList.Add(argument);

        using var process = Process.Start(start) ?? throw new InvalidOperationException();
        using var stop = cancellation.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { /* The process already exited. */ }
            catch (Win32Exception) { /* Exit can race the cancellation callback. */ }
        });
        var output = await process.StandardOutput.ReadToEndAsync(cancellation);
        await process.WaitForExitAsync(cancellation);
        cancellation.ThrowIfCancellationRequested();
        return (process.ExitCode, output);
    }

    private void SetSyncStatus(string? status, string? details = null)
    {
        syncStatus = status;
        syncDetails = details;
        if (status is not null) StatusText.Text = status;
        ToolTipService.SetToolTip(StatusText, details);
    }

    private void RenderProviders(UsageSnapshot data)
    {
        var period = data.DisplayMode switch
        {
            "five_hours" => "last 5 hours",
            "one_week" => "this UTC week",
            "one_month" => "this UTC month",
            _ => "last 31 days",
        };
        var dark = UseDarkMarks();
        var items = data.Providers.Select(provider => (
            Provider: provider, ListItem: ProviderItem(provider.ToolId, provider.DisplayName, dark))).ToArray();
        var active = items.Where(item => ShowProvider(item.Provider))
            .Select(item => new DashboardProvider(item.Provider, item.ListItem, data.GeneratedAt, period, data.Currency, wide))
            .ToArray();
        var other = items.Where(item => !ShowProvider(item.Provider)).Select(item => item.ListItem).ToArray();

        Providers.ItemsSource = active;
        UnmeasuredProviders.ItemsSource = other;
        var settings = items.Select(item => item.ListItem).ToArray();
        if (SettingsProviders.ItemsSource is not ProviderListItem[] displayed || !displayed.SequenceEqual(settings))
            SettingsProviders.ItemsSource = settings;
        MoreProviders.Visibility = other.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        Message.Title = "No usage in this view";
        Message.Message = "Select another period or import usage into the database.";
        Message.Severity = InfoBarSeverity.Informational;
        Message.IsOpen = active.Length == 0;
        Message.Visibility = Message.IsOpen ? Visibility.Visible : Visibility.Collapsed;

        StatusText.Text = syncStatus ?? (active.Length > 0 ? "Snapshot loaded" : "No measurements");
        ToolTipService.SetToolTip(StatusText, syncDetails);
        StatusDot.Opacity = active.Length > 0 ? 1 : 0.45;
        UpdatedText.Text = $"Updated {data.GeneratedAt.ToLocalTime():t}";
        ToolTipService.SetToolTip(Updated, data.GeneratedAt.ToLocalTime().ToString("f"));
        Updated.Visibility = Visibility.Visible;
    }

    private static bool ShowProvider(ProviderSnapshot provider) => !provider.NeedsManualSetup || provider.Plan is not null;

    private ProviderListItem ProviderItem(string toolId, string name, bool dark)
    {
        if (!marks.TryGetValue((toolId, dark), out var mark))
        {
            mark = ProviderMark.For(toolId, dark);
            marks.Add((toolId, dark), mark);
        }
        return new ProviderListItem(name, mark);
    }

    private bool UseDarkMarks()
    {
        if (!accessibility.HighContrast) return !wide;
        var background = new UISettings().GetColorValue(UIColorType.Background);
        return (299 * background.R + 587 * background.G + 114 * background.B) < 128_000;
    }

    private void ShowMessage(string title, string details, InfoBarSeverity severity = InfoBarSeverity.Informational)
    {
        snapshot = null;
        Providers.ItemsSource = null;
        MoreProviders.Visibility = Visibility.Collapsed;
        Updated.Visibility = Visibility.Collapsed;
        StatusText.Text = syncStatus ?? title;
        StatusDot.Opacity = 0.45;
        Message.Title = title;
        Message.Message = details;
        Message.Severity = severity;
        Message.Visibility = Visibility.Visible;
        Message.IsOpen = true;
    }

    private sealed record CatalogProvider(string Id, string DisplayName);
}
