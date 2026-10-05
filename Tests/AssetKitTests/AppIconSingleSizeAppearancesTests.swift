import Foundation
import Testing
@testable import AssetKit

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
    // MARK: - Fixtures

    /// Minimal valid 512x512-free: 1024x1024 would be slow; rendition keys
    /// and pixel formats do not depend on pixel size. 1x1 suffices.
    private func appIcon(
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
            try Self.onePixelPNG().write(to: dir.appendingPathComponent(image.filename))
        }
        let contents = try JSONDecoder().decode(
            AppIconContents.self,
            from: Data(contentsOf: dir.appendingPathComponent("Contents.json"))
        )
        let appIcon = LoadedAppIcon(name: "AppIcon", directory: dir, contents: contents)
        let files = try AppIconPlistEmitter.emit(appIcon).iconFiles
        return try ImageRenderer.appIconRenditions(for: appIcon, files: files)
    }

    /// 1x1 opaque white RGBA PNG, stored-deflate (dependency-free).
    private static func onePixelPNG() -> Data {
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
        let raw: [UInt8] = [0, 0xFF, 0xFF, 0xFF, 0xFF]
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
        let renditions = try appIcon(images: [
            ("Icon_1024x1024.png", "iphone", nil),
            ("Icon_1024x1024.png", "ipad", nil),
            ("Dark Icon.png", "iphone", "dark"),
            ("Dark Icon.png", "ipad", "dark"),
            ("Tint Icon.png", "iphone", "tinted"),
            ("Tint Icon.png", "ipad", "tinted"),
        ])
        // 2 base + 2 dark + 4 tinted (2 gray encodings x 2 idioms) + 2 MultiSized.
        #expect(renditions.count == 10)

        let format = KeyFormat.format(for: renditions)
        #expect(format == [
            .appearance, .localization, .scale, .idiom, .subtype,
            .dimension2, .displayGamut, .identifier, .element, .part,
        ])

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
            rows.insert(Row(
                appearance: tokens[0],
                scale: tokens[2],
                idiom: tokens[3],
                dimension2: tokens[5],
                gamut: tokens[6],
                part: tokens[9],
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
            // tinted 8-bit: gray gamma 22, gamut token 0.
            Row(appearance: 10, scale: 1, idiom: idiomPhone, dimension2: 1, gamut: 0, part: 220, pixelFormat: .gray8),
            Row(appearance: 10, scale: 1, idiom: idiomPad, dimension2: 1, gamut: 0, part: 220, pixelFormat: .gray8),
            // tinted 16-bit: extended gray, P3 gamut token 1.
            Row(appearance: 10, scale: 1, idiom: idiomPhone, dimension2: 1, gamut: 1, part: 220, pixelFormat: .gray16),
            Row(appearance: 10, scale: 1, idiom: idiomPad, dimension2: 1, gamut: 1, part: 220, pixelFormat: .gray16),
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

        // MLEC header: compression 3, bytesPerPixel 2 vs 4.
        #expect(u32(g8, 184 + 104 + 8) == 2)
        #expect(u32(g16, 184 + 104 + 8) == 4)
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
            }
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
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
