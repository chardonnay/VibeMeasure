using System.Text.Json;
using System.Globalization;
using Microsoft.UI.Xaml;

namespace VibeMeasure.Windows;

internal sealed record UsageSnapshot(
    DateTimeOffset GeneratedAt, string DisplayMode, ProviderSnapshot[] Providers, string Currency = "USD")
{
    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        RespectNullableAnnotations = true,
        RespectRequiredConstructorParameters = true,
    };

    public static UsageSnapshot Parse(string json) =>
        JsonSerializer.Deserialize<UsageSnapshot>(json, JsonOptions)
        ?? throw new JsonException("The snapshot is empty.");
}

internal sealed record CodexSyncResult(bool SourceFound, int DeferredFiles, int UnreadableFiles, bool MoreWork)
{
    public static CodexSyncResult Parse(string json) =>
        JsonSerializer.Deserialize<CodexSyncResult>(json, UsageSnapshot.JsonOptions)
        ?? throw new JsonException("The import summary is empty.");
}

internal sealed record ProviderSyncResult(int ProvidersUpdated, int UnreadableFiles, int DeferredAccounts)
{
    public static ProviderSyncResult Parse(string json) =>
        JsonSerializer.Deserialize<ProviderSyncResult>(json, UsageSnapshot.JsonOptions)
        ?? throw new JsonException("The provider import summary is empty.");
}

internal sealed record ProviderSnapshot(
    string ToolId, string DisplayName, QuotaSnapshot[] Windows, TokenUsage Usage, bool NeedsManualSetup,
    ProviderPlan? Plan = null, CostEstimate? EstimatedCost = null, ReportedUsage? Reported = null);

internal sealed record ReportedUsage(
    ulong? Tokens, bool ConversationTokens, double? EstimatedUsd, double? Credits,
    string? CreditUnit, ReportedQuota[] Quotas, MeasurementSource Source);

internal sealed record ReportedQuota(
    string Name, double? UsedPercent, DateTimeOffset? ResetsAt, double? Value, string? Unit, string Detail);

internal sealed record TokenUsage(ulong TotalTokens, string[] SourceLabels);

internal sealed record ProviderPlan(string Name, MeasurementSource Source)
{
    public string Details => $"{(Source.Kind == "manual" ? "Plan entered manually" : "Plan reported by the provider")}\n{Source.Details}";
}

internal sealed record MeasurementSource(string Kind, string Status, string Label, DateTimeOffset FetchedAt)
{
    public string Details => $"{Label} · {FetchedAt.ToLocalTime():g} ({Status})";
}

internal sealed record CostEstimate(
    string Status, double? Amount = null, string? Reason = null,
    MeasurementSource[]? PricingSources = null, MeasurementSource[]? ExchangeRateSources = null)
{
    public string Display(string currency)
    {
        if (Status != "api_equivalent_estimate" || Amount is not double amount)
            return "Est. —";

        var format = (NumberFormatInfo)CultureInfo.CurrentCulture.NumberFormat.Clone();
        format.CurrencySymbol = currency switch { "USD" => "$", "EUR" => "€", _ => currency };
        if (amount is > 0 and < 0.0001) return $"Est. <{0.0001.ToString("C4", format)}";
        var precision = amount is > 0 and < 0.01 ? "C4" : "C2";
        return $"Est. {amount.ToString(precision, format)}";
    }

    public string Details(string period)
    {
        var scope = $"API-equivalent estimate for recorded tokens · {period}";
        if (Status != "api_equivalent_estimate")
            return $"{scope}\n{Reason ?? "Pricing unavailable"}";

        var lines = new List<string> { scope, "Subscription charges and invoices are separate." };
        lines.AddRange((PricingSources ?? []).Select(source => $"Price: {source.Details}"));
        lines.AddRange((ExchangeRateSources ?? []).Select(source => $"FX: {source.Details}"));
        return string.Join(Environment.NewLine, lines);
    }
}

internal sealed record QuotaSnapshot(
    JsonElement WindowKind, DateTimeOffset ResetAt, double? UsedPercent, ulong? UsedTokens, ulong? TokenLimit,
    CostEstimate? EstimatedCost = null)
{
    public string Label => WindowKind.ValueKind switch
    {
        JsonValueKind.String => WindowKind.GetString() switch
        {
            "five_hours" => "5-Hour",
            "one_week" => "Weekly",
            "one_month" => "Monthly",
            _ => "Quota",
        },
        JsonValueKind.Object when WindowKind.TryGetProperty("custom_minutes", out var minutes) =>
            $"{minutes} min",
        _ => "Quota",
    };

    public double? Percentage => UsedPercent ?? (UsedTokens is ulong used && TokenLimit is > 0
        ? used * 100.0 / TokenLimit.Value
        : null);

    public string ShortLabel => Label switch
    {
        "5-Hour" => "5h",
        "Weekly" => "1w",
        "Monthly" => "1mo",
        _ when WindowKind.ValueKind == JsonValueKind.Object &&
            WindowKind.TryGetProperty("custom_minutes", out var value) && value.TryGetInt64(out var minutes) =>
            minutes % 60 == 0 ? $"{minutes / 60}h" : $"{minutes}m",
        _ => Label,
    };
}

public sealed class DashboardProvider
{
    internal DashboardProvider(
        ProviderSnapshot provider, ProviderListItem identity, DateTimeOffset updated, string period, string currency, bool wide)
    {
        FullName = identity.Name;
        Mark = identity.Mark;
        Name = wide ? provider.ToolId switch
        {
            "antigravity" => "Antigravity",
            "auggie" => "Auggie",
            _ => FullName,
        } : FullName;
        NameSize = wide ? 15 : 17;
        Width = wide ? 178 : double.NaN;
        Divider = wide ? new Thickness(0, 0, 1, 0) : new Thickness(0, 0, 0, 1);
        Padding = wide ? new Thickness(12, 14, 12, 14) : new Thickness(9, 10, 15, 10);
        var reported = provider.Reported;
        StatusVisibility = wide || (provider.Windows.Length == 0 && reported is null)
            ? Visibility.Collapsed : Visibility.Visible;
        PlanName = provider.Plan?.Name ?? "";
        PlanDetails = provider.Plan?.Details ?? "";
        PlanVisibility = provider.Plan is null ? Visibility.Collapsed : Visibility.Visible;
        PlanRow = wide ? 1 : 0;
        PlanColumn = wide ? 1 : 2;
        Quotas = provider.Windows.Select(window => new DashboardQuota(window, updated, currency, wide)).ToArray();
        ReportedQuotas = reported?.Quotas.Select(quota => new DashboardReportedQuota(quota, updated, wide)).ToArray() ?? [];
        ReportedQuotaUnavailable = reported is not null && ReportedQuotas.Length == 0
            ? Visibility.Visible : Visibility.Collapsed;
        var sourceDetails = reported?.Source.Details ?? "";
        var readings = new List<string>();
        if (reported?.Tokens is ulong recorded)
            readings.Add($"{(reported.ConversationTokens ? "Conversation" : "Recorded")} · {recorded:N0} tokens");
        if (reported?.EstimatedUsd is double usd)
            readings.Add($"Source est. {ReportedUsd(usd)}");
        if (reported?.Credits is double credits)
            readings.Add($"Spent {credits:N2} {reported.CreditUnit}");
        ReportedSummary = string.Join(Environment.NewLine, readings);
        ReportedDetails = $"From available provider records\n{sourceDetails}";
        ReportedVisibility = readings.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        TokenVisibility = provider.Usage.SourceLabels.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        var tokenTotal = $"{provider.Usage.TotalTokens:N0} tokens";
        TokenSummary = wide ? tokenTotal : $"{tokenTotal} · {period}";
        TokenDetails = string.Join(Environment.NewLine, new[] { period }.Concat(provider.Usage.SourceLabels));

        var cycle = wide && provider.EstimatedCost?.Amount is null
            ? provider.Windows.Where(window => window.EstimatedCost?.Amount is not null)
                .MaxBy(window => window.ResetAt)
            : null;
        var cost = cycle?.EstimatedCost ?? provider.EstimatedCost;
        CostText = cycle is null ? cost?.Display(currency) ?? "" : $"{cycle.Label} · {cost?.Display(currency)}";
        CostDetails = cost?.Details(cycle is null ? period : $"{cycle.Label} cycle to snapshot time") ?? "";
        CostVisibility = cost is null ? Visibility.Collapsed : Visibility.Visible;
        CostRow = wide ? 1 : 0;
        CostColumn = wide ? 0 : 1;
    }

    public string Name { get; }
    public string FullName { get; }
    public ProviderMark Mark { get; }
    public double NameSize { get; }
    public double Width { get; }
    public Thickness Divider { get; }
    public Thickness Padding { get; }
    public Visibility StatusVisibility { get; }
    public string PlanName { get; }
    public string PlanDetails { get; }
    public Visibility PlanVisibility { get; }
    public int PlanRow { get; }
    public int PlanColumn { get; }
    public DashboardQuota[] Quotas { get; }
    public DashboardReportedQuota[] ReportedQuotas { get; }
    public Visibility ReportedQuotaUnavailable { get; }
    public string ReportedSummary { get; }
    public string ReportedDetails { get; }
    public Visibility ReportedVisibility { get; }
    public string TokenSummary { get; }
    public string TokenDetails { get; }
    public Visibility TokenVisibility { get; }
    public string CostText { get; }
    public string CostDetails { get; }
    public Visibility CostVisibility { get; }
    public int CostRow { get; }
    public int CostColumn { get; }

    internal static string ReportedUsd(double amount) => amount switch
    {
        > 0 and < 0.0001 => $"<{0.0001:N4} USD",
        > 0 and < 0.01 => $"{amount:N4} USD",
        _ => $"{amount:N2} USD",
    };
}

public sealed class DashboardReportedQuota
{
    internal DashboardReportedQuota(ReportedQuota quota, DateTimeOffset updated, bool wide)
    {
        Name = quota.Name;
        Progress = Math.Clamp(quota.UsedPercent ?? 0, 0, 100);
        ProgressVisibility = quota.UsedPercent.HasValue ? Visibility.Visible : Visibility.Collapsed;
        var value = quota.Value is double amount ? quota.Unit switch
        {
            "usd_remaining" => $"{DashboardProvider.ReportedUsd(amount)} left",
            "usd_spent" => $"{DashboardProvider.ReportedUsd(amount)} spent",
            "remaining" => $"{amount:N2} left",
            "credits" => $"{amount:N2} credits",
            _ => "",
        } : "";
        var percentage = quota.UsedPercent is double percent ? $"{percent:0.#}%" : "";
        var fullValue = string.Join(" · ", new[] { percentage, value }.Where(text => text.Length > 0));
        if (fullValue.Length == 0) fullValue = "—";
        Value = wide && percentage.Length > 0 ? percentage : fullValue;
        Reset = quota.ResetsAt is DateTimeOffset reset
            ? reset > updated ? $"Resets in {DashboardQuota.FormatRemaining(reset - updated)}" : "Awaiting updated quota"
            : quota.Detail.StartsWith("resets upon renewal", StringComparison.OrdinalIgnoreCase)
                ? quota.Detail : "";
        ResetVisibility = Reset.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        Details = $"{Name} · {fullValue}\n{quota.Detail}";
        if (quota.ResetsAt is DateTimeOffset deadline)
            Details += $"\nReset: {deadline.ToLocalTime():g}";
    }

    public string Name { get; }
    public string Value { get; }
    public string Reset { get; }
    public string Details { get; }
    public double Progress { get; }
    public Visibility ProgressVisibility { get; }
    public Visibility ResetVisibility { get; }
}

public sealed class DashboardQuota
{
    internal DashboardQuota(QuotaSnapshot window, DateTimeOffset updated, string currency, bool wide)
    {
        Label = wide ? window.ShortLabel : window.Label;
        var percentage = window.Percentage;
        Value = percentage is double percent ? $"{percent:0.#}%" : "—";
        Progress = Math.Clamp(percentage ?? 0, 0, 100);
        ProgressVisibility = percentage.HasValue ? Visibility.Visible : Visibility.Collapsed;
        ResetLabel = $"Resets in {FormatRemaining(window.ResetAt - updated)}";
        ResetDetails = $"{window.Label} · {Value} · Resets {window.ResetAt.ToLocalTime():g}";
        AccessibleName = $"{window.Label} quota, {Value} used. {ResetLabel}";
        ResetColumn = new GridLength(wide ? 0 : 118);
        ResetVisibility = wide ? Visibility.Collapsed : Visibility.Visible;
        LabelColumn = new GridLength(wide ? 43 : 59);
        ValueColumn = new GridLength(wide ? 38 : 49);
        ColumnSpacing = wide ? 6 : 11;
        var showCost = !wide && window.EstimatedCost is not null;
        CostText = window.EstimatedCost?.Display(currency) ?? "";
        CostDetails = window.EstimatedCost?.Details($"{window.Label} cycle to snapshot time") ?? "";
        if (wide && window.EstimatedCost is not null)
            ResetDetails += $"\n{CostText}\n{CostDetails}";
        CostColumn = new GridLength(showCost ? 97 : 0);
        CostVisibility = showCost ? Visibility.Visible : Visibility.Collapsed;
    }

    public string Label { get; }
    public string Value { get; }
    public double Progress { get; }
    public Visibility ProgressVisibility { get; }
    public string ResetLabel { get; }
    public string ResetDetails { get; }
    public string AccessibleName { get; }
    public GridLength ResetColumn { get; }
    public Visibility ResetVisibility { get; }
    public GridLength LabelColumn { get; }
    public GridLength ValueColumn { get; }
    public double ColumnSpacing { get; }
    public string CostText { get; }
    public string CostDetails { get; }
    public GridLength CostColumn { get; }
    public Visibility CostVisibility { get; }

    internal static string FormatRemaining(TimeSpan remaining) => remaining switch
    {
        { TotalDays: >= 1 } => $"{remaining.Days}d {remaining.Hours}h",
        { TotalHours: >= 1 } => $"{remaining.Hours}h {remaining.Minutes}m",
        { TotalMinutes: >= 1 } => $"{remaining.Minutes}m",
        _ => "< 1m",
    };
}
