using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace VibeMeasure.Windows;

public sealed partial class MainWindow
{
    private sealed record AlertRule(DateOnly? EndDate, int? DaysBefore, int? UsedPercent);
    private sealed record AlertProvider(string Id, string Name, AlertRule Rule);

    private bool checkingAlerts;

    private async Task CheckAlertsAsync()
    {
        if (checkingAlerts || !File.Exists(db)) return;
        checkingAlerts = true;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            var result = await RunCliProcessAsync(timeout.Token, ["check-alerts", "--db", db, "--desktop-pipe"], message =>
            {
                if (!ready) throw new OperationCanceledException();
                deliverAlert(message);
            });
            if (result.ExitCode != 0) throw new InvalidOperationException("Alert check failed.");
        }
        catch (Exception error) when (error is Win32Exception or IOException or JsonException
            or InvalidOperationException or OperationCanceledException or COMException or UnauthorizedAccessException)
        {
            if (ready) SetSyncStatus("Notification check failed", "Check Windows notification settings. VibeMeasure will retry.");
        }
        finally { checkingAlerts = false; }
    }

    private async void EditAlerts(object sender, RoutedEventArgs args)
    {
        SettingsFlyout.Hide();
        using var lookup = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        try
        {
            var result = await RunCliAsync(lookup.Token, "alert-settings", "--db", db);
            var providers = result.ExitCode == 0
                ? JsonSerializer.Deserialize<AlertProvider[]>(result.Output, UsageSnapshot.JsonOptions) : null;
            if (providers is not { Length: > 0 }) throw new InvalidOperationException();
            var picker = new ComboBox { Header = "Provider", ItemsSource = providers, DisplayMemberPath = "Name" };
            var end = new CalendarDatePicker { Header = "Subscription end", PlaceholderText = "Choose a date" };
            var days = new TextBox { Header = "Days before end (0–365)", PlaceholderText = "Off" };
            var percent = new TextBox { Header = "Usage threshold (1–100%)", PlaceholderText = "Off" };
            var errorLabel = new TextBlock { TextWrapping = TextWrapping.Wrap };
            picker.SelectionChanged += (_, _) =>
            {
                if (picker.SelectedItem is not AlertProvider item) return;
                end.Date = item.Rule.EndDate is { } date ? new DateTimeOffset(date.ToDateTime(TimeOnly.MinValue)) : null;
                days.Text = item.Rule.DaysBefore?.ToString() ?? "";
                percent.Text = item.Rule.UsedPercent?.ToString() ?? "";
                errorLabel.Text = "";
            };
            picker.SelectedIndex = 0;
            var panel = new StackPanel { Spacing = 8 };
            foreach (var field in new UIElement[] { picker, end, days, percent, errorLabel }) panel.Children.Add(field);
            var dialog = new ContentDialog
            {
                Title = "Notification settings", Content = new ScrollViewer { Content = panel },
                PrimaryButtonText = "Save", CloseButtonText = "Cancel", XamlRoot = Dashboard.XamlRoot,
            };
            dialog.PrimaryButtonClick += async (_, click) =>
            {
                var defer = click.GetDeferral();
                try
                {
                    var item = (AlertProvider)picker.SelectedItem;
                    var command = new List<string> { "set-alert", "--db", db, "--tool", item.Id };
                    if (end.Date is { } date)
                        command.AddRange(["--end-date", date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture)]);
                    if (!string.IsNullOrWhiteSpace(days.Text)) command.AddRange(["--days-before", days.Text.Trim()]);
                    if (!string.IsNullOrWhiteSpace(percent.Text)) command.AddRange(["--used-percent", percent.Text.Trim()]);
                    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
                    var saved = await RunCliAsync(timeout.Token, command.ToArray());
                    if (saved.ExitCode != 0)
                    {
                        click.Cancel = true;
                        errorLabel.Text = "Enter whole numbers in the indicated ranges and choose an end date for the reminder. Leave a threshold blank to disable it.";
                    }
                }
                catch (Exception error) when (error is IOException or Win32Exception or InvalidOperationException or OperationCanceledException)
                {
                    click.Cancel = true;
                    errorLabel.Text = "Could not save notification settings.";
                }
                finally { defer.Complete(); }
            };
            if (await dialog.ShowAsync() == ContentDialogResult.Primary) await CheckAlertsAsync();
        }
        catch (Exception error) when (error is IOException or Win32Exception or InvalidOperationException
            or JsonException or OperationCanceledException or COMException)
        {
            SetSyncStatus("Could not open notification settings", "Check that vibemeasure-cli is installed and the database is writable.");
        }
    }
}
