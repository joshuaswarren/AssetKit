import Foundation

/// APPEARANCEKEYS tree rows: maps appearance name strings to the UInt16 ids
/// that rendition keys carry in their `appearance` attribute.
///
/// CoreUI's runtime walks this tree by exact name-string match to resolve
/// the appearance slot in a rendition key. Every numeric ID that can appear
/// in a rendition key must have a row here, or the rendition lookup
/// silently fails (UIImage(named:) returns nil with no error).
///
/// **Platform difference:** iOS uses `UIAppearanceAny` / `UIAppearanceDark`.
/// macOS uses `NSAppearanceNameAqua` / `NSAppearanceNameDarkAqua`. This
/// library targets iOS app catalogs only, so we register the UIAppearance*
/// names. The reference `actool` output only emits the rows for appearances
/// actually used in the catalog (catalogs with no dark variants omit the
/// `UIAppearanceDark` row entirely); we mirror that behaviour by passing
/// the catalog's used-appearances set to `entries(used:)`.
enum AppearanceKeys {
    static let any: UInt16 = 0
    static let dark: UInt16 = 1
    /// Explicit light-appearance id. Icon Composer layered renditions key
    /// their light variants at 4 ("UIAppearanceLight", IceCubes oracle
    /// APPEARANCEKEYS/rendition keys) while light app-icon bitmaps stay 0.
    static let light: UInt16 = 4
    /// Tinted home-screen icon variants. Name and id verified against the
    /// NNW single-size oracle car's APPEARANCEKEYS tree
    /// ("ISAppearanceTintable" -> 0x000A).
    static let tintable: UInt16 = 10

    static func entries(used: Set<UInt16>) -> [BOMTree.Entry] {
        var rows: [BOMTree.Entry] = []
        // `UIAppearanceAny` (id=0) is always present in the reference, even
        // when every rendition has an explicit appearance, because CoreUI
        // packs `appearance=0` as the default-variant marker in rendition
        // keys regardless of whether a dark variant exists.
        rows.append(BOMTree.Entry(
            key: Data("UIAppearanceAny".utf8),
            value: Self.encodeID(any)
        ))
        if used.contains(dark) {
            rows.append(BOMTree.Entry(
                key: Data("UIAppearanceDark".utf8),
                value: Self.encodeID(dark)
            ))
        }
        if used.contains(light) {
            rows.append(BOMTree.Entry(
                key: Data("UIAppearanceLight".utf8),
                value: Self.encodeID(light)
            ))
        }
        if used.contains(tintable) {
            rows.append(BOMTree.Entry(
                key: Data("ISAppearanceTintable".utf8),
                value: Self.encodeID(tintable)
            ))
        }
        return rows
    }

    private static func encodeID(_ id: UInt16) -> Data {
        var w = ByteWriter()
        w.writeLE(id)
        return w.data
    }
}
