import Foundation
import Testing
@testable import AssetKit
import PNG

/// The classic macOS layout actool 27.0 writes for `--platform macosx`
/// (oracle: a real-world `.icon`, alone, with an imageset and a colorset,
/// and with a symbolset).
@Suite("Classic macOS schema")
struct ClassicMacSchemaTests {
    static let color = Rendition(
        name: "Tint", idiom: .universal, scale: .x1,
        body: .color(ColorBody(components: [1, 0.5, 0, 1], colorSpaceID: 1)))

    /// A rendition at Icon Index 0 (the MultiSized container of an icon).
    static let stack = Rendition(
        name: "AppIcon", idiom: .universal, scale: .x1,
        body: .multiSized(MultiSizedBody(sizes: [.init(pointWidth: 16, pointHeight: 16, iconIndex: 1)])))

    static func icon(scale: Scale, index: UInt16, side: UInt32) -> Rendition {
        Rendition(
            name: "AppIcon", idiom: .universal, scale: scale, iconIndex: index,
            body: .bitmap(BitmapBody(
                width: side, height: side,
                pixelsBGRA: [UInt8](repeating: 255, count: Int(side * side) * 4),
                colorSpaceID: 1, kind: .appIcon, renditionName: "AppIcon.png")))
    }

    @Test("Key format: classic order, dimension2 only with app icons")
    func keyFormat() {
        #expect(KeyFormat.classicMac(for: [Self.color]).map(\.rawValue) == [7, 13, 1, 2, 3, 17, 11, 12])
        #expect(KeyFormat.classicMac(for: [Self.color, Self.icon(scale: .x2, index: 1, side: 32)])
            .map(\.rawValue) == [7, 13, 1, 2, 3, 17, 9, 11, 12])
    }

    @Test("BITMAPKEYS descriptors match actool's words")
    func bitmapKeys() {
        func words(_ data: Data) -> [UInt32] {
            stride(from: 0, to: data.count, by: 4).map { i in
                data[i..<i + 4].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            }
        }
        let format = KeyFormat.classicMac(for: [Self.icon(scale: .x2, index: 1, side: 32)])
        let none = UInt32.max
        #expect(words(BitmapKeys.classicMacDescriptor(keys: [Self.color].map(RenditionKey.init), keyFormat: format))
            == [1, 0, 40, 9, none, 1, none, none, 1, none, 1, 1, 2])
        let icons = [Self.icon(scale: .x2, index: 1, side: 32), Self.icon(scale: .x1, index: 7, side: 1024)]
        #expect(words(BitmapKeys.classicMacDescriptor(keys: (icons + [Self.stack]).map(RenditionKey.init), keyFormat: format))
            == [1, 0, 40, 9, none, 1, none, none, 1, none, 0b1000_0011, 1, 6])
    }

    @Test("The car says macosx and uses NSAppearance names")
    func header() throws {
        var writer = CARWriter(deploymentTarget: "14.0", renditions: [Self.color])
        writer.classicMacSchema = true
        let data = try writer.write()
        func contains(_ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }
        #expect(contains("macosx"))
        #expect(contains("NSAppearanceNameSystem"))
        #expect(!contains("UIAppearanceAny"))
        // CARHEADER keySemantics (offset 432 in the 'RATC' block) is 1.
        let header = try #require(data.range(of: Data("RATC".utf8)))
        let semantics = data[header.lowerBound + 432..<header.lowerBound + 436]
        #expect(Array(semantics) == [1, 0, 0, 0])
    }

    static func image(_ name: String, idiom: Idiom, scale: Scale, gamut: Gamut? = nil) -> Rendition {
        Rendition(
            name: name, idiom: idiom, scale: scale, gamut: gamut,
            body: .bitmap(BitmapBody(
                width: 2, height: 2, pixelsBGRA: [UInt8](repeating: 255, count: 16),
                colorSpaceID: 1, kind: .image, renditionName: "\(name).png")))
    }

    @Test("macOS keeps mac over universal, drops other idioms and 3x")
    func macRenditionFilter() {
        let kept = XCAssetCompiler.macRenditions([
            Self.image("Pic", idiom: .universal, scale: .x2),
            Self.image("Pic", idiom: .mac, scale: .x2),
            Self.image("Plain", idiom: .universal, scale: .x2),
            Self.image("Plain", idiom: .universal, scale: .x3),
            Self.image("Phone", idiom: .iphone, scale: .x2),
            Self.image("Mix", idiom: .universal, scale: .x1),   // no mac 1x: kept
            Self.image("Mix", idiom: .mac, scale: .x2),
        ])
        #expect(kept.map { "\($0.name)/\($0.idiom.rawValue)/\($0.scale!.rawValue)" }
            == ["Pic/mac/2x", "Plain/universal/2x", "Mix/universal/1x", "Mix/mac/2x"])
    }

    @Test("Duplicate rendition keys are reported, not refused")
    func duplicateKeys() throws {
        // AssetKit does not key a light appearance next to any, so these
        // collide; output stays as before (both written), with a warning.
        let names = ["Pic", "Pic", "Other"]
        let keys = [Data([1, 2]), Data([1, 2]), Data([3, 4])]
        #expect(CARWriter.duplicateKeyAssets(names, keys: keys) == ["Pic"])
        var writer = CARWriter(deploymentTarget: "14.0", renditions: [
            Self.image("Pic", idiom: .universal, scale: .x2),
            Self.image("Pic", idiom: .mac, scale: .x2),
        ])
        writer.classicMacSchema = true
        let car = try writer.compile()
        #expect(car.data == (try writer.write()))
        #expect(car.warnings.map(\.path) == ["Pic"])
    }

    @Test("P3 variants add displayGamut (key slot and BITMAPKEYS value 3)")
    func displayGamut() {
        let renditions = [
            Self.image("Wide", idiom: .universal, scale: .x2, gamut: .sRGB),
            Self.image("Wide", idiom: .universal, scale: .x2, gamut: .displayP3),
        ]
        let format = KeyFormat.classicMac(for: renditions)
        #expect(format.map(\.rawValue) == [7, 13, 1, 2, 3, 17, 11, 12, 24])
        let words = BitmapKeys.classicMacDescriptor(keys: renditions.map(RenditionKey.init), keyFormat: format)
        #expect(Array(words.suffix(8)) == [4, 0, 0, 0, 3, 0, 0, 0])  // scale mask 2x, gamut 3
    }

    @Test("The macOS icon canvas: transparent corners, opaque body, shadow below")
    func iconCanvas() {
        let design = [PNG.RGBA<UInt8>](repeating: PNG.RGBA(255, 128, 0, 255), count: 1024 * 1024)
        let canvas = IconComposerCompiler.macIconCanvas(design)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { canvas[y * 1024 + x].a }
        #expect(alpha(0, 0) == 0 && alpha(1023, 1023) == 0)
        #expect(alpha(110, 110) == 0)                 // outside the rounded corner
        #expect(alpha(512, 512) == 255 && alpha(100, 512) == 255 && alpha(923, 512) == 255)
        #expect(canvas[512 * 1024 + 512].r == 255)    // body colour kept
        #expect(alpha(512, 940) > alpha(512, 84))     // the shadow falls below the body
        #expect(alpha(512, 940) > 0 && alpha(512, 1000) == 0)
    }
}
