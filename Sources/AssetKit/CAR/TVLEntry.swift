import Foundation

/// One entry in a CSI rendition's TVL (type-length-value) metadata section.
///
/// CoreUI consumes a small fixed set of TVL types between the 184-byte CSI
/// header and the rendition body. Closed enum + exhaustive switch keeps the
/// type IDs and value layouts in one place; the alignment rule for
/// `.bytesPerRow` lives inside the enum (callers pass width, encoding
/// computes the 16-byte-aligned stride).
///
/// Type IDs and value layouts derived from actool's reference Assets.car
/// (Xcode 26 / CoreUI 970). Without these entries, CoreUI can parse the
/// rendition's key but cannot materialise the body -- `assetutil --info`
/// reports AssetType "Unknown" and omits PixelWidth/PixelHeight/Encoding.
enum TVLEntry {
    /// Type 1001 (20-byte value): bitmap descriptor. Encoded fields are
    /// `(1, 0, 0, width, height)`. The leading 1 is presumed a
    /// bitmap-type/flags field; the trailing dims duplicate the CSI header
    /// dims and seem to be what CoreUI consults during materialisation.
    case bitmapDescriptor(width: UInt32, height: UInt32)

    /// Type 1003 (28-byte value): destination rect. Encoded fields are
    /// `(1, 0, 0, 0, 0, width, height)` -- `(flags, x, y, z, w, w, h)`.
    case destRect(width: UInt32, height: UInt32)

    /// Type 1004 (8-byte value): slice/scale pair. Reference is `(0, 1.0f)`.
    case sliceScale

    /// Type 1004 (8-byte value) as named colors carry it: all zero. Seen in
    /// actool 27.0 output for every `.colorset` rendition.
    case colorSlice

    /// Type 1006 (4-byte value): always 1 in the reference. Likely a
    /// bitmap-count / has-mipmap-stages flag.
    case bitmapFlag

    /// Type 1007 (4-byte value): bytes per row, aligned up to 16. Caller
    /// passes the pixel width and per-pixel byte count (4 for ARGB/GA16,
    /// 2 for GA8).
    case bytesPerRow(width: UInt32, bytesPerPixel: UInt32)

    /// Type 1010 (50-byte value): symbol-cache link to the packed atlas.
    /// `x`/`y`/`width`/`height` place this cache entry's bitmap inside the
    /// atlas; the trailing key pairs (ascending attribute id, nonzero
    /// tokens of the packed rendition's key) let CoreUI resolve the atlas
    /// by key. Apple symbol oracle: (1, 9), (2, 181), (12, scale), (25, 5)
    /// with a (0, 0) terminator.
    case symbolLink(
        x: UInt32, y: UInt32, width: UInt32, height: UInt32, keyPairs: [(UInt16, UInt16)])

    /// Type 1018: symbol font metrics. `pointSize` is the reference size
    /// (17); the floats are baseline, capline, 0, left margin, right
    /// margin, left margin, right margin at that size. `sizes` carries the
    /// (cachedIndex, pointSize) pairs — present only on the Medium vector.
    case glyphMetrics(
        pointSize: UInt32,
        baseline: Float,
        capline: Float,
        left: Float,
        right: Float,
        sizes: [(index: UInt32, pointSize: UInt32)]?)

    /// Type 1019 (12-byte value): symbol glyph flags, always (1, 0, 0).
    case glyphSizes
    /// Escape hatch for the Icon Composer layered renditions (stacks,
    /// groups, gradients), whose TVL vocabularies are their own: the bytes
    /// are emitted verbatim, layout documented at the encoding site.
    case rawBytes(tag: UInt32, payload: [UInt8])

    func encode(into w: inout ByteWriter) {
        switch self {
        case .bitmapDescriptor(let width, let height):
            w.writeLE(UInt32(1001))
            w.writeLE(UInt32(20))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(width)
            w.writeLE(height)
        case .destRect(let width, let height):
            w.writeLE(UInt32(1003))
            w.writeLE(UInt32(28))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
            w.writeLE(width)
            w.writeLE(height)
        case .sliceScale:
            w.writeLE(UInt32(1004))
            w.writeLE(UInt32(8))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(Float(1).bitPattern))
        case .colorSlice:
            w.writeLE(UInt32(1004))
            w.writeLE(UInt32(8))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
        case .bitmapFlag:
            w.writeLE(UInt32(1006))
            w.writeLE(UInt32(4))
            w.writeLE(UInt32(1))
        case .bytesPerRow(let width, let bytesPerPixel):
            w.writeLE(UInt32(1007))
            w.writeLE(UInt32(4))
            // actool stores the exact stride (NNW oracle: 4096 for ARGB and
            // GA16, 2048 for GA8 at 1024 px); ours keeps the historical
            // 16-byte alignment, identical for these strides.
            let bytesPerRow = width * bytesPerPixel
            let aligned = (bytesPerRow + 15) & ~15
            w.writeLE(aligned)
        case .symbolLink(let x, let y, let width, let height, let keyPairs):
            w.writeLE(UInt32(1010))
            w.writeLE(UInt32(4 + 4 + 16 + 2 + 4 + keyPairs.count * 4 + 4))
            // 'INLK' as an LE multi-char constant (file bytes K,L,N,I), the
            // same convention as CTSI. Version, atlas placement, then the
            // inline key: u16 flags, u32 key-data length (pairs + (0,0)
            // terminator), ascending (attribute, value) pairs.
            w.writeLE(UInt32(0x494E4C4B))
            w.writeLE(UInt32(0))
            w.writeLE(x)
            w.writeLE(y)
            w.writeLE(width)
            w.writeLE(height)
            w.writeLE(UInt16(0))
            w.writeLE(UInt32(keyPairs.count * 4 + 4))
            for (attribute, value) in keyPairs {
                w.writeLE(attribute)
                w.writeLE(value)
            }
            w.writeLE(UInt16(0))
            w.writeLE(UInt16(0))
        case .glyphMetrics(let pointSize, let baseline, let capline, let left, let right, let sizes):
            w.writeLE(UInt32(1018))
            var value = ByteWriter()
            value.writeLE(UInt32(3))
            value.writeLE(pointSize)
            value.writeLE(baseline.bitPattern)
            value.writeLE(capline.bitPattern)
            value.writeLE(Float(0).bitPattern)
            value.writeLE(left.bitPattern)
            value.writeLE(right.bitPattern)
            value.writeLE(left.bitPattern)
            value.writeLE(right.bitPattern)
            let pairs = sizes ?? []
            value.writeLE(UInt32(pairs.count))
            for (index, size) in pairs {
                value.writeLE(index)
                value.writeLE(size)
            }
            w.writeLE(UInt32(value.offset))
            w.write(value.data)
        case .glyphSizes:
            w.writeLE(UInt32(1019))
            w.writeLE(UInt32(12))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(0))
            w.writeLE(UInt32(0))
        case .rawBytes(let tag, let payload):
            w.writeLE(tag)
            w.writeLE(UInt32(payload.count))
            w.write(payload)
        }
    }
}
