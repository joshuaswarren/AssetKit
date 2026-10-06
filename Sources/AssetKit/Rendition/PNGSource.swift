import Foundation
import PNG

/// In-memory adapter for swift-png's `PNG.BytestreamSource`. Lets us decode
/// PNG bytes that come from a `Data` buffer (e.g. fresh output from an SVG
/// rasteriser) without round-tripping through a temp file.
private struct MemoryBytestream: PNG.BytestreamSource {
    var bytes: [UInt8]
    var offset: Int = 0
    mutating func read(count: Int) -> [UInt8]? {
        guard offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }
}

/// PNG source handler: produces one bitmap rendition with BGRA-premultiplied
/// pixels. Shared by both `.imageset` (kind=.image) and `.appiconset`
/// (kind=.appIcon) paths; the caller picks the kind via the Context.
public enum PNGSource {
    struct Context {
        var assetName: String
        var idiom: Idiom
        var scale: Scale?
        var appearance: Appearance?
        var gamut: Gamut
        var filename: String
        var kind: BitmapBody.Kind
    }

    static func renditions(bytes: Data, context: Context) throws -> [Rendition] {
        let decoded = try decodeBGRA(bytes)
        var body = BitmapBody(
            width: decoded.width,
            height: decoded.height,
            pixelsBGRA: decoded.bgra8,
            colorSpaceID: context.gamut.colorSpaceID,
            kind: context.kind,
            renditionName: context.filename
        )
        // Colorless 8-bit content (R = G = B in every pixel) is stored as
        // gray+alpha, 'GA8 ' in gray gamma 22 (IceCubes ActionIcon oracle:
        // an RGBA source of black + alpha compiles to Encoding Gray, cs 2).
        // Tinted entries are skipped: they become gray through
        // ImageRenderer.tintedRenditions, which reads BGRA.
        if decoded.extendedRGBA16 == nil, context.appearance?.tintedLuminosity != true,
           let gray = grayAlpha(premultipliedBGRA: decoded.bgra8) {
            body.pixelsBGRA = gray
            body.pixelFormat = .gray8
            body.colorSpaceID = 2
        }
        var out = [Rendition(
            name: context.assetName,
            idiom: context.idiom,
            scale: context.scale,
            appearance: context.appearance,
            gamut: context.gamut,
            body: .bitmap(body)
        )]
        // Display P3 sources get a second, wide-gamut rendition beside the
        // 8-bit one (tinted entries excepted: they go through the gray
        // conversion, which reads the 8-bit BGRA rendition).
        if let wide = decoded.extendedRGBA16, context.appearance?.tintedLuminosity != true {
            out.append(Rendition(
                name: context.assetName,
                idiom: context.idiom,
                scale: context.scale,
                appearance: context.appearance,
                gamut: .displayP3,
                body: .bitmap(BitmapBody(
                    width: decoded.width,
                    height: decoded.height,
                    pixelsBGRA: wide,
                    colorSpaceID: 4,
                    kind: context.kind,
                    pixelFormat: .argb16,
                    renditionName: context.filename
                ))
            ))
        }
        return out
    }

    /// Interleaved (gray, alpha) bytes when every premultiplied BGRA pixel
    /// has b = g = r; nil as soon as one pixel carries color.
    static func grayAlpha(premultipliedBGRA px: [UInt8]) -> [UInt8]? {
        var out = [UInt8]()
        out.reserveCapacity(px.count / 2)
        var i = 0
        while i < px.count {
            guard px[i] == px[i + 1], px[i + 1] == px[i + 2] else { return nil }
            out.append(px[i])
            out.append(px[i + 3])
            i += 4
        }
        return out
    }

    public struct DecodedBitmap {
        public var width: UInt32
        public var height: UInt32
        /// Premultiplied 8-bit BGRA pixels.
        public var bgra8: [UInt8]
        /// The extended-sRGB rendition actool 27.0 adds for a Display P3
        /// source, 8- or 16-bit alike, whose colors leave the sRGB gamut: the
        /// P3 pixels converted to extended sRGB, premultiplied, as
        /// little-endian half floats in R, G, B, A order ('RGBW', colorSpace
        /// 4, keyed display-gamut P3). blue_alt2.png's first pixel decodes to
        /// (0.3074, 0.4468, 0.8999, 1.0), the converted value.
        public var extendedRGBA16: [UInt8]?
    }

    /// Decode PNG bytes to premultiplied pixels. Shared with SVGSource's
    /// rasterised fanout, which feeds PNG bytes returned by the SVG rasteriser
    /// straight through this path.
    public static func decodeBGRA(_ bytes: Data) throws -> DecodedBitmap {
        var blob = MemoryBytestream(bytes: [UInt8](bytes))
        let image = try PNG.Image.decompress(stream: &blob)
        let width = UInt32(image.size.x)
        let height = UInt32(image.size.y)
        // swift-png widens 8-bit samples by 257, so the high byte is exact for
        // 8-bit sources and actool's plain downconvert for 16-bit ones.
        let rgba = image.unpack(as: PNG.RGBA<UInt16>.self)
        var out = [UInt8](repeating: 0, count: rgba.count * 4)
        for i in 0..<rgba.count {
            let px = rgba[i]
            let a = UInt16(px.a >> 8)
            out[i * 4 + 0] = UInt8((UInt16(px.b >> 8) * a + 127) / 255)
            out[i * 4 + 1] = UInt8((UInt16(px.g >> 8) * a + 127) / 255)
            out[i * 4 + 2] = UInt8((UInt16(px.r >> 8) * a + 127) / 255)
            out[i * 4 + 3] = UInt8(a)
        }
        // IceCubes oracle, 21 P3-tagged sources: actool adds the wide rendition
        // exactly when some pixel leaves sRGB by more than 3/255 after
        // conversion. The four icon sets it skips stay within 2/255 (one has
        // 11 pixels between 2 and 3/255); every widened source has hundreds of
        // pixels past 3/255.
        var wide: [UInt8]?
        if isDisplayP3(image.metadata.colorProfile) {
            let converted = extendedSRGB(rgba)
            if converted.leavesSRGB { wide = converted.pixels }
        }
        return DecodedBitmap(width: width, height: height, bgra8: out, extendedRGBA16: wide)
    }

    /// A Display P3 ICC profile, recognised by its iCCP name (Apple tools
    /// write "kCGColorSpaceDisplayP3"; Photoshop and others "Display P3").
    static func isDisplayP3(_ profile: PNG.ColorProfile?) -> Bool {
        guard let name = profile?.name.lowercased() else { return false }
        return name.contains("displayp3") || name.contains("display p3")
    }

    /// P3 pixels to premultiplied extended-sRGB half floats (R, G, B, A).
    /// Both spaces use the sRGB transfer curve and D65; the linear 3x3 maps
    /// P3 primaries to sRGB ones, and out-of-gamut values stay negative or
    /// above 1 (extended range). `leavesSRGB`: some unpremultiplied channel
    /// lies more than 3/255 outside [0, 1].
    static func extendedSRGB(_ rgba: [PNG.RGBA<UInt16>]) -> (pixels: [UInt8], leavesSRGB: Bool) {
        let linear: [Float] = (0...65535).map { code in
            let v = Float(code) / 65535
            return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
        }
        func encode(_ v: Float) -> Float {
            let m = abs(v)
            let e = m <= 0.0031308 ? m * 12.92 : 1.055 * powf(m, 1 / 2.4) - 0.055
            return v < 0 ? -e : e
        }
        let tolerance: Float = 3 / 255
        var leavesSRGB = false
        var out = [UInt8](repeating: 0, count: rgba.count * 8)
        for i in 0..<rgba.count {
            let px = rgba[i]
            let r = linear[Int(px.r)], g = linear[Int(px.g)], b = linear[Int(px.b)]
            let alpha = Float(px.a) / 65535
            let color = [
                encode(1.2249401 * r - 0.2249404 * g),
                encode(-0.0420569 * r + 1.0420571 * g),
                encode(-0.0196376 * r - 0.0786361 * g + 1.0982735 * b),
            ]
            if !leavesSRGB, color.contains(where: { $0 < -tolerance || $0 > 1 + tolerance }) {
                leavesSRGB = true
            }
            let channels = color.map { $0 * alpha } + [alpha]
            for (j, value) in channels.enumerated() {
                let half = halfFloat(value)
                out[i * 8 + j * 2] = UInt8(half & 0xFF)
                out[i * 8 + j * 2 + 1] = UInt8(half >> 8)
            }
        }
        return (out, leavesSRGB)
    }

    /// IEEE 754 binary16 bit pattern, round to nearest; saturates at the
    /// largest finite half and flushes values below the subnormal range.
    static func halfFloat(_ value: Float) -> UInt16 {
        let bits = value.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exponent = Int((bits >> 23) & 0xFF) - 127 + 15
        let mantissa = bits & 0x7F_FFFF
        if exponent >= 31 { return sign | 0x7BFF }
        if exponent <= 0 {
            guard exponent > -10 else { return sign }
            let full = mantissa | 0x80_0000
            let shift = UInt32(14 - exponent)
            let rounded = (full + (1 << (shift - 1))) >> shift
            return sign | UInt16(rounded)
        }
        let half = UInt32(exponent) << 10 | (mantissa >> 13)
        let roundBit = (mantissa >> 12) & 1
        return sign | UInt16(min(half + roundBit, 0x7BFF))
    }
}
