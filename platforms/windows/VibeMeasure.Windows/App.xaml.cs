using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.Win32;

namespace VibeMeasure.Windows;

public partial class App : Application
{
    private MainWindow? window;
    private TrayMenu? tray;
    private EventWaitHandle? openWindowSignal;
    private RegisteredWaitHandle? activationWait;
    private bool exiting;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var database = Environment.GetEnvironmentVariable("VIBEMEASURE_DB")
            ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                            "VibeMeasure", "vibemeasure.sqlite");
        var background = Environment.GetCommandLineArgs().Skip(1).Contains(StartupRegistration.BackgroundArgument);

        // Two launches with the same database share one importer. A normal launch
        // can signal the existing tray instance even when its window is hidden.
        var profileId = Convert.ToHexString(SHA256.HashData(
            Encoding.UTF8.GetBytes(Path.GetFullPath(database).ToUpperInvariant())));
        var signal = new EventWaitHandle(false, EventResetMode.AutoReset,
            $@"Local\VibeMeasure.OpenDashboard.{profileId}", out var firstInstance);
        if (!firstInstance)
        {
            using (signal)
            {
                if (!background) signal.Set();
            }
            Exit();
            return;
        }
        openWindowSignal = signal;

        var startup = new StartupRegistration(Registry.CurrentUser,
            Path.Combine(AppContext.BaseDirectory, "VibeMeasure.Windows.exe"));
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        tray = new TrayMenu(startup, ShowDashboard, () => dispatcher.TryEnqueue(Quit));
        var dashboard = new MainWindow(database, startup, tray.ShowAlert);
        window = dashboard;
        activationWait = ThreadPool.RegisterWaitForSingleObject(signal, (_, _) =>
        {
            dispatcher.TryEnqueue(ShowDashboard);
        }, null, Timeout.Infinite, executeOnlyOnce: false);

        dashboard.AppWindow.Closing += (_, close) =>
        {
            if (exiting) return;
            close.Cancel = true;
            dashboard.AppWindow.Hide();
        };
        dashboard.Closed += (_, _) =>
        {
            window = null;
            tray?.Dispose();
            activationWait?.Unregister(null);
            openWindowSignal?.Dispose();
            Exit();
        };

        if (!background) ShowDashboard();
        dashboard.StartUpdates();
    }

    private void ShowDashboard()
    {
        if (window is not { } dashboard || exiting) return;
        if (!dashboard.AppWindow.IsVisible) dashboard.AppWindow.Show();
        if (dashboard.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
        dashboard.Activate();
    }

    private void Quit()
    {
        exiting = true;
        window?.Close();
    }
}

