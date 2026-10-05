import Foundation

/// BITMAPKEYS tree: per-asset bitmap descriptors that CoreUI consults during
/// UIImage(named:) resolution for `.imageset` (and analogous) assets.
///
/// Structure (verified against actool's reference Assets.car, Xcode 26 /
/// CoreUI 970, and a Xcode 27.0 per-colorspace oracle):
/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
///   block pointer like other trees).
/// - Each value is a 52-byte descriptor block (48 bytes for colorsets,
///   which carry one fewer trailing sentinel).
///
/// Without this tree present, `UIImage(named:)` returns nil on device even
/// though `assetutil --info` parses the file cleanly and FACETKEYS/RENDITIONS
/// resolve correctly. SpringBoard's appicon-render path does NOT depend on
/// BITMAPKEYS (the home icon still renders via the loose-PNG fallback).
enum BitmapKeys {
    /// The descriptor. Layout was derived by diffing actool's outputs
    /// for `.appiconset` vs `.imageset` (bitmap) vs `.imageset` (vector)
    /// renditions. The first 7 u32s are header-like; only slot 6 varies
    /// across asset kinds. The remaining 6 vary by asset kind.
    struct Descriptor {
        var kind: Kind
        /// Number of distinct (idiom, subtype) tuples this asset is keyed on.
        var idiomSubtypeCount: UInt32
        /// Overrides the count slot for the single-size appicon shape.
        var countOverride: UInt32? = nil
        /// Icon rendition groups (see `encode`) for the single-size shape.
        var renditionGroups: UInt32 = 0
        /// The catalog's KEYFORMAT token count (drives hdrSize/keyLen/size).
        var keyTokenCount: Int = 9

        enum Kind {
            case appIcon
            /// PNG and JPEG `.imageset` assets — bitmap source.
            case image
            /// SVG `.imageset` assets and `preserves-vector-representation`
            /// PDF sets — vector source preserved in the car.
            case vector
            /// PDF `.imageset` assets without
            /// `preserves-vector-representation`: the vector bytes still
            /// ship (as the scale-0 generic-image rendition) but the asset
            /// classifies as raster-derived. Apple's BITMAPKEYS marker for
            /// these is 0x0f (NNW oracle: accountNewsBlur), distinct from
            /// the 0x0e vector and 0x04 bitmap markers.
            case vectorDiscarded
            /// `.colorset` assets. actool 27.0 writes one BITMAPKEYS row per
            /// colorset too (marker 0x02, variable section shaped like the
            /// image one).
            case color
            /// Single-size (1024 universal) `.appiconset` — the Icon
            /// Composer / Xcode 14+ form. actool 27.0 emits a 48-byte
            /// descriptor with marker 0x02 and a shorter variable section
            /// (verified against the democar2 oracle).
            case appIconSingleSize
            /// `.symbolset` assets. Apple's marker is 0x0e (vector source,
            /// like preserving PDF sets) but the variable slots differ
            /// from all-1s: 12-token oracle [1, 1, 0x10, 4, 7, 0x20],
            /// 14-token oracle [1, 1, 0x10, 4, 7, 1, 0x20, 1] — the 0x20
            /// sits at index keyTokenCount/2 - 1 in both.
            case symbol
        }

        /// Slot 6 of the header (the only header u32 that varies by kind).
        /// `0x04` for bitmap-source assets (PNG, JPG); `0x0e` for classic
        /// appicons and vector sources; `0x0f` for non-preserving PDF
        /// sets; `0x02` for single-size appicons and colors (actool 27.0
        /// oracles).
        private var assetKindMarker: UInt32 {
            switch kind {
            case .image: return 0x04
            case .vector, .appIcon, .symbol: return 0x0e
            case .vectorDiscarded: return 0x0f
            case .appIconSingleSize, .color: return 0x02
            }
        }

        func encode() -> Data {
            var w = ByteWriter()
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32((keyTokenCount + 1) * 4))  // hdrSize
            w.writeLE(UInt32(keyTokenCount))            // keyLen
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(1))
            w.writeLE(assetKindMarker)
            // Variable-slot count: Apple's descriptors always carry
            // (tokens - 6) u32 slots between the marker and the three -1
            // sentinels, for every token count observed (8/9/10/13/14).
            // Clamp at 0 so low-token catalogs never produce a negative
            // range.
            let slots = max(0, keyTokenCount - 6)
            // Per-kind value templates. The first `slots` entries are
            // written; any extra template entries are silently dropped
            // (matching actool's truncation at high token counts), and
            // missing entries are 1-filled (actool's colour/vector fills
            // are all-1s at every observed token count).
            var template: [UInt32]
            switch kind {
            case .color:
                // Oracle: all-1s at 8/9/13/14 tokens.
                template = [UInt32](repeating: 1, count: slots)
            case .appIconSingleSize:
                // [groups, 1, 3] then 3s to fill
                // (9t base+dark: [6,1,3]; 10t base+tinted: [6,1,3,3];
                //  9t base-only: [2,1,3]).
                template = [renditionGroups, 1, 3]
                template += [UInt32](repeating: 3, count: max(0, slots - 3))
            case .appIcon:
                // Classic multi-size oracle (9t): [70, (1,1), 63].
                template = [70, 0x0001_0001, 63]
                template += [UInt32](repeating: 1, count: max(0, slots - 3))
            case .symbol:
                // Apple symbol oracles: 12t [1, 1, 0x10, 4, 7, 0x20],
                // 14t [1, 1, 0x10, 4, 7, 1, 0x20, 1]. The 0x20 lands at
                // index keyTokenCount/2 - 1 in both; other slots after
                // the shared five-value prefix are 1.
                template = [1, 1, 0x10, 4, 7]
                template += [UInt32](repeating: 1, count: max(0, slots - 5))
                if slots > 0 {
                    template[max(0, keyTokenCount / 2 - 1)] = 0x20
                }
            case .image, .vector, .vectorDiscarded:
                // Oracle (13t no-app-icon): all-1s for 0x0e/0x0f;
                // (14t full NNW): [1, 1, 0x10, 4, 7, 1, 0x20, 1] for the
                // preserving 0x0e with non-default rendering — content-
                // dependent, we emit all-1s (safe default, matches most
                // assets).
                template = [UInt32](repeating: 1, count: slots)
            }
            for i in 0..<slots {
                w.writeLE(i < template.count ? template[i] : 1)
            }
            for _ in 0..<3 {
                w.writeLE(UInt32(0xFFFFFFFF))
            }
            let expectedSize = (keyTokenCount + 4) * 4
            precondition(
                w.offset == expectedSize,
                "BITMAPKEYS descriptor must be \(expectedSize) bytes; got \(w.offset)")
            return w.data
        }
    }

    /// Per-asset BITMAPKEYS entry: `(inline u32 key = NameIdentifier, value
    /// = descriptor bytes)`.
    static func entries(for assets: [(name: String, descriptor: Descriptor)]) -> [(key: UInt32, value: Data)] {
        return assets.map { asset in
            (key: FacetKeys.nameHash(asset.name) & 0xFFFF, value: asset.descriptor.encode())
        }
    }

    /// Derive the BITMAPKEYS descriptor for one asset from its rendition list.
    /// Returns `nil` only for assets with no bitmap, preserved-source, or
    /// color renditions (actool 27.0 writes a BITMAPKEYS row for colorsets
    /// too, marker 0x02).
    ///
    /// `renditions` is the per-asset slice -- only the renditions whose
    /// `name` equals this asset's name. Caller is responsible for the
    /// grouping; this function does not re-filter.
    static func descriptor(
        forAsset name: String,
        renditions: [Rendition],
        keyTokenCount: Int
    ) -> Descriptor? {
        let hasDescribableRendition = renditions.contains { rendition in
            switch rendition.body {
            case .bitmap, .preservedSource, .color, .symbolVector, .symbolCached: return true
            case .symbolPacked: return false
            case .multiSized: return false
            }
        }
        guard hasDescribableRendition else { return nil }

        let kind = inferKind(from: renditions)
        var countOverride: UInt32? = nil
        var effectiveKind = kind
        // Single-size form: every bitmap rendition occupies the same Icon
        // Index slot (one point size, optionally with dark / tinted
        // appearance variants and per-idiom keys), plus the MultiSized
        // containers. The classic multi-size form spans several indices.
        let bitmapIndices = Set(renditions.compactMap { rendition -> UInt16? in
            guard case .bitmap = rendition.body else { return nil }
            return rendition.iconIndex
        })
        var renditionGroups: UInt32 = 0
        if kind == .appIcon,
           renditions.contains(where: { if case .multiSized = $0.body { return true }; return false }),
           bitmapIndices.count <= 1 {
            effectiveKind = .appIconSingleSize
            countOverride = UInt32(renditions.count)
            // Icon rendition groups: distinct (idiom, appearance) bitmap
            // variants — the tinted GA8/GA16 encodings share one group —
            // plus one per MultiSized container (cs1: 4 + 2 = 6; tint:
            // base(2) + tinted(2) + MS(2) = 6).
            let bitmapGroups = Set(renditions.compactMap { rendition -> UInt32? in
                guard case .bitmap = rendition.body else { return nil }
                let appearanceKey = UInt32(rendition.appearance?.keyToken ?? 0) << 16
                return UInt32(rendition.idiom.rawValueByte) | appearanceKey
            }).count
            let multiSized = renditions.filter {
                if case .multiSized = $0.body { return true }
                return false
            }.count
            renditionGroups = UInt32(bitmapGroups + multiSized)
        }

        let idiomSubtypes = Set(renditions.map { rendition -> UInt32 in
            let idiom = UInt32(rendition.idiom.rawValueByte)
            let subtype = UInt32(rendition.subtype ?? 0)
            return (idiom << 16) | subtype
        })

        return Descriptor(
            kind: effectiveKind,
            idiomSubtypeCount: UInt32(idiomSubtypes.count),
            countOverride: countOverride,
            renditionGroups: renditionGroups,
            keyTokenCount: keyTokenCount)
    }

    /// AppIcon takes precedence over Vector takes precedence over Image:
    /// an .appiconset is a distinct CoreUI category, and a vector source
    /// outranks plain bitmap because the rasterised PNG fallbacks coexist
    /// with the preserved body. Mixed PNG/JPEG imagesets fall through
    /// to `.image`. Color-only assets (`.colorset`) classify as `.color`.
    /// A PDF set without `preserves-vector-representation` classifies as
    /// `.vectorDiscarded` (marker 0x0f); with it, `.vector` (0x0e).
    ///
    /// The AppIcon arm relies on `ImageRenderer.appIconRenditions` only
    /// producing `.bitmap(.appIcon)` renditions (PNG-only at that entry
    /// point). If that invariant slips, an appiconset whose source was
    /// (say) preserved JPG would be misclassified as `.image` here.
    private static func inferKind(from renditions: [Rendition]) -> Descriptor.Kind {
        for rendition in renditions {
            if case .bitmap(let body) = rendition.body, body.kind == .appIcon {
                return .appIcon
            }
        }
        for rendition in renditions {
            switch rendition.body {
            case .symbolVector, .symbolCached:
                return .symbol
            default: break
            }
        }
        for rendition in renditions {
            if case .preservedSource(let body) = rendition.body {
                switch body.format {
                case .svg: return .vector
                case .pdf(let preservesVector):
                    return preservesVector ? .vector : .vectorDiscarded
                case .jpeg: break
                }
            }
        }
        for rendition in renditions {
            if case .color = rendition.body {
                return .color
            }
        }
        return .image
    }
}
