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

    // MARK: - automatic-gradient (actool 27.2, Xcode 27B52)

    static let navy = C.IconColor(colorSpaceID: 1, components: [0.125, 0.251, 0.376, 1])
    static let darkNavy = C.IconColor(colorSpaceID: 1, components: [0.063, 0.125, 0.188, 1])

    @Test("automatic-gradient is the background of its appearance, not a system preset")
    func automaticGradient() throws {
        let specialized = try C.parseModel(["groups": [["layers": [["image-name": "circle.svg"]]]],
            "fill-specializations": [
                ["value": ["automatic-gradient": "srgb:0.12549,0.25098,0.37647,1.00000"]],
                ["appearance": "dark", "value": ["automatic-gradient": "srgb:0.06275,0.12549,0.18824,1.00000"]],
            ]])
        #expect(C.backgroundFill(specialized, appearance: nil) == .automaticGradient(Self.navy))
        #expect(C.backgroundFill(specialized, appearance: .tinted) == .automaticGradient(Self.navy))
        #expect(C.backgroundFill(specialized, appearance: .dark) == .automaticGradient(Self.darkNavy))

        // A bare automatic-gradient fill: the light background; dark stays system-dark.
        let bare = try Self.model(fill: ["automatic-gradient": "srgb:0.12549,0.25098,0.37647,1.00000"])
        #expect(C.backgroundFill(bare, appearance: nil) == .automaticGradient(Self.navy))
        #expect(C.backgroundFill(bare, appearance: .dark) == C.presetFill("system-dark"))

        // A layer's own automatic gradient is not read (no actool oracle for it).
        let layer = try Self.model(fill: nil, layerFill: ["automatic-gradient": "srgb:0.12549,0.25098,0.37647,1.00000"])
        #expect(C.resolveFill(layer.groups[0].layers[0].fills, appearance: nil) == nil)
    }

    /// Fixtures/IconFill/AutomaticGradient.icon compiled for iphoneos: each
    /// stack's background is a one-stop named gradient with the source color
    /// of its appearance (Apple: light and tinted Gradient-1 = Color-2,
    /// dark Gradient-2 = Color-3; no system-light or system-dark facet).
    @Test("automatic-gradient backgrounds in the compiled icon stack")
    func automaticGradientStack() throws {
        let fixtures = Bundle.module.url(forResource: "IconFill", withExtension: nil, subdirectory: "Fixtures")!
        let result = try C.compile(input: .init(
            name: "AppIcon", directory: fixtures.appendingPathComponent("AutomaticGradient.icon"), idioms: ["iphone"]))
        var gradients: [UInt16: (name: String, stops: [String])] = [:]
        var colors: [String: ColorBody] = [:]
        var stacks: [(Appearance?, IconImageStackBody)] = []
        for rendition in result.renditions {
            switch rendition.body {
            case .namedGradient(let body):
                gradients[UInt16(FacetKeys.nameHash(rendition.name) & 0xFFFF)] = (rendition.name, body.stopColorNames)
            case .color(let body): colors[rendition.name] = body
            case .iconImageStack(let body): stacks.append((rendition.appearance, body))
            default: break
            }
        }
        #expect(!gradients.values.contains { $0.name.hasSuffix("/system-light") || $0.name.hasSuffix("/system-dark") })

        let expected: [Appearance: (String, C.IconColor)] = [
            .light: ("AppIcon_Assets/Gradient-1", Self.navy),
            .tinted: ("AppIcon_Assets/Gradient-1", Self.navy),
            .dark: ("AppIcon_Assets/Gradient-2", Self.darkNavy),
        ]
        #expect(stacks.count == 3)
        for (appearance, stack) in stacks {
            let key = try #require(appearance)
            let (name, color) = try #require(expected[key])
            let background = try #require(stack.children.first)
            #expect(background.part == 247)
            let gradient = try #require(gradients[background.identifier])
            #expect(gradient.name == name)
            #expect(gradient.stops.count == 1)
            let stopName = try #require(gradient.stops.first)
            let stop = try #require(colors[stopName])
            #expect(stop.colorSpaceID == color.colorSpaceID)
            #expect(stop.components == color.components.map { Double(Float($0)) })
        }
    }

    @Test("A one-stop named gradient is byte-identical to actool 27.2")
    func oneStopGradientBytes() {
        // AppIcon_Assets/Gradient-1 from actool 27.2 for AutomaticGradient.icon.
        let apple = "495354430100000000000000000000000000000000000000000000000000000000000000fd03000041707049636f6e5f4173736574732f4772616469656e742d31"
            + String(repeating: "00", count: 103)
            + "1c00000001000000000000003f000000ec030000080000000000000000000000ee0300000400000001000000"
            + "415247470100000000000000000000000000003f000000000000003f0000803f00000000"
            + "1700000041707049636f6e5f4173736574732f436f6c6f722d3200"
        let ours = CSIWriter.namedGradient(
            name: "AppIcon_Assets/Gradient-1",
            body: NamedGradientBody(stopColorNames: ["AppIcon_Assets/Color-2"]))
        #expect(ours.map { String(format: "%02x", $0) }.joined() == apple)
    }
}
