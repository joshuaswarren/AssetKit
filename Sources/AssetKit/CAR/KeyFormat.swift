import Foundation

/// kThemeRenditionAttribute IDs for CoreUI 970 (StorageVersion 17, Xcode 26).
///
/// Values determined by dumping the KEYFORMAT block of an actool-produced
/// Assets.car (`xcrun assetutil --info`). Older CoreUI versions used a
/// different numbering; do not rely on writeups that predate Xcode 14.
enum AttributeID: UInt32 {
    case element = 1
    case part = 2
    case appearance = 7
    case dimension2 = 9
    case dimension1 = 8
    case scale = 12
    case localization = 13
    case idiom = 15
    case subtype = 16
    case identifier = 17
    case deploymentTarget = 25
    case displayGamut = 24
    case glyphWeight = 26
    case glyphSize = 27
}

/// Attribute order CoreUI emits in `KEYFORMAT` (and which the rendition key
/// tuple positions mirror exactly). Order is significant: CoreUI binary-searches
/// rendition keys by raw byte comparison after packing them into this slot
/// layout.
///
/// KEYFORMAT is per-catalog: actool emits the base eight attributes and adds
/// `dimension2` only when some rendition uses it (app icons carry an Icon
/// Index there). Verified against actool 27.0: an icon-only catalog gets 9
/// attributes, a color-only catalog gets 8, and rendition keys pack exactly
/// that many tokens in this order.
let baseKeyFormat: [AttributeID] = [
    .appearance,
    .localization,
    .scale,
    .idiom,
    .subtype,
    .identifier,
    .element,
    .part,
]

/// Key format for catalogs that use the Icon Index slot (app icons).
let v1KeyFormat: [AttributeID] = [
    .appearance,
    .localization,
    .scale,
    .idiom,
    .subtype,
    .dimension2,
    .identifier,
    .element,
    .part,
]

/// Attribute order actool widens the key tuple in: the classic order with
/// each optional attribute inserted at its fixed rank. Dumped from the NNW
/// single-size-with-appearances oracle car, whose 14-attribute KEYFORMAT is
/// [7, 13, 12, 15, 16, 26, 27, 9, 8, 25, 24, 17, 1, 2].
let canonicalKeyOrder: [AttributeID] = [
    .appearance,
    .localization,
    .scale,
    .idiom,
    .subtype,
    .glyphWeight,
    .glyphSize,
    .dimension2,
    .dimension1,
    .deploymentTarget,
    .displayGamut,
    .identifier,
    .element,
    .part,
]

enum KeyFormat {
    /// The catalog's KEYFORMAT: the attributes this catalog's renditions
    /// actually use, in `canonicalKeyOrder`. actool includes `dimension2`
    /// when app icons are present, `displayGamut` when a rendition carries a
    /// non-default gamut (tinted icons re-key their 16-bit gray variant as
    /// P3), and `appearance` when any rendition has a named appearance.
    /// Verified: the NNW oracle car keys its dark/tinted renditions through
    /// exactly these slots.
    static func format(for renditions: [Rendition]) -> [AttributeID] {
        let usesIconIndex = renditions.contains { rendition in
            if case .bitmap(let body) = rendition.body, body.kind == .appIcon {
                return true
            }
            return false
        }
        let usesAppearance = renditions.contains { $0.appearance?.keyToken != nil }
        let usesGamut = renditions.contains { rendition in
            guard let gamut = rendition.gamut else { return false }
            return gamut != .sRGB
        }
        var used: Set<AttributeID> = [
            .appearance, .localization, .scale, .idiom, .subtype,
            .identifier, .element, .part,
        ]
        if usesIconIndex { used.insert(.dimension2) }
        if usesAppearance { used.insert(.appearance) }
        if usesGamut { used.insert(.displayGamut) }
        return canonicalKeyOrder.filter { used.contains($0) }
    }
}

/// `kfmt` block payload.
enum KeyFormatBlock {
    static let magic: UInt32 = 0x6B666D74 // 'kfmt' as LE multi-char constant

    static func data(attributes: [AttributeID] = v1KeyFormat) -> Data {
        var w = ByteWriter()
        w.writeLE(magic)
        w.writeLE(UInt32(0))                            // version
        w.writeLE(UInt32(attributes.count))             // maximumRenditionKeyTokenCount
        for attr in attributes {
            w.writeLE(attr.rawValue)
        }
        return w.data
    }
}
