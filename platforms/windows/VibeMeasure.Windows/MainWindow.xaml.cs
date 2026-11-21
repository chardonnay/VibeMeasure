using System.ComponentModel;
using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace VibeMeasure.Windows;

public sealed partial class MainWindow : Window
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMinutes(1) };
    private CancellationTokenSource? pending;
    private bool ready;

    public MainWindow()
    {
        InitializeComponent();
        ready = true;
        timer.Tick += (_, _) => _ = RefreshAsync();
        Closed += (_, _) =>
        {
            ready = false;
            timer.Stop();
            pending?.Cancel();
        };
        timer.Start();
        _ = RefreshAsync();
    }

    private void ModeChanged(object sender, SelectionChangedEventArgs args)
    {
        if (ready) _ = RefreshAsync();
    }

    private void RefreshClicked(object sender, RoutedEventArgs args) => _ = RefreshAsync();

    private async Task RefreshAsync()
    {
        pending?.Cancel();
        using var request = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        pending = request;
        var db = Environment.GetEnvironmentVariable("VIBEMEASURE_DB")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                            "VibeMeasure", "vibemeasure.sqlite");
        try
        {
            if (!File.Exists(db))
            {
                Summary.Text = $"No usage database at {db}. Import usage with vibemeasure-cli.";
                return;
            }
            var bundledCli = Path.Combine(AppContext.BaseDirectory, "vibemeasure-cli.exe");
            var start = new ProcessStartInfo(File.Exists(bundledCli) ? bundledCli : "vibemeasure-cli.exe")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                StandardOutputEncoding = System.Text.Encoding.UTF8,
            };
            var mode = (string)((ComboBoxItem)Mode.SelectedItem).Tag;
            foreach (var argument in new[] { "snapshot", "--db", db, "--mode", mode, "--text" })
                start.ArgumentList.Add(argument);

            using var process = Process.Start(start) ?? throw new InvalidOperationException();
            using var stop = request.Token.Register(() =>
            {
                try { if (!process.HasExited) process.Kill(); }
                catch (InvalidOperationException) { /* The process already exited. */ }
                catch (Win32Exception) { /* Exit can race the cancellation callback. */ }
            });
            var output = await process.StandardOutput.ReadToEndAsync(request.Token);
            await process.WaitForExitAsync(request.Token);
            request.Token.ThrowIfCancellationRequested();
            Summary.Text = process.ExitCode == 0 ? output.TrimEnd() : "Could not read the usage database.";
        }
        catch (OperationCanceledException)
        {
            if (ready && pending == request) Summary.Text = "The snapshot request timed out.";
        }
        catch (Exception error) when (error is Win32Exception or IOException or InvalidOperationException)
        {
            if (pending == request) Summary.Text = $"Could not read usage. {error.Message}";
        }
        finally
        {
            if (pending == request) pending = null;
        }
    }
}
