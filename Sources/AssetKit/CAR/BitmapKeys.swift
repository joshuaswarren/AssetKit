import Foundation

/// BITMAPKEYS tree: per-asset bitmap descriptors that CoreUI consults during
/// UIImage(named:) resolution for `.imageset` (and analogous) assets.
///
/// Structure (verified against actool's reference Assets.car, Xcode 26 /
/// CoreUI 970, and Xcode 27.0 oracles):
/// - The tree is `isPathInternal = true` and uses a `blockSize` of 1024.
/// - Each leaf entry's "key" slot is an INLINE u32 NameIdentifier (not a
///   block pointer like other trees).
/// - Each value is a descriptor block of `keyTokenCount + 4` u32s.
///
/// Without this tree present, `UIImage(named:)` returns nil on device even
/// though `assetutil --info` parses the file cleanly and FACETKEYS/RENDITIONS
/// resolve correctly.
///
/// Every variable field is a value mask over the asset's own renditions: bit
/// `n` is set when some rendition of the asset carries token `n` for that
/// KEYFORMAT attribute (a 1x/2x/3x set has scale mask 0x0e, an icon keyed on
/// iphone and ipad has idiom mask 0x06). Apple's `assetutil --validate-file`
/// recomputes the descriptor from the renditions and reports
/// `invalid bitmapindex` when a stored field differs; `assetutil -U` rewrites
/// the field to this value. Checked on 55 distinct IceCubes cars: the 8 that
/// pass `--validate-file` match this rule field for field, and the 46 that
/// fail each differ in at least one field.
enum BitmapKeys {
    struct Descriptor {
        /// The catalog's KEYFORMAT. Its length drives hdrSize/keyLen/size.
        var keyFormat: [AttributeID]
        /// Per KEYFORMAT position: the OR of `1 << token` over the asset's
        /// renditions. Tokens of 32 or more have no bit and are skipped.
        var masks: [UInt32]

        var keyTokenCount: Int { keyFormat.count }

        /// Header slot 6: the scale mask. Symbols (scales 1 to 3) read 0x0e,
        /// a PDF kept as a scale-0 rendition adds bit 0 (0x0f).
        private var scaleMask: UInt32 {
            keyFormat.firstIndex(of: .scale).map { masks[$0] } ?? 0
        }

        func encode() -> Data {
            var w = ByteWriter()
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32((keyTokenCount + 1) * 4))  // hdrSize
            w.writeLE(UInt32(keyTokenCount))            // keyLen
            w.writeLE(UInt32(0xFFFFFFFF))
            w.writeLE(UInt32(1))
            w.writeLE(scaleMask)
            // Apple's descriptors carry (tokens - 6) slots between the
            // scale mask and the three -1 sentinels: the masks of KEYFORMAT
            // positions 3 up to the identifier, which Apple leaves out.
            let slots = max(0, keyTokenCount - 6)
            for i in 0..<slots {
                let attribute = keyFormat[i + 3]
                // macOS symbols key dimension1 at token 0 but Apple's NNW Mac
                // oracle writes the scale mask there.
                w.writeLE(attribute == .dimension1 ? scaleMask : masks[i + 3])
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

    /// Derive the BITMAPKEYS descriptor for one asset from its rendition list.
    /// Returns `nil` only for assets with no bitmap, preserved-source, or
    /// color renditions (actool 27.0 writes a BITMAPKEYS row for colorsets
    /// too).
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

        var masks = [UInt32](repeating: 0, count: keyFormat.count)
        for rendition in renditions {
            let key = RenditionKey(rendition: rendition).encode(format: keyFormat)
            for index in masks.indices {
                let token = UInt32(key[key.startIndex + index * 2]) | UInt32(key[key.startIndex + index * 2 + 1]) << 8
                if token < 32 { masks[index] |= 1 << token }
            }
        }
        return Descriptor(keyFormat: keyFormat, masks: masks)
    }
}
