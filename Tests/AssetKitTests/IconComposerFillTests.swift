import Foundation
import Testing
@testable import AssetKit

/// Background and dark-layer fill rules of Icon Composer icons, from
/// actool 27.0 oracles (the same for macosx and iphoneos).
@Suite("Icon Composer fills")
struct IconComposerFillTests {
    typealias C = IconComposerCompiler

    static func model(fill: Any?, layerFill: Any? = nil) throws -> C.IconModel {
        var layer: [String: Any] = ["image-name": "ring.svg", "name": "ring"]
        if let layerFill { layer["fill"] = layerFill }
        var json: [String: Any] = ["groups": [["layers": [layer]]]]
        if let fill { json["fill"] = fill }
        return try C.parseModel(json)
    }

    static let red = C.IconColor(colorSpaceID: 3, components: [0.9, 0.1, 0.1, 1])
    static let halfRed = C.IconColor(colorSpaceID: 3, components: [0.9, 0.1, 0.1, 0.5])
    static var ringGradient: [String: Any] { ["linear-gradient": [
        "display-p3:1.00000,1.00000,1.00000,1.00000", "display-p3:0.80000,0.90000,1.00000,1.00000"]] }

    @Test("No fill: white in light, system-dark in dark, white on dark layers")
    func noFill() throws {
        let m = try Self.model(fill: nil)
        #expect(C.backgroundFill(m, appearance: nil) == .solid(C.white))
        #expect(C.backgroundFill(m, appearance: .tinted) == .solid(C.white))
        #expect(C.backgroundFill(m, appearance: .dark) == C.presetFill("system-dark"))
        #expect(C.automaticDarkFill(m, layer: m.groups[0].layers[0], lightShape: true) == .solid(C.white))
        #expect(C.automaticDarkFill(m, layer: m.groups[0].layers[0], lightShape: false) == nil)
    }

    @Test("automatic is system-light; dark layers take system-light")
    func automatic() throws {
        let m = try Self.model(fill: "automatic")
        #expect(C.backgroundFill(m, appearance: nil) == C.presetFill("system-light"))
        #expect(C.automaticDarkFill(m, layer: m.groups[0].layers[0], lightShape: true) == C.presetFill("system-light"))
    }

    @Test("A clear fill stays clear in dark; layers keep their own fill")
    func clearFill() throws {
        let clear = C.IconColor(colorSpaceID: 3, components: [0, 0, 0, 0])
        let m = try Self.model(fill: ["solid": "display-p3:0.00000,0.00000,0.00000,0.00000"], layerFill: Self.ringGradient)
        #expect(C.backgroundFill(m, appearance: .dark) == .solid(clear))
        #expect(C.automaticDarkFill(m, layer: m.groups[0].layers[0], lightShape: true) == nil)
        #expect(C.resolveFill(m.groups[0].layers[0].fills, appearance: .dark) != nil)
    }

    @Test("A plain layer fill gives way in dark, opaque for a solid background")
    func plainLayerFill() throws {
        let half = ["solid": "display-p3:0.90000,0.10000,0.10000,0.50000"]
        let withFill = try Self.model(fill: half, layerFill: Self.ringGradient)
        #expect(withFill.groups[0].layers[0].plainFill)
        #expect(C.resolveFill(withFill.groups[0].layers[0].fills, appearance: nil) != nil)
        #expect(C.automaticDarkFill(withFill, layer: withFill.groups[0].layers[0], lightShape: true) == .solid(Self.red))
        let without = try Self.model(fill: half)
        #expect(C.automaticDarkFill(without, layer: without.groups[0].layers[0], lightShape: true) == .solid(Self.halfRed))
    }
}
