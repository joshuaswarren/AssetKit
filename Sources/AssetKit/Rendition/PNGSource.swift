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
        var out = [Rendition(
            name: context.assetName,
            idiom: context.idiom,
            scale: context.scale,
            appearance: context.appearance,
            gamut: context.gamut,
            body: .bitmap(BitmapBody(
                width: decoded.width,
                height: decoded.height,
                pixelsBGRA: decoded.bgra8,
                colorSpaceID: context.gamut.colorSpaceID,
                kind: context.kind,
                renditionName: context.filename
            ))
        )]
        if let wide = decoded.bgra16 {
            // 16-bit sources get a second, extended-sRGB (P3) rendition:
            // actool 27.0 stores premultiplied half-float ARGB ('RGBW',
            // colorSpace 4) beside the 8-bit downconvert (IceCubes oracle:
            // every 16-bit source yields Encoding ARGB + ARGB-16 pairs).
            // Appearance-variant files stay 8-bit: their dark/tinted entries
            // flow through the gray conversion, which is defined on 8-bit
            // input (and Apple's own 16-bit appearance pairs only show up on
            // sets that ship explicit appearance images, e.g. IceCubes'
            // Icon.appiconset — a reported gap, not a crash).
            guard context.appearance == nil else { return out }
            var pixels = [UInt8]()
            pixels.reserveCapacity(wide.count * 2)
            for v in wide {
                let half = ImageRenderer.halfBits(Double(v) / 65535.0)
                pixels.append(UInt8(half & 0xFF))
                pixels.append(UInt8((half >> 8) & 0xFF))
            }
            out.append(Rendition(
                name: context.assetName,
                idiom: context.idiom,
                scale: context.scale,
                appearance: context.appearance,
                gamut: .displayP3,
                body: .bitmap(BitmapBody(
                    width: decoded.width,
                    height: decoded.height,
                    pixelsBGRA: pixels,
                    colorSpaceID: 4,
                    kind: context.kind,
                    pixelFormat: .argb16,
                    renditionName: context.filename
                ))
            ))
        }
        return out
    }

    public struct DecodedBitmap {
        public var width: UInt32
        public var height: UInt32
        /// Premultiplied 8-bit BGRA pixels.
        public var bgra8: [UInt8]
        /// Premultiplied 16-bit BGRA pixels; present iff the source PNG is
        /// 16-bit.
        public var bgra16: [UInt8]?
    }

    /// Decode PNG bytes to premultiplied pixels. Shared with SVGSource's
    /// rasterised fanout, which feeds PNG bytes returned by the SVG rasteriser
    /// straight through this path.
    public static func decodeBGRA(_ bytes: Data) throws -> DecodedBitmap {
        var blob = MemoryBytestream(bytes: [UInt8](bytes))
        let image = try PNG.Image.decompress(stream: &blob)
        let width = UInt32(image.size.x)
        let height = UInt32(image.size.y)
        let is16: Bool
        switch image.layout.format.pixel {
        case .v16, .rgb16, .va16, .rgba16: is16 = true
        default: is16 = false
        }
        if is16 {
            let rgba = image.unpack(as: PNG.RGBA<UInt16>.self)
            var out8 = [UInt8](repeating: 0, count: rgba.count * 4)
            var out16 = [UInt8](repeating: 0, count: rgba.count * 8)
            for i in 0..<rgba.count {
                let px = rgba[i]
                // 8-bit rendition: actool's plain high-byte downconvert,
                // premultiplied like every other 8-bit source.
                let a8 = UInt8(px.a >> 8)
                let r8 = UInt8(px.r >> 8)
                let g8 = UInt8(px.g >> 8)
                let b8 = UInt8(px.b >> 8)
                let a = UInt16(a8)
                out8[i * 4 + 0] = UInt8((UInt16(b8) * a + 127) / 255)
                out8[i * 4 + 1] = UInt8((UInt16(g8) * a + 127) / 255)
                out8[i * 4 + 2] = UInt8((UInt16(r8) * a + 127) / 255)
                out8[i * 4 + 3] = a8
                // 16-bit rendition: premultiplied at source precision,
                // stored big-endian component / little-endian half pairs.
                var halves = [UInt16](repeating: 0, count: 4)
                for (j, v) in [px.b, px.g, px.r, px.a].enumerated() {
                    let premultiplied = min(UInt32(v) * UInt32(px.a) / 65535, 65535)
                    halves[j] = ImageRenderer.halfBits(Double(premultiplied) / 65535.0)
                }
                for (j, half) in halves.enumerated() {
                    out16[i * 8 + j * 2 + 0] = UInt8(half & 0xFF)
                    out16[i * 8 + j * 2 + 1] = UInt8((half >> 8) & 0xFF)
                }
            }
            return DecodedBitmap(width: width, height: height, bgra8: out8, bgra16: out16)
        }
        let rgba: [PNG.RGBA<UInt8>] = image.unpack(as: PNG.RGBA<UInt8>.self)
        var out = [UInt8](repeating: 0, count: rgba.count * 4)
        for i in 0..<rgba.count {
            let px = rgba[i]
            let a = UInt16(px.a)
            let r = UInt8((UInt16(px.r) * a + 127) / 255)
            let g = UInt8((UInt16(px.g) * a + 127) / 255)
            let b = UInt8((UInt16(px.b) * a + 127) / 255)
            let base = i * 4
            out[base + 0] = b
            out[base + 1] = g
            out[base + 2] = r
            out[base + 3] = px.a
        }
        return DecodedBitmap(width: width, height: height, bgra8: out, bgra16: nil)
    }
}
