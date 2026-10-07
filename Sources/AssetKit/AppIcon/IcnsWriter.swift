import Foundation

/// Builds the `.icns` Apple's actool writes for a classic macOS
/// `.appiconset` (oracle: actool 27.0 on the NNW Mac AppIcon). The modern
/// file carries four elements only — Calculator, 1Password and Arc ship the
/// same set; the 32/256/512 pt entries contribute nothing:
///
/// - `ic04` 16 px "ARGB" (RLE-packed channels) from the 16 pt 1x source,
/// - `ic07` 128 px PNG from the 128 pt 1x source,
/// - `ic11` 32 px PNG from the 16 pt 2x source,
/// - `ic13` 256 px PNG from the 128 pt 2x source.
///
/// Sources are embedded as-is (no re-encode); an entry missing from the set
/// just drops its element. Larger sizes render from the car's Icon
/// renditions, as on Apple-built bundles.
enum IcnsWriter {
    enum IcnsError: Error, CustomStringConvertible {
        case badSource(asset: String, filename: String)

        var description: String {
            switch self {
            case .badSource(let asset, let filename):
                return "\(asset): cannot build icns from \(filename)"
            }
        }
    }

    static func write(_ appIcon: LoadedAppIcon) throws -> Data {
        // 8-byte header: 'icns' + total length (patched below).
        var body = Data([0x69, 0x63, 0x6e, 0x73, 0, 0, 0, 0])
        for (type, pointSize, scale) in [("ic04", 16.0, Scale.x1), ("ic07", 128.0, Scale.x1),
                                         ("ic11", 16.0, Scale.x2), ("ic13", 128.0, Scale.x2)] {
            func entry(where idiom: Idiom?) -> AppIconContents.Image? {
                appIcon.contents.images.first(where: {
                    $0.appearances == nil && $0.filename != nil
                        && (idiom == nil || $0.idiom == idiom)
                        && $0.pointSize?.0 == pointSize && $0.scale == scale
                })
            }
            // mac-idiom entries first (NNW Mac oracle); a set written with
            // universal entries instead still produces the four elements.
            guard let image = entry(where: .mac) ?? entry(where: nil) else { continue }
            let url = appIcon.directory.appendingPathComponent(image.filename!)
            let png = try Data(contentsOf: url)
            let payload = type == "ic04"
                ? try argb(fromPNG: png, asset: appIcon.name, filename: image.filename!)
                : png
            body.append(Data(type.utf8))
            body.append(be32(UInt32(payload.count + 8)))
            body.append(payload)
        }
        body.replaceSubrange(4..<8, with: be32(UInt32(body.count)))
        return body
    }

    /// ic04 payload: 'ARGB' magic, then the four channels (a, r, g, b) as
    /// PackBytes RLE streams — 0x00-0x7F copies the next n+1 bytes, 0x80-0xFF
    /// repeats the next byte 0x82..0xFF minus 0x7D times (max 130). Channel
    /// data is straight (unpremultiplied) alpha (verified: Apple's ic04
    /// decodes to exactly 4 x 256 bytes for a 16 px icon).
    static func argb(fromPNG png: Data, asset: String, filename: String) throws -> Data {
        let decoded = try PNGSource.decodeBGRA(png)
        guard decoded.width == 16, decoded.height == 16 else {
            throw IcnsError.badSource(asset: asset, filename: filename)
        }
        var a = [UInt8](), r = [UInt8](), g = [UInt8](), b = [UInt8]()
        a.reserveCapacity(256); r.reserveCapacity(256)
        g.reserveCapacity(256); b.reserveCapacity(256)
        var i = 0
        while i + 4 <= decoded.bgra8.count {
            let alpha = decoded.bgra8[i + 3]
            func straight(_ c: UInt8) -> UInt8 {
                guard alpha > 0 else { return 0 }
                return UInt8(min(255, (UInt32(c) * 255 + UInt32(alpha) / 2) / UInt32(alpha)))
            }
            b.append(straight(decoded.bgra8[i]))
            g.append(straight(decoded.bgra8[i + 1]))
            r.append(straight(decoded.bgra8[i + 2]))
            a.append(alpha)
            i += 4
        }
        var payload = Data([0x41, 0x52, 0x47, 0x42]) // 'ARGB'
        for channel in [a, r, g, b] { payload.append(pack(channel)) }
        return payload
    }

    private static func pack(_ data: [UInt8]) -> Data {
        var out = Data()
        var literal: [UInt8] = []
        func flush() {
            guard !literal.isEmpty else { return }
            out.append(UInt8(literal.count - 1))
            out.append(contentsOf: literal)
            literal.removeAll(keepingCapacity: true)
        }
        var i = 0
        while i < data.count {
            let x = data[i]
            if i + 2 < data.count, data[i + 1] == x, data[i + 2] == x {
                flush()
                var run = 3
                while i + run < data.count, data[i + run] == x { run += 1 }
                i += run
                while run > 130 {
                    out.append(0xFF); out.append(x); run -= 130
                }
                if run > 2 {
                    out.append(UInt8(run + 0x7D)); out.append(x)
                } else {
                    i -= run
                }
            } else {
                literal.append(x)
                if literal.count > 127 { flush() }
                i += 1
            }
        }
        flush()
        return out
    }

    private static func be32(_ v: UInt32) -> Data {
        withUnsafeBytes(of: v.bigEndian) { Data($0) }
    }
}
