import SwiftUI
import AppKit

enum AppTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case signal
    case carbon
    case glacier

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .signal: "Signal"
        case .carbon: "Carbon"
        case .glacier: "Glacier"
        }
    }

    var description: String {
        switch self {
        case .system: "macOS surfaces, with near-black dark mode."
        case .signal: "Cool slate surfaces with a quiet teal signal."
        case .carbon: "Quiet graphite with a sharp lime signal."
        case .glacier: "Cool blue-gray surfaces with an ice-blue signal."
        }
    }

    var palette: ThemePalette {
        switch self {
        case .system: .system
        case .signal: .signal
        case .carbon: .carbon
        case .glacier: .glacier
        }
    }

    static func restoring(_ stored: String?) -> AppTheme? {
        switch stored {
        case "konishi": .signal
        case "ember": .carbon
        case "lumen": .glacier
        default: stored.flatMap(AppTheme.init(rawValue:))
        }
    }
}

struct ThemePalette {
    let canvas: Color
    let sidebar: Color
    let surface: Color
    let surfaceRaised: Color
    let border: Color
    let signal: Color

    static let system = ThemePalette(
        canvas: systemColor(.underPageBackgroundColor, dark: 0x000000),
        sidebar: systemColor(.controlBackgroundColor, dark: 0x080808),
        surface: systemColor(.controlBackgroundColor, dark: 0x111111),
        surfaceRaised: systemColor(.controlBackgroundColor, dark: 0x191919),
        border: systemColor(.separatorColor, dark: 0x2B2B2B),
        signal: .accentColor
    )

    static let signal = ThemePalette(
        canvas: adaptive(light: 0xF1F5F3, dark: 0x101719),
        sidebar: adaptive(light: 0xE9F0EE, dark: 0x151F20),
        surface: adaptive(light: 0xF7FAF8, dark: 0x182324),
        surfaceRaised: adaptive(light: 0xFFFFFF, dark: 0x202C2E),
        border: adaptive(light: 0xD6E0DC, dark: 0x2B393A),
        signal: adaptive(light: 0x157B70, dark: 0x62D6C4)
    )

    static let carbon = ThemePalette(
        canvas: adaptive(light: 0xF1F3F0, dark: 0x101210),
        sidebar: adaptive(light: 0xE7EAE6, dark: 0x171A17),
        surface: adaptive(light: 0xF7F8F5, dark: 0x1E221E),
        surfaceRaised: adaptive(light: 0xFFFFFF, dark: 0x282D28),
        border: adaptive(light: 0xD3D8D1, dark: 0x3A423A),
        signal: adaptive(light: 0x587A22, dark: 0xB7DF66)
    )

    static let glacier = ThemePalette(
        canvas: adaptive(light: 0xEEF3F5, dark: 0x10171B),
        sidebar: adaptive(light: 0xE3EBEF, dark: 0x172127),
        surface: adaptive(light: 0xF7FAFB, dark: 0x1D292F),
        surfaceRaised: adaptive(light: 0xFFFFFF, dark: 0x26363E),
        border: adaptive(light: 0xCFDCE2, dark: 0x394D56),
        signal: adaptive(light: 0x256F8B, dark: 0x73CBE2)
    )

    private static func systemColor(_ light: NSColor, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else {
                return light
            }
            return color(dark)
        })
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return color(hex)
        })
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension View {
    func themedFormBackground(_ color: Color) -> some View {
        scrollContentBackground(.hidden)
            .background(color)
    }
}

extension Color {
    /// Creates a color from a `#RRGGBB` or `#RRGGBBAA` hex string. Falls back to accentColor.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let r, g, b, a: Double
        switch cleaned.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        default:
            self = .accentColor
            return
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
