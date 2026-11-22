using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace VibeMeasure.Windows;

public sealed record ProviderListItem(string Name, ProviderMark Mark);

public sealed class ProviderMark
{
    private ProviderMark(BitmapImage? image = null, string letter = "", Color background = default, bool whiteText = false)
    {
        Image = image;
        Letter = letter;
        if (background.A > 0)
            Background = new SolidColorBrush(background);
        if (letter.Length > 0)
            Foreground = new SolidColorBrush(whiteText ? Color.FromArgb(255, 255, 255, 255) : Color.FromArgb(255, 0, 0, 0));
    }

    public BitmapImage? Image { get; }
    public string Letter { get; }
    public Brush? Background { get; }
    public Brush? Foreground { get; }
    public Thickness ImagePadding => new(Background is null ? 0 : 2);
    public Visibility ImageVisibility => Image is null ? Visibility.Collapsed : Visibility.Visible;
    public Visibility LetterVisibility => Letter.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    public Visibility GenericVisibility => Image is null && Letter.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

    internal static ProviderMark For(string toolId, bool dark)
    {
        // Provider IDs are also used as directory names in the shared image catalog.
        if (toolId.Length > 0 && toolId.All(ch => char.IsAsciiLetterOrDigit(ch) || ch == '-'))
        {
            var directory = $"Assets/Providers/provider-{toolId}.imageset";
            if (dark && Load($"{directory}/mark-dark.png") is BitmapImage darkImage)
                return new ProviderMark(darkImage);
            if (Load($"{directory}/mark.png") is BitmapImage image)
            {
                // The shared Kimi and Qwen marks only have dark artwork.
                var backdrop = dark && toolId is ("kimi-cli" or "qwen-code")
                    ? Color.FromArgb(255, 221, 229, 242) : default;
                return new ProviderMark(image, background: backdrop);
            }
        }

        return toolId switch
        {
            "factory-droid" => new ProviderMark(letter: "F", background: Color.FromArgb(255, 255, 150, 82)),
            "auggie" => new ProviderMark(letter: "A", background: Color.FromArgb(255, 64, 87, 199), whiteText: true),
            "pi" => new ProviderMark(letter: "π", background: Color.FromArgb(255, 82, 54, 158), whiteText: true),
            "kilo" => new ProviderMark(letter: "K", background: Color.FromArgb(255, 255, 224, 71)),
            _ => new ProviderMark(),
        };
    }

    private static BitmapImage? Load(string relativePath) =>
        File.Exists(Path.Combine(AppContext.BaseDirectory, relativePath))
            ? new BitmapImage(new Uri($"ms-appx:///{relativePath}"))
            : null;
}
