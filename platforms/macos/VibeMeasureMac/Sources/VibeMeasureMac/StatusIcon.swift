import AppKit

@MainActor
enum StatusIcon {
    static let image: NSImage = {
        // SwiftPM's native build copies the catalog; Xcode compiles the same SVG.
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        let source = bundle.url(forResource: "pegelbot-symbolic", withExtension: "svg",
                                subdirectory: "Assets.xcassets/StatusIcon.imageset")
        let loaded = bundle.image(forResource: "StatusIcon") ?? source.flatMap(NSImage.init(contentsOf:))
        #else
        let loaded = Bundle.main.image(forResource: "StatusIcon")
        #endif
        guard let image = loaded else {
            preconditionFailure("Missing bundled VibeMeasure status icon")
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    #if SWIFT_PACKAGE
    static func setDevelopmentDockIcon() {
        // A swift run executable has no app bundle from which the Dock can load the icon.
        let bundle = Bundle.module
        let source = bundle.url(forResource: "pegelbot-512", withExtension: "png",
                                subdirectory: "Assets.xcassets/AppIcon.appiconset")
        if let icon = bundle.image(forResource: "AppIcon") ?? source.flatMap(NSImage.init(contentsOf:)) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    #endif
}
