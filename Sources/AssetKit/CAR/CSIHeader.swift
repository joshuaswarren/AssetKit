import Foundation

/// The fixed 184-byte CSI ("CTSI") rendition header. Layout verified against
/// the reference Assets.car produced by actool (Xcode 26 / CoreUI 970): on
/// disk the tag reads "ISTC" (CTSI as an LE multi-char constant).
enum CSIHeader {
    /// Byte length of the encoded header. Preserved-source and bitmap
    /// renditions both share this length; the body starts at this offset.
    static let length = 184

    /// 'CTSI' as an LE multi-char constant. Produces file bytes I,S,T,C.
    static let tag: UInt32 = 0x43545349

    /// `pixelFormat` = 'ARGB' as an LE multi-char constant. Produces file
    /// bytes B,G,R,A. The pixel encoding is in BGRA byte order in memory.
    static let pixelFormatARGB: UInt32 = 0x41524742

    /// `pixelFormat` = 'JPEG' as an LE multi-char constant. Produces file
    /// bytes G,E,P,J. Reused for preserved-source JPG renditions; CoreUI
    /// dispatches on this constant to invoke its JPEG decoder on the
    /// DWAR-wrapped body.
    static let pixelFormatJPEG: UInt32 = 0x4A504547

    /// `pixelFormat` = 'SVG ' (trailing space) as an LE multi-char constant.
    /// Produces file bytes space,G,V,S. Used for preserved-source SVG
    /// renditions; CoreUI dispatches on this constant to invoke its SVG
    /// renderer on the DWAR-wrapped body.
    static let pixelFormatSVG: UInt32 = 0x53564720

    /// `pixelFormat` = 'PDF ' (trailing space) as an LE multi-char constant.
    /// Produces file bytes space,F,D,P. Used for preserved-source PDF
    /// renditions; CoreUI dispatches on this constant to invoke its PDF
    /// renderer on the DWAR-wrapped body (NNW oracle).
    static let pixelFormatPDF: UInt32 = 0x50444620

    /// `pixelFormat` = 'GA8 ' (trailing space) as an LE multi-char constant
    /// (file bytes space,8,A,G; Apple symbol oracle).
    static let pixelFormatGray8: UInt32 = 0x47413820
    /// `pixelFormat` = 'DATA' as an LE multi-char constant (bytes A,T,A,D on
    /// disk). Carried by the Icon Composer structured renditions (group
    /// 1020, stack 1019); IceCubes oracle CSI headers.
    static let pixelFormatData: UInt32 = 0x44415441

    /// Layout types observed in the reference. The names are derived from
    /// CoreUI symbol names where known.
    enum Layout: UInt16 {
        /// Per the reference: every raw bitmap icon emitted by actool uses 12.
        /// Preserved-source JPG renditions reuse this same layout value (the
        /// pixelFormat selects the decoder, not the layout).
        case bitmapIcon = 12
        case namedColor = 1009
        /// MultiSized icon container. The body is a 'MSIS' record (version,
        /// count, then per-size width/height/index); actool emits one such
        /// rendition per (idiom, subtype) group of app-icon renditions.
        case multiSized = 1010
        /// Used by preserved-source SVG renditions in CoreUI 970. JPG keeps
        /// `bitmapIcon` because JPEG sits inside CoreUI's bitmap-asset
        /// category; SVG promotes to its own layout because vector
        /// renditions surface a different AssetType to `assetutil`.
        case vector = 9
        /// Symbol-set cached bitmap (GA8, no inline pixels; pixels resolve
        /// through the TVL-1010 atlas link). Apple symbol oracle.
        case symbolCache = 1003
        /// Symbol-set vector glyph ('SVG ' pixelFormat, DWAR-wrapped
        /// rewritten SVG body). Apple symbol oracle.
        case symbolGlyph = 1017
        /// Symbol-set packed cache atlas (GA8 dmp2 pixels). Apple symbol
        /// oracle.
        case symbolPacked = 1004
        /// Icon Composer layered icon stack ("IconImageStack" in assetutil).
        /// Body is a 12-byte DWAR envelope; the structure lives in the TVL.
        case iconImageStack = 1019
        /// Icon Composer group ("IconGroup"). Same body shape as the stack.
        case iconGroup = 1020
        /// Icon Composer named gradient ("Named Gradient"). Body is a raw
        /// 'ARGG' record, no DWAR envelope.
        case namedGradient = 1021
    }

    // swiftlint:disable:next function_parameter_count
    static func encode(
        renditionFlags: UInt32,
        width: UInt32,
        height: UInt32,
        scaleFactor: UInt32,
        pixelFormat: UInt32,
        colorSpace: UInt32,
        layout: Layout,
        name: String,
        tvlLength: UInt32,
        bitmapCount: UInt32,
        renditionLength: UInt32
    ) -> Data {
        var w = ByteWriter()
        w.writeLE(tag)
        w.writeLE(UInt32(1))                    // version
        w.writeLE(renditionFlags)
        w.writeLE(width)
        w.writeLE(height)
        w.writeLE(scaleFactor)
        w.writeLE(pixelFormat)
        w.writeLE(colorSpace)
        w.writeLE(UInt32(0))                    // modtime (matches reference; was wall-clock)
        w.writeLE(layout.rawValue)
        w.writeLE(UInt16(0))                    // zero
        w.writePadded(name, length: 128)
        w.writeLE(tvlLength)
        w.writeLE(bitmapCount)
        w.writeLE(UInt32(0))                    // reserved
        w.writeLE(renditionLength)
        precondition(w.offset == length, "CSI header must be \(length) bytes; got \(w.offset)")
        return w.data
    }
}
