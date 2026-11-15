import Foundation
import Testing
@testable import AssetKit

/// Icon Composer's `automatic-gradient` fill, from actool 27.2 (Xcode 27.2,
/// 27B52) oracles: one probe icon per base color, compiled for iphoneos.
@Suite("Icon Composer automatic gradient")
struct IconComposerAutomaticGradientTests {
    typealias C = IconComposerCompiler

    static func model(_ json: [String: Any]) throws -> C.IconModel {
        var json = json
        json["groups"] = [["layers": [["image-name": "ring.svg", "name": "ring"]]]]
        return try C.parseModel(json)
    }

    static let warmBlack = C.IconColor(colorSpaceID: 1, components: [0.102, 0.098, 0.094, 1])
    static let darkerBlack = C.IconColor(colorSpaceID: 1, components: [0.071, 0.067, 0.063, 1])

    @Test("automatic-gradient resolves to its base color, per appearance")
    func resolves() throws {
        let m = try Self.model(["fill-specializations": [
            ["value": ["automatic-gradient": "srgb:0.10196,0.09804,0.09412,1.00000"]],
            ["appearance": "dark", "value": ["automatic-gradient": "srgb:0.07059,0.06667,0.06275,1.00000"]],
        ]])
        #expect(C.backgroundFill(m, appearance: nil) == .automatic(Self.warmBlack))
        #expect(C.backgroundFill(m, appearance: .tinted) == .automatic(Self.warmBlack))
        #expect(C.backgroundFill(m, appearance: .dark) == .automatic(Self.darkerBlack))
    }

    @Test("A plain automatic-gradient fill is system-dark in dark, as actool 27.2")
    func plainFill() throws {
        let m = try Self.model(["fill": ["automatic-gradient": "srgb:0.50000,0.50000,0.50000,1.00000"]])
        #expect(C.backgroundFill(m, appearance: nil) == .automatic(C.IconColor(colorSpaceID: 1, components: [0.5, 0.5, 0.5, 1])))
        #expect(C.backgroundFill(m, appearance: .dark) == C.presetFill("system-dark"))
    }

    @Test("The named gradient body is actool 27.2's: one stop, type 0, 63 bytes")
    func body() {
        let data = CSIWriter.namedGradient(
            name: "AppIcon_Assets/Gradient-2",
            body: NamedGradientBody(stopColorNames: ["AppIcon_Assets/Color-3"], automatic: true))
        let bytes = [UInt8](data)
        // actool 27.2 rendition body for AppIcon_Assets/Gradient-2 (dark #121110).
        let oracle: [UInt8] = [
            0x41, 0x52, 0x47, 0x47, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x3f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x00, 0x00, 0x80, 0x3f,
            0x00, 0x00, 0x00, 0x00, 0x17, 0x00, 0x00, 0x00,
        ] + Array("AppIcon_Assets/Color-3\0".utf8)
        #expect(oracle.count == 63)
        #expect(Array(bytes.suffix(63)) == oracle)
        // The CSI header's rendition length (offset 180) is the body length.
        #expect(bytes[180] == 63 && bytes[181] == 0 && bytes[182] == 0 && bytes[183] == 0)
    }

    /// sRGB 8-bit of a P3 gamma color.
    static func srgb8(_ c: (Float, Float, Float, Float)) -> [Int] {
        let s = GlassRender.convert((c.0, c.1, c.2), GlassRender.p3ToSRGB)
        return [s.0, s.1, s.2].map { Int(($0 * 255).rounded()) }
    }

    @Test("Flat-image stops match actool 27.2 within 2/255 on gray bases",
          arguments: [
              // base, actool 27.2 at the top plateau (y 64), at the end of the ramp
              (0.0, 51, 0), (0.10196, 72, 26), (0.25, 102, 64), (0.5, 160, 128), (0.75, 211, 192),
          ])
    func darkStops(base: Double, top: Int, bottom: Int) {
        let stops = GlassRender.automaticStops(C.IconColor(colorSpaceID: 1, components: [base, base, base, 1]))
        #expect(stops.map(\.0) == [0.0, 0.7])
        #expect(abs(Self.srgb8(stops[0].1)[0] - top) <= 2)
        #expect(abs(Self.srgb8(stops[1].1)[0] - bottom) <= 2)
    }

    @Test("A light base keeps its color at the top and darkens toward the bottom",
          arguments: [(0.8, 204, 183), (0.9, 230, 207), (1.0, 255, 229)])
    func lightStops(base: Double, top: Int, bottom: Int) {
        let stops = GlassRender.automaticStops(C.IconColor(colorSpaceID: 1, components: [base, base, base, 1]))
        #expect(stops.map(\.0) == [0.3, 1.0])
        #expect(abs(Self.srgb8(stops[0].1)[0] - top) <= 2)
        #expect(abs(Self.srgb8(stops[1].1)[0] - bottom) <= 3)
    }
}
