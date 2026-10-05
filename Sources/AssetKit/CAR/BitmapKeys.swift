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

        enum Kind {
            case appIcon
            /// PNG and JPEG `.imageset` assets — bitmap source.
            case image
            /// SVG `.imageset` assets — vector source.
            case vector
            /// `.colorset` assets. actool 27.0 writes one BITMAPKEYS row per
            /// colorset too (marker 0x02, variable section shaped like the
            /// image one).
            case color
            /// Single-size (1024 universal) `.appiconset` — the Icon
            /// Composer / Xcode 14+ form. actool 27.0 emits a 48-byte
            /// descriptor with marker 0x02 and a shorter variable section
            /// (verified against the democar2 oracle).
            case appIconSingleSize
        }

        /// Slot 6 of the header (the only header u32 that varies by kind).
        /// `0x04` for bitmap-source assets (PNG, JPG); `0x0e` for classic
        /// appicons and vector sources; `0x02` for single-size appicons and
        /// colors (actool 27.0 oracles).
        private var assetKindMarker: UInt32 {
            switch kind {
            case .image: return 0x04
            case .vector, .appIcon: return 0x0e
            case .appIconSingleSize, .color: return 0x02
            }
        }

        func encode() -> Data {
            // Single-size appicons: exact 52-byte descriptor from the
            // actool 27.0 democar2 oracle.
            if kind == .appIconSingleSize {
                var w = ByteWriter()
                for v: UInt32 in [1, 0, 0x28, 9, 0xFFFFFFFF, 1, 0x02, 2, 1, 3,
                                  0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF] {
                    w.writeLE(v)
                }
                precondition(w.offset == 52)
                return w.data
            }
            // All other kinds: generic 52-byte (icon/image/vector) or
            // 48-byte (color) descriptor.
            var w = ByteWriter()
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            let hdrSize: UInt32 = kind == .color ? 0x24 : 0x28
            let keyLen: UInt32 = kind == .color ? 8 : 9
            w.writeLE(hdrSize)
            w.writeLE(keyLen)
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(1))
            w.writeLE(assetKindMarker)
            w.writeLE(idiomSubtypeCount)
            switch kind {
            case .appIcon:
                w.writeLE(UInt16(1))
                w.writeLE(UInt16(1))
                w.writeLE(UInt32(7))
            case .image, .vector:
                w.writeLE(UInt16(1))
                w.writeLE(UInt16(0))
                w.writeLE(UInt32(1))
            case .color:
                w.writeLE(UInt16(1))
                w.writeLE(UInt16(0))
            case .appIconSingleSize:
                break
            }
            let sentinels = kind == .color ? 3 : 3
            for _ in 0..<sentinels {
                w.writeLE(UInt32(0xFFFFFFFF))
            }
            let expectedSize = kind == .color ? 48 : 52
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
    static func descriptor(forAsset name: String, renditions: [Rendition]) -> Descriptor? {
        let hasDescribableRendition = renditions.contains { rendition in
            switch rendition.body {
            case .bitmap, .preservedSource, .color: return true
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
        if kind == .appIcon,
           renditions.contains(where: { if case .multiSized = $0.body { return true }; return false }),
           bitmapIndices.count <= 1 {
            effectiveKind = .appIconSingleSize
            countOverride = UInt32(renditions.count)
        }

        let idiomSubtypes = Set(renditions.map { rendition -> UInt32 in
            let idiom = UInt32(rendition.idiom.rawValueByte)
            let subtype = UInt32(rendition.subtype ?? 0)
            return (idiom << 16) | subtype
        })

        return Descriptor(
            kind: effectiveKind,
            idiomSubtypeCount: UInt32(idiomSubtypes.count),
            countOverride: countOverride)
    }

    /// AppIcon takes precedence over Vector takes precedence over Image:
    /// an .appiconset is a distinct CoreUI category, and a vector source
    /// outranks plain bitmap because the rasterised PNG fallbacks coexist
    /// with the preserved SVG body. Mixed PNG/JPEG imagesets fall through
    /// to `.image`. Color-only assets (`.colorset`) classify as `.color`.
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
            if case .preservedSource(let body) = rendition.body, case .svg = body.format {
                return .vector
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
