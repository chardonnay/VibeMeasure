import AppKit
import SwiftUI

struct ProviderMark: View {
    let provider: ProviderSettings
    @Environment(\.colorScheme) private var colorScheme

    static func logo(for id: String, dark: Bool) -> NSImage? {
        let name = "provider-\(id)"
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        // The native SwiftPM build system can copy the catalog without compiling it.
        if let compiled = bundle.image(forResource: name) { return compiled }
        let directory = "Assets.xcassets/\(name).imageset"
        let names = dark ? ["mark-dark", "mark"] : ["mark"]
        let url = names.lazy.compactMap { bundle.url(forResource: $0, withExtension: "png", subdirectory: directory) }.first
        return url.flatMap(NSImage.init(contentsOf:))
        #else
        return Bundle.main.image(forResource: name)
        #endif
    }

    var body: some View {
        let useDefaultMark = ProviderSettingsStore.usesDefaultMark(provider)

        Group {
            if useDefaultMark, let logo = Self.logo(for: provider.id, dark: colorScheme == .dark) {
                Image(nsImage: logo)
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
            } else if useDefaultMark, provider.id == "pi" {
                lettermark("π", foreground: .white, background: Color(red: 0.32, green: 0.21, blue: 0.62))
            } else if useDefaultMark, provider.id == "kilo" {
                lettermark("K", foreground: .black, background: Color(red: 1, green: 0.88, blue: 0.28))
            } else if useDefaultMark, provider.id == "factory-droid" {
                lettermark("F", foreground: .black, background: Color(red: 1, green: 0.59, blue: 0.32))
            } else if useDefaultMark, provider.id == "auggie" {
                lettermark("A", foreground: .white, background: Color(red: 0.25, green: 0.34, blue: 0.78))
            } else {
                Image(systemName: provider.symbolName.isEmpty ? "terminal" : provider.symbolName)
                    .foregroundStyle(provider.isEnabled ? provider.dataSource.color : .secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }

    private func lettermark(_ letter: String, foreground: Color, background: Color) -> some View {
        Text(letter)
            .font(.system(size: 12, weight: .heavy, design: .monospaced))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(background, in: RoundedRectangle(cornerRadius: 4))
    }
}
