import Foundation
import Testing
@testable import AssetKit

/// Golden pins against Apple actool 27.0 (Xcode 27.0, macstudio oracle):
/// a catalog containing only NetNewsWire's markAllAsRead.symbolset, the
/// Xcode flags (--platform iphoneos --minimum-deployment-target 17.0
/// --target-device iphone --target-device ipad --app-icon AppIcon).
@Suite("Symbol template")
struct SymbolTemplateTests {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Symbol")

    @Test("Guides decode: Medium baseline 110 units above origin, cap height 70.46")
    func guides() throws {
        let svg = try Data(contentsOf: Self.fixture.appendingPathComponent("markAllAsRead2.svg"))
        let parsed = try SymbolTemplate.parse(svg, asset: "markAllAsRead", filename: "markAllAsRead2.svg")
        #expect(parsed.baselineOffset[2] == 110)
        #expect(parsed.capHeight[2]! - 70.46 < 0.0000001)
        #expect(parsed.baselineOffset[1] == -320)
        #expect(parsed.baselineOffset[3] == 540)
    }

    @Test("Medium layer bounds match Apple's viewBox math")
    func bounds() throws {
        let svg = try Data(contentsOf: Self.fixture.appendingPathComponent("markAllAsRead2.svg"))
        let parsed = try SymbolTemplate.parse(svg, asset: "markAllAsRead", filename: "markAllAsRead2.svg")
        let layer = parsed.layers.first { $0.sizeClass == 2 }!
        let b = SymbolTemplate.bounds(of: layer.children)
        #expect(b.minX == 0)
        #expect(b.minY == 0)
        #expect(b.maxX == 99.60977)
        #expect(b.maxY == 149.6094)
    }

    @Test("Rewritten SVG is byte-identical to Apple's embedded payload")
    func rewrittenSVG() throws {
        let svg = try Data(contentsOf: Self.fixture.appendingPathComponent("markAllAsRead2.svg"))
        let parsed = try SymbolTemplate.parse(svg, asset: "markAllAsRead", filename: "markAllAsRead2.svg")
        let layer = parsed.layers.first { $0.sizeClass == 2 }!
        let b = SymbolTemplate.bounds(of: layer.children)
        let ours = SymbolTemplate.rewrittenSVG(layer: layer, bounds: b, scale: 0.17)
        let apple = try Data(contentsOf: Self.fixture.appendingPathComponent("apple-vector.svg"))
        if ours != apple {
            let o = String(decoding: ours, as: UTF8.self)
            let a = String(decoding: apple, as: UTF8.self)
            let chars = zip(o, a).enumerated().first { $0.1.0 != $0.1.1 }
            if let (i, _) = chars {
                let lo = max(0, i - 40)
                let hiO = min(o.count, i + 40)
                let hiA = min(a.count, i + 40)
                let oStart = o.index(o.startIndex, offsetBy: lo)
                let oEnd = o.index(o.startIndex, offsetBy: hiO)
                let aStart = a.index(a.startIndex, offsetBy: lo)
                let aEnd = a.index(a.startIndex, offsetBy: hiA)
                Issue.record("first difference at char \(i): ours '\(o[oStart..<oEnd])' apple '\(a[aStart..<aEnd])'")
            }
            #expect(o.count == a.count)
        }
        #expect(ours == apple)
    }

    func renderVector() throws -> Data {
        let svg = try Data(contentsOf: Self.fixture.appendingPathComponent("markAllAsRead2.svg"))
        let set = LoadedSymbolSet(
            name: "markAllAsRead",
            directory: Self.fixture,
            filename: "markAllAsRead2.svg"
        )
        let renditions = try SymbolRenderer.renditions(for: set, svgRasterizer: RsvgConvertRasterizer())
        let vector = renditions.first { if case .symbolVector = $0.body { return true } else { return false } }!
        guard case .symbolVector(let body) = vector.body else { fatalError() }
        return CSIWriter.symbolVector(body: body)
    }

    @Test("Vector-glyph CSI is byte-identical to Apple's rendition block")
    func vectorCSI() throws {
        let ours = try renderVector()
        let apple = try Data(contentsOf: Self.fixture.appendingPathComponent("apple-vector.csi.bin"))
        #expect(ours.count == apple.count)
        #expect([UInt8](ours) == [UInt8](apple))
    }

    @Test("Cached-bitmap CSI is byte-identical to Apple's rendition block")
    func cachedCSI() throws {
        let set = LoadedSymbolSet(
            name: "markAllAsRead",
            directory: Self.fixture,
            filename: "markAllAsRead2.svg"
        )
        let renditions = try SymbolRenderer.renditions(for: set, svgRasterizer: RsvgConvertRasterizer())
        let cached = renditions.first { rendition in
            if case .symbolCached(let body) = rendition.body { return body.cachedIndex == 0 && rendition.scale == .x1 }
            return false
        }!
        guard case .symbolCached(let body) = cached.body else { fatalError() }
        let ours = CSIWriter.symbolCached(body: body, scaleFactor: 100)
        let apple = try Data(contentsOf: Self.fixture.appendingPathComponent("apple-cached-s1-i0.csi.bin"))
        #expect(ours.count == apple.count)
        // Fully byte-identical: the single-shelf width-desc atlas layout
        // reproduces Apple's placements for this template.
        #expect([UInt8](ours) == [UInt8](apple))
    }

    @Test("Packed atlas CSI carries the dmp2 pixel record")
    func packedCSI() throws {
        let set = LoadedSymbolSet(
            name: "markAllAsRead",
            directory: Self.fixture,
            filename: "markAllAsRead2.svg"
        )
        let renditions = try SymbolRenderer.renditions(for: set, svgRasterizer: RsvgConvertRasterizer())
        let packed = renditions.first { if case .symbolPacked = $0.body { return true } else { return false } }!
        guard case .symbolPacked(let body) = packed.body else { fatalError() }
        let data = CSIWriter.symbolPacked(body: body, scaleFactor: 100)
        let bytes = [UInt8](data)
        // header: layout 1004 at offset 36, pixelFormat 'GA8 ' at 24
        #expect(bytes[24..<28] == [0x20, 0x38, 0x41, 0x47])
        #expect(body.pixelsGA.count == Int(body.width * body.height) * 2)
        // alpha plane has ink: the glyph covers part of the atlas
        #expect(body.pixelsGA.indices.contains { $0 % 2 == 1 && body.pixelsGA[$0] > 0 })
        #expect(data.count > 184)
    }

    @Test("Rendition keys carry the symbol tokens (weight 4, size 2, target 5)")
    func keys() throws {
        let svg = try Data(contentsOf: Self.fixture.appendingPathComponent("markAllAsRead2.svg"))
        let parsed = try SymbolTemplate.parse(svg, asset: "markAllAsRead", filename: "markAllAsRead2.svg")
        #expect(parsed.layers.map(\.sizeClass) == [2])
    }
}
