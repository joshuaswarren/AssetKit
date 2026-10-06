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
        /// Some rendition of the asset is keyed display-gamut P3 (a wide
        /// ARGB-16 rendition, or a tinted icon's GA16): Apple then writes 3
        /// in the displayGamut slot.
        var hasWideGamut: Bool = false
        /// The catalog's KEYFORMAT. Its length drives hdrSize/keyLen/size;
        /// its order places the variable slots (see `encode`).
        var keyFormat: [AttributeID] = v1KeyFormat
        var keyTokenCount: Int { keyFormat.count }

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
            /// classifies as raster-derived.
            case vectorDiscarded
            /// `.colorset` assets. actool 27.0 writes one BITMAPKEYS row per
            /// colorset too.
            case color
            /// Single-size (1024 universal) `.appiconset` — the Icon
            /// Composer / Xcode 14+ form.
            case appIconSingleSize
            /// `.symbolset` assets. Marker 0x0e; the variable slots differ
            /// from all-1s: 12-token oracle [1, 1, 0x10, 4, 7, 0x20],
            /// 14-token oracle [1, 1, 0x10, 4, 7, 1, 0x20, 1] — the 0x20
            /// sits at index keyTokenCount/2 - 1 in both.
            case symbol
            /// Any asset of an Icon Composer `.icon` compilation other than
            /// the icon itself (colors, gradients, groups, the layer image).
            /// The IceCubes oracle gives all of them all-1 slots.
            case iconComposerAsset
            /// The icon asset itself (the one carrying the stack): idiom
            /// slot 7 and dimension2 slot 3 (see `encode`).
            case iconComposerIcon
        }

        /// The scales the asset's renditions are keyed at, bit `1 << scale`
        /// (header slot 6). Apple's oracles: 1x imagesets, colors, icons
        /// 0x02 (IceCubes 39 of 39, NNW, Mastodon); a 2x-only imageset 0x04;
        /// 1x/2x/3x bitmap and vector sets 0x0e; a non-preserving PDF set,
        /// whose vector sits at scale 0, 0x0f.
        var scaleMask: UInt32 = 0x02

        /// Symbols keep the verified Apple symbol-oracle value 0x0e.
        private var assetKindMarker: UInt32 {
            kind == .symbol ? 0x0e : scaleMask
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
            // Slot k describes KEYFORMAT attribute k + 3 (the attributes from
            // idiom on). Apple's values, every oracle so far (9, 10, 13, 14
            // tokens; IceCubes app-all, NNW, democar2, the cs1/tint pair):
            // 1 everywhere, except the idiom slot of an icon (its rendition
            // group count), the dimension2 slot of an icon (3), and the
            // displayGamut slot of an asset with P3-keyed renditions (3).
            var template = [UInt32](repeating: 1, count: slots)
            func set(_ attribute: AttributeID, _ value: UInt32) {
                guard let index = keyFormat.firstIndex(of: attribute), index >= 3, index - 3 < slots else { return }
                template[index - 3] = value
            }
            switch kind {
            case .color, .iconComposerAsset, .image, .vector, .vectorDiscarded:
                break
            case .iconComposerIcon:
                // IceCubes: 7 for every Icon Composer stack, 2 to 4 groups.
                set(.idiom, 7)
                set(.dimension2, 3)
            case .appIconSingleSize:
                set(.idiom, renditionGroups)
                set(.dimension2, 3)
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
            }
            if hasWideGamut, kind != .symbol, kind != .appIcon {
                set(.displayGamut, 3)
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
        keyFormat: [AttributeID]
    ) -> Descriptor? {
        let hasDescribableRendition = renditions.contains { rendition in
            if rendition.iconComposerSource { return true }
            switch rendition.body {
            case .bitmap, .preservedSource, .color, .symbolVector, .symbolCached: return true
            case .symbolPacked, .multiSized, .namedGradient, .iconGroup, .iconImageStack: return false
            }
        }
        guard hasDescribableRendition else { return nil }
        let hasWideGamut = renditions.contains { $0.gamut == .displayP3 }
        let scaleMask = renditions.reduce(UInt32(0)) { mask, rendition in
            mask | (1 << UInt32(RenditionKey(rendition: rendition).scale))
        }

        // Icon Composer sources: the icon asset (the one carrying the
        // stack) gets the icon descriptor, every other asset of the
        // compilation the all-1s 0x02 descriptor.
        if renditions.contains(where: { $0.iconComposerSource }) {
            let isStack = renditions.contains {
                if case .iconImageStack = $0.body { return true }
                return false
            }
            return Descriptor(
                kind: isStack ? .iconComposerIcon : .iconComposerAsset,
                idiomSubtypeCount: 0, hasWideGamut: hasWideGamut, keyFormat: keyFormat,
                scaleMask: scaleMask)
        }

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
            // Icon rendition groups: n(n + 1) for the n idioms carrying a
            // MultiSized container, whatever the appearances (democar2,
            // iphone only: 2; cs1, tint, NNW and all 32 IceCubes sets,
            // iphone + ipad, base-only or with dark and tinted: 6).
            let idioms = Set(renditions.compactMap { rendition -> UInt16? in
                guard case .multiSized = rendition.body else { return nil }
                return rendition.idiom.rawValueByte
            }).count
            renditionGroups = UInt32(idioms * (idioms + 1))
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
            hasWideGamut: hasWideGamut,
            keyFormat: keyFormat,
            scaleMask: scaleMask)
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
                case .jpeg, .heif: break
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
