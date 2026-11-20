import AppKit

enum AppPalette {
    static let window = adaptive(0xf1f3f6, 0x262b32)
    static let titleBar = adaptive(0xfafbfa, 0x1f252e)
    static let titleBarRule = adaptive(0xc9d2de, 0x465365, highContrast: (0xa8b4c4, 0x74869e))
    static let chrome = adaptive(0xf0f3f7, 0x272e38)
    static let sidebarTint = adaptive(0xecf0f5, 0x272e38, opacity: 0.94)
    static let editor = adaptive(0xfcfcfb, 0x232a33)
    static let gutter = adaptive(0xf2f5f9, 0x272e38)
    static let preview = adaptive(0xe9edf3, 0x202631)

    static let text = adaptive(0x283442, 0xced6e1)
    static let secondaryText = adaptive(0x525f70, 0xa5b2c3)
    static let mutedText = adaptive(0x626f81, 0x91a1b6)
    static let disabledText = adaptive(0x808c9c, 0x78889e)
    static let rule = adaptive(0xd5dce7, 0x394453, highContrast: (0xa8b4c4, 0x74869e))
    static let control = adaptive(0xe5eaf2, 0x303a47)
    static let hover = adaptive(0xdfe7f2, 0x394658)

    static let accent = adaptive(0x3c5c85, 0xa0b8d9, highContrast: (0x314e75, 0xd0def0))
    static let accentSurface = adaptive(0xe0e9f5, 0x32435b)
    static let action = adaptive(0x45688f, 0x3b5273)
    static let actionPressed = adaptive(0x375879, 0x445f85)
    static let actionText = adaptive(0xf8fafc, 0xecf2fa)
    static let selection = adaptive(0xdde8f6, 0x33445c, highContrast: (0xc5d8ec, 0x4b5d75))
    static let inactiveSelection = adaptive(0xe1e7ef, 0x343e4c)
    static let selectionText = adaptive(0x293c54, 0xe1eafa)
    static let currentLine = adaptive(0xedf2f8, 0x2a3544)

    static let syntaxCommand = accent
    static let syntaxComment = adaptive(0x5f6c7d, 0x9eacba)
    static let syntaxMath = adaptive(0x81573b, 0xcdb199)
    static let syntaxArgument = adaptive(0x526780, 0xa3b3c9)
    static let success = adaptive(0x4b6789, 0x9bb2ce)
    static let warning = adaptive(0x896132, 0xc8aa86)
    static let error = adaptive(0x9b504b, 0xd9a19a)
    static let pdfHighlight = rgb(0xe8c880, opacity: 0.42)

    private static func adaptive(_ light: UInt32, _ dark: UInt32, opacity: CGFloat = 1,
                                 highContrast: (UInt32, UInt32)? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua,
                                               .darkAqua, .aqua]) {
            case .accessibilityHighContrastDarkAqua: rgb(highContrast?.1 ?? dark, opacity: opacity)
            case .accessibilityHighContrastAqua: rgb(highContrast?.0 ?? light, opacity: opacity)
            case .darkAqua: rgb(dark, opacity: opacity)
            default: rgb(light, opacity: opacity)
            }
        }
    }

    private static func rgb(_ value: UInt32, opacity: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: opacity)
    }
}
