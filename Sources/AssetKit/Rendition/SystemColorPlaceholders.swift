import Foundation

/// One appearance variant of a system-color fallback: the COLR colorspace ID
/// (base space + 0x100 system flag) and the components actool writes for it.
struct SystemColorVariant: Sendable {
    /// Includes the 0x100 "system" flag: 0x101 srgb, 0x102 gray-gamma-22,
    /// 0x104 extended-srgb, 0x106 extended-gray.
    var colorSpaceID: UInt32
    var components: [Double]
}

/// Per-system-color, per-appearance fallback bodies. actool 27.0 resolves a
/// `"reference": "<name>"` entry to a concrete placeholder in the color's own
/// space instead of reusing a sibling's colorspace; the value is a property
/// of the system color name alone (verified: siblings change nothing).
///
/// Values decoded from Xcode 27.0 actool output (38-color oracle, light+dark
/// each). Components are plain decimals; CSIWriter quantizes them to Float32,
/// which reproduces actool's bytes exactly.
enum SystemColorPlaceholders {
    struct Placeholder: Sendable {
        var light: SystemColorVariant
        var dark: SystemColorVariant
    }

    static let table: [String: Placeholder] = [
        "systemBackgroundColor": .init(
            light: .init(colorSpaceID: 0x106, components: [1, 1]),
            dark: .init(colorSpaceID: 0x106, components: [0, 1])),
        "secondarySystemBackgroundColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.949, 0.949, 0.969, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.11, 0.11, 0.118, 1])),
        "tertiarySystemBackgroundColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.949, 0.949, 0.969, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.173, 0.173, 0.18, 1])),
        "systemGroupedBackgroundColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.949, 0.949, 0.969, 1]),
            dark: .init(colorSpaceID: 0x106, components: [0, 1])),
        "secondarySystemGroupedBackgroundColor": .init(
            light: .init(colorSpaceID: 0x106, components: [1, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.11, 0.11, 0.118, 1])),
        "tertiarySystemGroupedBackgroundColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.949, 0.949, 0.969, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.173, 0.173, 0.18, 1])),
        "labelColor": .init(
            light: .init(colorSpaceID: 0x102, components: [0, 1]),
            dark: .init(colorSpaceID: 0x102, components: [1, 1])),
        "secondaryLabelColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.235, 0.235, 0.263, 0.6]),
            dark: .init(colorSpaceID: 0x101, components: [0.922, 0.922, 0.961, 0.6])),
        "tertiaryLabelColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.235, 0.235, 0.263, 0.298]),
            dark: .init(colorSpaceID: 0x101, components: [0.922, 0.922, 0.961, 0.298])),
        "quaternaryLabelColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.235, 0.235, 0.263, 0.176]),
            dark: .init(colorSpaceID: 0x101, components: [0.922, 0.922, 0.961, 0.157])),
        "placeholderTextColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.235, 0.235, 0.263, 0.298]),
            dark: .init(colorSpaceID: 0x101, components: [0.922, 0.922, 0.961, 0.298])),
        "separatorColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.235, 0.235, 0.263, 0.12]),
            dark: .init(colorSpaceID: 0x104, components: [0.329, 0.329, 0.345, 0.5])),
        "opaqueSeparatorColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.776, 0.776, 0.784, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.22, 0.22, 0.227, 1])),
        "systemBlueColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0, 0.533, 1, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0, 0.569, 1, 1])),
        "systemGreenColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.204, 0.78, 0.349, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0.188, 0.82, 0.345, 1])),
        "systemRedColor": .init(
            light: .init(colorSpaceID: 0x101, components: [1, 0.22, 0.235, 1]),
            dark: .init(colorSpaceID: 0x101, components: [1, 0.259, 0.271, 1])),
        "systemOrangeColor": .init(
            light: .init(colorSpaceID: 0x101, components: [1, 0.553, 0.157, 1]),
            dark: .init(colorSpaceID: 0x101, components: [1, 0.573, 0.188, 1])),
        "systemYellowColor": .init(
            light: .init(colorSpaceID: 0x101, components: [1, 0.8, 0, 1]),
            dark: .init(colorSpaceID: 0x101, components: [1, 0.839, 0, 1])),
        "systemPinkColor": .init(
            light: .init(colorSpaceID: 0x101, components: [1, 0.176, 0.333, 1]),
            dark: .init(colorSpaceID: 0x101, components: [1, 0.216, 0.373, 1])),
        "systemPurpleColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.796, 0.188, 0.878, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0.859, 0.204, 0.949, 1])),
        "systemTealColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0, 0.765, 0.816, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0, 0.824, 0.878, 1])),
        "systemIndigoColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.38, 0.333, 0.961, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0.42, 0.365, 1, 1])),
        "systemMintColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0, 0.783, 0.702, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0, 0.855, 0.765, 1])),
        "systemCyanColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0, 0.753, 0.91, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0.235, 0.827, 0.996, 1])),
        "systemBrownColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.675, 0.498, 0.369, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0.718, 0.541, 0.4, 1])),
        "systemGrayColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0.557, 0.557, 0.576, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0.557, 0.557, 0.576, 1])),
        "systemGray2Color": .init(
            light: .init(colorSpaceID: 0x104, components: [0.682, 0.682, 0.698, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.388, 0.388, 0.4, 1])),
        "systemGray3Color": .init(
            light: .init(colorSpaceID: 0x104, components: [0.78, 0.78, 0.8, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.282, 0.282, 0.29, 1])),
        "systemGray4Color": .init(
            light: .init(colorSpaceID: 0x104, components: [0.82, 0.82, 0.839, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.227, 0.227, 0.235, 1])),
        "systemGray5Color": .init(
            light: .init(colorSpaceID: 0x104, components: [0.898, 0.898, 0.918, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.173, 0.173, 0.18, 1])),
        "systemGray6Color": .init(
            light: .init(colorSpaceID: 0x104, components: [0.949, 0.949, 0.969, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.11, 0.11, 0.118, 1])),
        "linkColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0, 0.478, 1, 1]),
            dark: .init(colorSpaceID: 0x104, components: [0.035, 0.518, 1, 1])),
        "tintColor": .init(
            light: .init(colorSpaceID: 0x101, components: [0, 0.533, 1, 1]),
            dark: .init(colorSpaceID: 0x101, components: [0, 0.569, 1, 1])),
        "systemFillColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.502, 0.502, 0.502, 0.2]),
            dark: .init(colorSpaceID: 0x104, components: [0.502, 0.502, 0.502, 0.36])),
        "secondarySystemFillColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.502, 0.502, 0.502, 0.16]),
            dark: .init(colorSpaceID: 0x104, components: [0.502, 0.502, 0.502, 0.32])),
        "tertiarySystemFillColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.502, 0.502, 0.502, 0.12]),
            dark: .init(colorSpaceID: 0x104, components: [0.502, 0.502, 0.502, 0.24])),
        "quaternarySystemFillColor": .init(
            light: .init(colorSpaceID: 0x104, components: [0.455, 0.455, 0.502, 0.08]),
            dark: .init(colorSpaceID: 0x104, components: [0.463, 0.463, 0.502, 0.18])),
    ]

    /// Fallback for system colors missing from the table: actool has the full
    /// catalog; we keep the historical black/white gray guess.
    static let fallback = Placeholder(
        light: .init(colorSpaceID: 0x102, components: [0, 1]),
        dark: .init(colorSpaceID: 0x102, components: [1, 1]))

    static func placeholder(named name: String, dark: Bool) -> SystemColorVariant {
        let placeholder = table[name] ?? fallback
        return dark ? placeholder.dark : placeholder.light
    }
}
