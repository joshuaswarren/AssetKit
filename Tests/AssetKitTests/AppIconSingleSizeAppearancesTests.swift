import Foundation
import Testing
@testable import AssetKit
import PNG

/// Pins the universal single-size app icon WITH dark and tinted appearance
/// variants against Apple's actool 27.0 output for the NetNewsWire catalog
/// (~/tmp/apple-dev/oracle/nnwcar/apple):
///
/// - one 1024 rendition per (idiom, variant): base and dark are ARGB sRGB;
///   tinted has NO ARGB rendition — actool writes an 8-bit gray gamma 22
///   rendition and a 16-bit extended gray (P3) rendition instead,
/// - one MultiSized container per idiom,
/// - rendition keys carry the appearance id (dark 1 = UIAppearanceDark,
///   tinted 10 = ISAppearanceTintable) and the gamut token (tinted-16 = 1),
/// - the catalog's KEYFORMAT widens to include appearance and displayGamut,
/// - APPEARANCEKEYS gains the ISAppearanceTintable row,
/// - FACETKEYS / APPEARANCEKEYS leaves carry no inline key area and their
///   headers mark external keys with the -1 trailer (RENDITIONS keeps its
///   inline key area and the exact key length).
@Suite("AppIconSingleSizeAppearances")
struct AppIconSingleSizeAppearancesTests {
    private func bytes(_ hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    // MARK: - Fixtures

    /// Minimal valid 512x512-free: 1024x1024 would be slow; rendition keys
    /// and pixel formats do not depend on pixel size. 1x1 suffices.
    private func appIcon(
        rgba: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF],
        images: [(filename: String, idiom: String, appearance: String?)]
    ) throws -> [Rendition] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SingleSizeApp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dir = tmp.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let entries = try images.map { image -> String in
            var entry = "{\"filename\":\"\(image.filename)\",\"idiom\":\"\(image.idiom)\",\"size\":\"1024x1024\",\"scale\":\"1x\""
            if let appearance = image.appearance {
                entry += ",\"appearances\":[{\"appearance\":\"luminosity\",\"value\":\"\(appearance)\"}]"
            }
            return entry + "}"
        }
        let json = "{\"images\":[\(entries.joined(separator: ","))],\"info\":{\"author\":\"xcode\",\"version\":1}}"
        try Data(json.utf8).write(to: dir.appendingPathComponent("Contents.json"))
        for image in images {
            try Self.onePixelPNG(rgba: rgba).write(to: dir.appendingPathComponent(image.filename))
        }
        let contents = try JSONDecoder().decode(
            AppIconContents.self,
            from: Data(contentsOf: dir.appendingPathComponent("Contents.json"))
        )
        let appIcon = LoadedAppIcon(name: "AppIcon", directory: dir, contents: contents)
        let files = try AppIconPlistEmitter.emit(appIcon).iconFiles
        return try ImageRenderer.appIconRenditions(for: appIcon, files: files)
    }

    /// 1x1 RGBA PNG (default opaque white), stored-deflate (dependency-free).
    private static func onePixelPNG(rgba: [UInt8]) -> Data {
        func be32(_ value: UInt32) -> [UInt8] {
            withUnsafeBytes(of: value.bigEndian) { Array($0) }
        }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 {
                    crc = (crc & 1 != 0) ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
                }
            }
            return crc ^ 0xFFFFFFFF
        }
        func adler32(_ bytes: [UInt8]) -> UInt32 {
            var a: UInt32 = 1, b: UInt32 = 0
            for byte in bytes {
                a = (a + UInt32(byte)) % 65521
                b = (b + a) % 65521
            }
            return (b << 16) | a
        }
        let ihdr: [UInt8] = [0, 0, 0, 0x0D] + Array("IHDR".utf8)
            + [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]
            + be32(crc32(Data(Array("IHDR".utf8)) + Data([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0])))
        let raw: [UInt8] = [0] + rgba
        var deflate: [UInt8] = [0x01, UInt8(raw.count), 0, UInt8(~raw.count & 0xFF), 0xFF]
        deflate.append(contentsOf: raw)
        var zlib: [UInt8] = [0x78, 0x01]
        zlib.append(contentsOf: deflate)
        zlib.append(contentsOf: be32(adler32(raw)))
        var idat: [UInt8] = [0, 0, 0, 0] + Array("IDAT".utf8) + zlib
        idat.replaceSubrange(0..<4, with: be32(UInt32(zlib.count)))
        idat.append(contentsOf: be32(crc32(Data(idat[4...]))))
        var iend: [UInt8] = Array("IEND".utf8)
        iend.append(contentsOf: be32(crc32(Data(iend))))
        iend.insert(contentsOf: [0, 0, 0, 0], at: 0)
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + ihdr + idat + iend)
    }

    private func key(
        _ rendition: Rendition, format: [AttributeID]
    ) -> [UInt16] {
        RenditionKey(rendition: rendition).encode(format: format).withUnsafeBytes { raw in
            Array(raw).chunked(2).map { UInt16($0[0]) | (UInt16($0[1]) << 8) }
        }
    }

    // MARK: - Tests

    @Test("Universal icon with dark and tinted: rendition set, keys, pixel formats")
    func renditionSet() throws {
        // A colored pixel: colorless content compiles to GA8 (see grayContent).
        let renditions = try appIcon(rgba: [0xFF, 0x80, 0x00, 0xFF], images: [
            ("Icon_1024x1024.png", "iphone", nil),
            ("Icon_1024x1024.png", "ipad", nil),
            ("Dark Icon.png", "iphone", "dark"),
            ("Dark Icon.png", "ipad", "dark"),
            ("Tint Icon.png", "iphone", "tinted"),
            ("Tint Icon.png", "ipad", "tinted"),
        ])
        // 2 base + 2 dark + 2 tinted (colored: ARGB) + 2 MultiSized.
        #expect(renditions.count == 8)

        let format = KeyFormat.format(for: renditions)
        #expect(format == v1KeyFormat)

        struct Row: Hashable {
            var appearance: UInt16
            var scale: UInt16
            var idiom: UInt16
            var dimension2: UInt16
            var gamut: UInt16
            var part: UInt16
            var pixelFormat: BitmapBody.PixelFormat
        }
        var rows = Set<Row>()
        for rendition in renditions {
            guard case .bitmap(let body) = rendition.body else {
                // MultiSized containers: two of them (phone, pad).
                if case .multiSized = rendition.body {
                    #expect(rendition.scale == .x1 && rendition.idiom.rawValueByte <= 2)
                }
                continue
            }
            let tokens = key(rendition, format: format)
            func token(_ attribute: AttributeID) -> UInt16 {
                format.firstIndex(of: attribute).map { tokens[$0] } ?? 0
            }
            rows.insert(Row(
                appearance: token(.appearance),
                scale: token(.scale),
                idiom: token(.idiom),
                dimension2: token(.dimension2),
                gamut: token(.displayGamut),
                part: token(.part),
                pixelFormat: body.pixelFormat
            ))
        }
        let idiomPhone = Idiom.iphone.rawValueByte
        let idiomPad = Idiom.ipad.rawValueByte
        let expected: Set<Row> = [
            // base: ARGB, any appearance, scale 1, index 1.
            Row(appearance: 0, scale: 1, idiom: idiomPhone, dimension2: 1, gamut: 0, part: 220, pixelFormat: .bgra8),
            Row(appearance: 0, scale: 1, idiom: idiomPad, dimension2: 1, gamut: 0, part: 220, pixelFormat: .bgra8),
            // dark: same pixels encoding, key appearance 1.
            Row(appearance: 1, scale: 1, idiom: idiomPhone, dimension2: 1, gamut: 0, part: 220, pixelFormat: .bgra8),
            Row(appearance: 1, scale: 1, idiom: idiomPad, dimension2: 1, gamut: 0, part: 220, pixelFormat: .bgra8),
            // tinted, colored source: stays ARGB like the base, key
            // appearance 10 (IceCubes Icon.appiconset oracle). The neutral
            // GA8/GA16 form is pinned by `tintedPixels`.
            Row(appearance: 10, scale: 1, idiom: idiomPhone, dimension2: 1, gamut: 0, part: 220, pixelFormat: .bgra8),
            Row(appearance: 10, scale: 1, idiom: idiomPad, dimension2: 1, gamut: 0, part: 220, pixelFormat: .bgra8),
        ]
        #expect(rows == expected)
    }

    @Test("Gray CSI records: GA8 / GA16 pixel formats, color spaces, strides")
    func grayCSI() throws {
        let renditions = try appIcon(images: [
            ("Tint Icon.png", "iphone", "tinted"),
        ])
        var gray8CSI: Data?
        var gray16CSI: Data?
        for rendition in renditions {
            guard case .bitmap(let body) = rendition.body else { continue }
            let csi = CSIWriter.bitmap(name: body.renditionName, body: body, scaleFactor: 100)
            if body.pixelFormat == .gray8 { gray8CSI = csi }
            if body.pixelFormat == .gray16 { gray16CSI = csi }
        }
        let g8 = try #require(gray8CSI)
        let g16 = try #require(gray16CSI)

        // CSIHeader: pixfmt at 0x18 (LE multi-char: on disk reversed), cs at 0x1C.
        #expect(Array(g8[0x18..<0x1C]) == Array("GA8 ".utf8.reversed()))
        #expect(Array(g16[0x18..<0x1C]) == Array("GA16".utf8.reversed()))
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }
        #expect(u32(g8, 0x1C) == 2)  // gray gamma 22
        #expect(u32(g16, 0x1C) == 6) // extended gray

        // TVL 1007 = bytes per row (2 for GA8, 4 for GA16), 16-aligned.
        // TVL layout: 1001(28B) + 1003(36B) + 1004(16B) + 1006(12B) = 92B,
        // then 1007's tag+len (8B) precede its value.
        #expect(u32(g8, 184 + 92 + 8) == 16)  // 1 px * 2 B/px aligned to 16
        #expect(u32(g16, 184 + 92 + 8) == 16) // 1 px * 4 B/px aligned to 16

        // MLEC header: compression 3; bytesPerPixel is actool's CONSTANT 4
        // for every pixel format (even GA8, whose chunks are 2 B/px).
        #expect(u32(g8, 184 + 104 + 8) == 4)
        #expect(u32(g16, 184 + 104 + 8) == 4)
    }

    @Test("MLEC chunking matches actool: 3x floor(h/3) plus remainder, constant bpp 4")
    func mlecChunking() {
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
        }

        // 1024 rows -> 341/341/341/1, four KCBC chunks (oracle verified).
        let body = MLECBody.encode(
            width: 1024, height: 1024, bytesPerPixel: 2, opaque: true,
            pixels: [UInt8](repeating: 0x80, count: 1024 * 2 * 1024))
        #expect(u32(body, 4) == 3)  // flags: LZFSE chunks + opaque
        #expect(u32(body, 8) == 4)  // bytesPerPixel constant, even for 2 B/px GA8
        #expect(u32(body, 12) == 4) // chunk count
        var pos = 16
        var rows: [UInt32] = []
        for _ in 0..<4 {
            #expect(Array(body[pos..<pos + 4]) == Array("KCBC".utf8))
            rows.append(u32(body, pos + 12))
            pos += 20 + Int(u32(body, pos + 16))
        }
        #expect(rows == [341, 341, 341, 1])
        #expect(pos == body.count)

        // 120 rows -> three equal chunks of 40.
        let small = MLECBody.encode(
            width: 120, height: 120, opaque: false,
            pixels: [UInt8](repeating: 0, count: 120 * 120 * 4))
        #expect(u32(small, 4) == 1)  // flags: LZFSE chunks, partial alpha
        #expect(u32(small, 12) == 3)
        #expect(u32(small, 28) == 40) // first KCBC chunkHeight

        // Degenerate height 1 -> single chunk.
        let tiny = MLECBody.encode(width: 1, height: 1, opaque: false, pixels: [0, 0, 0, 0])
        #expect(u32(tiny, 12) == 1)
    }

    @Test("Colorless content compiles to GA8 gray gamma 22; colored stays ARGB")
    func grayContent() throws {
        // IceCubes ActionIcon oracle: an RGBA source with R = G = B in every
        // pixel is stored 'GA8 ', cs 2 (assetutil Encoding Gray).
        let gray = try appIcon(rgba: [0x00, 0x00, 0x00, 0x80], images: [("Icon.png", "iphone", nil)])
        let grayBodies = gray.compactMap { r -> BitmapBody? in
            if case .bitmap(let b) = r.body { return b } else { return nil }
        }
        #expect(grayBodies.count == 1)
        #expect(grayBodies.first?.pixelFormat == .gray8)
        #expect(grayBodies.first?.colorSpaceID == 2)
        #expect(grayBodies.first?.pixelsBGRA == [0x00, 0x80])
        let colored = try appIcon(rgba: [0xFF, 0x80, 0x00, 0xFF], images: [("Icon.png", "iphone", nil)])
        for r in colored {
            if case .bitmap(let b) = r.body { #expect(b.pixelFormat == .bgra8) }
        }
    }

    @Test("Display P3 pixels convert to extended-sRGB RGBA half floats")
    func displayP3Extended() {
        // IceCubes blue_alt2.png (8-bit, kCGColorSpaceDisplayP3), first pixel
        // (86, 113, 222): Apple's car stores (0.3074, 0.4468, 0.8999, 1.0).
        let px = PNG.RGBA<UInt16>(86 * 257, 113 * 257, 222 * 257, 65535)
        let converted = PNGSource.extendedSRGB([px])
        let bytes = converted.pixels
        // In gamut: no wide rendition. Pure P3 green leaves sRGB.
        #expect(!converted.leavesSRGB)
        #expect(PNGSource.extendedSRGB([PNG.RGBA<UInt16>(0, 65535, 0, 65535)]).leavesSRGB)
        let halves = stride(from: 0, to: 8, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
        // Within one half-float ULP per channel: Apple converts through the
        // embedded ICC tables, we through the standard P3-to-sRGB matrix.
        let apple: [UInt16] = [0x34EB, 0x3726, 0x3B33, 0x3C00]
        for (ours, theirs) in zip(halves, apple) {
            #expect(abs(Int(ours) - Int(theirs)) <= 1)
        }
        #expect(PNGSource.halfFloat(1) == 0x3C00)
        #expect(PNGSource.halfFloat(-2) == 0xC000)
        #expect(PNGSource.halfFloat(0.5) == 0x3800)
        #expect(PNGSource.halfFloat(100_000) == 0x7BFF)
        #expect(PNGSource.isDisplayP3(PNG.ColorProfile(name: "kCGColorSpaceDisplayP3", profile: [])))
        #expect(!PNGSource.isDisplayP3(PNG.ColorProfile(name: "sRGB IEC61966-2.1", profile: [])))
        #expect(!PNGSource.isDisplayP3(nil))
    }

    @Test("isOpaque reads the alpha channel of every pixel format")
    func opacity() throws {
        func body(_ format: BitmapBody.PixelFormat, _ pixels: [UInt8]) -> BitmapBody {
            var b = BitmapBody(width: 1, height: 1, pixelsBGRA: pixels, colorSpaceID: 1,
                               kind: .appIcon, renditionName: "x.png")
            b.pixelFormat = format
            return b
        }
        #expect(body(.bgra8, [1, 2, 3, 0xFF]).isOpaque)
        #expect(!body(.bgra8, [1, 2, 3, 0xFE]).isOpaque)
        #expect(body(.gray8, [7, 0xFF]).isOpaque)
        #expect(!body(.gray8, [0, 0x80]).isOpaque)
        // Half floats, little-endian: alpha 1.0 = 0x3C00.
        #expect(body(.gray16, [0, 0, 0x00, 0x3C]).isOpaque)
        #expect(!body(.gray16, [0, 0, 0x00, 0x38]).isOpaque)
        #expect(body(.argb16, [0, 0, 0, 0, 0, 0, 0x00, 0x3C]).isOpaque)
        #expect(!body(.argb16, [0, 0, 0, 0, 0, 0, 0x00, 0x00]).isOpaque)
        // ActionIcon shape: black + partial alpha compiles to non-opaque GA8.
        let gray = try appIcon(rgba: [0x00, 0x00, 0x00, 0x80], images: [("Icon.png", "iphone", nil)])
        for r in gray {
            if case .bitmap(let b) = r.body { #expect(!b.isOpaque) }
        }
    }

    @Test("Tinted gray conversion: Rec. 709 luma and half-float 16-bit payload")
    func tintedPixels() throws {
        let renditions = try appIcon(images: [
            ("Tint Icon.png", "iphone", "tinted"),
        ])
        // The 1x1 source pixel is opaque white: luma 255. GA8 payload is
        // [gray, alpha] = [255, 255]; GA16 payload is the half-float pair
        // 1.0 = 0x3C00 little-endian: [00 3C 00 3C].
        for rendition in renditions {
            guard case .bitmap(let body) = rendition.body else { continue }
            switch body.pixelFormat {
            case .gray8:
                #expect(body.pixelsBGRA == [255, 255])
            case .gray16:
                #expect(body.pixelsBGRA == [0x00, 0x3C, 0x00, 0x3C])
            case .bgra8:
                Issue.record("tinted variant must not carry an ARGB rendition")
            case .argb16:
                Issue.record("tinted variant must not carry an ARGB-16 rendition")
            }
        }
    }

    @Test("BITMAPKEYS slots follow the KEYFORMAT at 13 tokens (IceCubes app-all)")
    func bitmapKeysThirteenTokens() throws {
        // Apple's 13-token IceCubes car: [appearance, localization, scale,
        // idiom, subtype, glyphWeight, glyphSize, dimension2,
        // deploymentTarget, displayGamut, identifier, element, part].
        let format = canonicalKeyOrder.filter { $0 != .dimension1 }
        #expect(format.count == 13)
        func slots(_ d: BitmapKeys.Descriptor) -> [UInt32] {
            let data = d.encode()
            return (7..<14).map { i in data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) } }
        }
        let icon = try appIcon(rgba: [0xFF, 0x80, 0x00, 0xFF], images: [
            ("Icon.png", "iphone", nil), ("Icon.png", "ipad", nil),
        ])
        let single = try #require(BitmapKeys.descriptor(forAsset: "AppIcon", renditions: icon, keyFormat: format))
        #expect(slots(single) == [6, 1, 1, 1, 3, 1, 1])
        var wide = single
        wide.hasWideGamut = true
        #expect(slots(wide) == [6, 1, 1, 1, 3, 1, 3])
        let stack = BitmapKeys.Descriptor(kind: .iconComposerIcon, idiomSubtypeCount: 0, keyFormat: format)
        #expect(slots(stack) == [7, 1, 1, 1, 3, 1, 1])
        var image = BitmapKeys.Descriptor(kind: .image, idiomSubtypeCount: 0, keyFormat: format)
        #expect(slots(image) == [1, 1, 1, 1, 1, 1, 1])
        image.hasWideGamut = true
        #expect(slots(image) == [1, 1, 1, 1, 1, 1, 3])
    }

    @Test("BITMAPKEYS single-size descriptors match the cs1/tint oracles")
    func bitmapKeysDescriptors() throws {
        // cs1 oracle (base+dark, 9-token KEYFORMAT): 52 bytes,
        // [1, 0, 0x28, 9, -1, 1, 2, 6, 1, 3, -1, -1, -1].
        let dark = try appIcon(images: [
            ("Icon_1024x1024.png", "iphone", nil),
            ("Icon_1024x1024.png", "ipad", nil),
            ("Dark Icon.png", "iphone", "dark"),
            ("Dark Icon.png", "ipad", "dark"),
        ])
        let darkDescriptor = try #require(BitmapKeys.descriptor(
            forAsset: "AppIcon", renditions: dark, keyFormat: KeyFormat.format(for: dark)))
        #expect(darkDescriptor.encode() == bytes(
            "01000000000000002800000009000000ffffffff0100000002000000060000000100000003000000ffffffffffffffffffffffff"))

        // tint oracle (base+tinted, 10-token KEYFORMAT): 56 bytes,
        // [1, 0, 0x2C, 10, -1, 1, 2, 6, 1, 3, 3, -1, -1, -1].
        let tinted = try appIcon(images: [
            ("Icon_1024x1024.png", "iphone", nil),
            ("Icon_1024x1024.png", "ipad", nil),
            ("Tint Icon.png", "iphone", "tinted"),
            ("Tint Icon.png", "ipad", "tinted"),
        ])
        let tintDescriptor = try #require(BitmapKeys.descriptor(
            forAsset: "AppIcon", renditions: tinted, keyFormat: KeyFormat.format(for: tinted)))
        let tintEncoded = tintDescriptor.encode()
        let tintExpected = bytes(
            "01000000000000002c0000000a000000ffffffff010000000200000006000000010000000300000003000000ffffffffffffffffffffffff")
        if tintEncoded != tintExpected {
            Issue.record("tint descriptor mismatch")
            let gotHex = tintEncoded.map { String(format: "%02x", $0) }.joined()
            let expHex = tintExpected.map { String(format: "%02x", $0) }.joined()
            print("got      " + gotHex)
            print("expected " + expHex)
        }
    }

    @Test("AppearanceKeys registers tintable; external tree markers use -1")
    func appearanceRegistry() {
        let entries = AppearanceKeys.entries(used: [
            AppearanceKeys.any, AppearanceKeys.dark, AppearanceKeys.tintable,
        ])
        let names = entries.map { String(data: $0.key, encoding: .utf8)! }
        #expect(names == ["UIAppearanceAny", "UIAppearanceDark", "ISAppearanceTintable"])
        let values = entries.map { entry -> UInt16 in
            let bytes = [UInt8](entry.value)
            return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        }
        #expect(values == [0, 1, 10])

        // Variable-length-key trees: leaf has no inline key area and the
        // header trailer is -1 (bytes ff ff ff ff), matching Apple.
        let sorted: [(key: Data, value: Data)] = [
            (key: Data("a".utf8), value: Data([1, 0])),
            (key: Data("bb".utf8), value: Data([2, 0])),
        ]
        let leaf = BOMTree.leafExternal(
            sorted: sorted, keyBlockIDs: [8, 10], valueBlockIDs: [9, 11],
            blockSize: 64, inlineKeys: false)
        #expect(leaf.count == 64)
        let tailStart = 16 + 8 * sorted.count
        #expect(leaf[tailStart...].allSatisfy { $0 == 0 }) // no inline keys
        let header = BOMTree.header(
            leafBlockID: 7, blockSize: 64, pathCount: 2, isInternal: false,
            keyTrailerLength: -1)
        #expect([UInt8](header[21..<25]) == [0xFF, 0xFF, 0xFF, 0xFF])
        // Fixed-length-key trees keep the inline key area + exact length.
        let inlineLeaf = BOMTree.leafExternal(
            sorted: sorted, keyBlockIDs: [8, 10], valueBlockIDs: [9, 11],
            blockSize: 64, inlineKeys: true)
        #expect(inlineLeaf.count == 64 + 3)
        let inlineHeader = BOMTree.header(
            leafBlockID: 7, blockSize: 64, pathCount: 2, isInternal: false,
            keyTrailerLength: 2)
        #expect([UInt8](inlineHeader[21..<25]) == [0, 0, 0, 2])

        // actool's rule across oracle cars: FACETKEYS with one uniform key
        // ("AppIcon", 7 bytes) inlines it (trailer 7, leaf 4096 + 7); with
        // variable-length facet names (NNW) it goes external with trailer
        // -1 (leaf exactly 4096). Both shapes reproduced above by
        // inlineKeys true/false; the trailer byte encodes which.
        let singleFacet: [(key: Data, value: Data)] = [
            (key: Data("AppIcon".utf8), value: Data([0, 0, 0, 0, 3, 0, 1, 0, 85, 0, 2, 0, 220, 0, 17, 0, 193, 26])),
        ]
        let facetLeaf = BOMTree.leafExternal(
            sorted: singleFacet, keyBlockIDs: [8], valueBlockIDs: [9],
            blockSize: 4096, inlineKeys: true)
        #expect(facetLeaf.count == 4096 + 7)
        let facetHeader = BOMTree.header(
            leafBlockID: 7, blockSize: 4096, pathCount: 1, isInternal: false,
            keyTrailerLength: 7)
        #expect([UInt8](facetHeader[21..<25]) == [0, 0, 0, 7])
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}

