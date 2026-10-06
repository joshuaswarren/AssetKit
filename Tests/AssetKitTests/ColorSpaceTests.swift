import Foundation
import Testing
@testable import AssetKit

/// Pins color rendition bytes against the Xcode 27.0 actool oracle: one
/// colorset per color space (srgb, extended-srgb, display-p3,
/// extended-linear-srgb, gray-gamma-22, extended-gray), light + dark.
///
/// Oracle facts:
/// - COLR colorspace IDs: srgb 1, gray-gamma-22 2, display-p3 3,
///   extended-srgb 4, extended-linear-srgb 5, extended-gray 6.
/// - Gray spaces carry 2 components (white, alpha); RGB spaces carry 4.
/// - Components are quantized to Float32 in the Float64 slots
///   (actool writes 1.1 as 0x3FF19999A0000000).
/// - Color-only catalogs get an 8-attribute KEYFORMAT (no dimension2), so
///   rendition keys are 16 bytes; colors key at element 85 / part 217.
/// - actool writes one BITMAPKEYS row per colorset with marker 0x02.
@Suite("ColorSpace")
struct ColorSpaceTests {
    private func loadColorSet(
        name: String, space: String, lightComponents: String, darkComponents: String
    ) throws -> LoadedColorSet {
        let json = """
        {
          "colors" : [
            {
              "idiom" : "universal",
              "color" : { "platform" : "ios", "color-space" : "\(space)", "components" : \(lightComponents) }
            },
            {
              "idiom" : "universal",
              "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
              "color" : { "platform" : "ios", "color-space" : "\(space)", "components" : \(darkComponents) }
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        return LoadedColorSet(name: name, directory: URL(fileURLWithPath: "/"), contents: contents)
    }

    private func rgbComponents(_ values: [Double]) -> String {
        let keys = ["red", "green", "blue", "alpha"]
        let pairs = zip(keys, values).map { "\"\($0)\" : \"\(stringified([$1]))\"" }
        return "{ \(pairs.joined(separator: ", ")) }"
    }

    private func grayComponents(white: Double, alpha: Double = 1) -> String {
        "{ \"white\" : \"\(stringified([white]))\", \"alpha\" : \"\(stringified([alpha]))\" }"
    }

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

    private func darkRendition(_ renditions: [Rendition]) -> Rendition? {
        renditions.first { $0.appearance?.darkLuminosity == true }
    }

    private func lightRendition(_ renditions: [Rendition]) -> Rendition? {
        renditions.first { $0.appearance?.darkLuminosity != true }
    }

    /// 16-byte color rendition key per the oracle: base 8-attribute format.
    private func colorKey(appearance: UInt16, identifier: UInt16) -> Data {
        var w = ByteWriter()
        for token: UInt16 in [appearance, 0, 1, 0, 0, identifier, 85, 217] {
            w.writeLE(token)
        }
        return w.data
    }

    @Test("Every color space byte-matches actool 27.0 (light and dark)")
    func oracleParity() throws {
        // (set name, color-space, light components, COLR colorspace id, rgb?, oracle CSI)
        let cases: [(String, String, [Double], UInt8, Bool, String)] = [
            ("Srgb", "srgb", [1, 0.5, 0.25, 1], 1, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000053726762000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000100000004000000000000000000f03f000000000000e03f000000000000d03f000000000000f03f"),
            ("ExtSrgb", "extended-srgb", [1.2, -0.1, 0.5, 1], 4, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000045787453726762000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000400000004000000000000403333f33f000000a09999b9bf000000000000e03f000000000000f03f"),
            ("P3", "display-p3", [1, 0.4, 0.7, 1], 3, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000050330000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000300000004000000000000000000f03f000000a09999d93f000000606666e63f000000000000f03f"),
            ("ExtLinear", "extended-linear-srgb", [0.5, 0.25, 0.125, 1], 5, true,
             "495354430100000000000000000000000000000000000000000000000000000000000000f10300004578744c696e65617200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000030000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000500000004000000000000000000e03f000000000000d03f000000000000c03f000000000000f03f"),
            ("Gray22", "gray-gamma-22", [0.75, 1], 2, false,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000047726179323200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000020000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000200000002000000000000000000e83f000000000000f03f"),
            ("ExtGray", "extended-gray", [1.1, 1], 6, false,
             "495354430100000000000000000000000000000000000000000000000000000000000000f103000045787447726179000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000010000000000000020000000ec030000080000000000000000000000ee0300000400000001000000524c4f43010000000600000002000000000000a09999f13f000000000000f03f"),
        ]
        for (name, space, components, colorSpaceID, rgb, oracleHex) in cases {
            let set = try loadColorSet(
                name: name, space: space,
                lightComponents: rgb
                    ? rgbComponents(components)
                    : grayComponents(white: components[0]),
                darkComponents: rgb
                    ? rgbComponents([0, 0, 0, 1])
                    : grayComponents(white: 0))
            let renditions = try ColorRenderer.renditions(for: set)
            #expect(renditions.count == 2, "\(name)")

            let light = try #require(lightRendition(renditions))
            guard case .color(let lightBody) = light.body else {
                Issue.record("\(name): expected color body")
                return
            }
            // Components arrive float32-widened (actool parses component
            // strings as Float32), so compare against the widened inputs.
            #expect(lightBody.components == components.map { Double(Float($0)) }, "\(name)")
            #expect(lightBody.colorSpaceID == colorSpaceID, "\(name)")
            let csi = CSIWriter.color(name: name, body: lightBody)
            if csi != bytes(oracleHex) {
                let hex = csi.map { String(format: "%02x", $0) }.joined()
                Issue.record("\(name): CSI mismatch\n  ours:   \(hex)\n  oracle: \(oracleHex)")
            }

            // 16-byte rendition keys in the 8-attribute base format.
            let identifier = UInt16(FacetKeys.nameHash(name) & 0xFFFF)
            #expect(RenditionKey(rendition: light).encode(format: baseKeyFormat)
                == colorKey(appearance: 0, identifier: identifier), "\(name)")
            let dark = try #require(darkRendition(renditions))
            #expect(RenditionKey(rendition: dark).encode(format: baseKeyFormat)
                == colorKey(appearance: 1, identifier: identifier), "\(name)")
        }

        // Dark COLR bodies for a gray space (white 0) and extended-gray
        // (white -0.2, alpha 0.5), from the oracle.
        let grayDark = try loadColorSet(name: "Gray22", space: "gray-gamma-22",
                                        lightComponents: grayComponents(white: 0.75),
                                        darkComponents: grayComponents(white: 0))
        let grayDarkBody = try #require(darkRendition(try ColorRenderer.renditions(for: grayDark)))
        guard case .color(let darkBody) = grayDarkBody.body else {
            Issue.record("expected color body")
            return
        }
        #expect(Array(CSIWriter.color(name: "Gray22", body: darkBody)[212...])
            == Array(bytes("524c4f430100000002000000020000000000000000000000000000000000f03f")))

        // Extended-gray dark with the oracle's -0.2 white and 0.5 alpha.
        let extGrayJSON = """
        {
          "colors" : [
            {
              "idiom" : "universal",
              "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
              "color" : { "platform" : "ios", "color-space" : "extended-gray",
                          "components" : { "white" : "-0.200", "alpha" : "0.500" } }
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let extContents = try JSONDecoder().decode(
            ColorSetContents.self, from: Data(extGrayJSON.utf8))
        let extSet = LoadedColorSet(name: "ExtGray", directory: URL(fileURLWithPath: "/"), contents: extContents)
        let extDark = try #require(darkRendition(try ColorRenderer.renditions(for: extSet)))
        guard case .color(let extBody) = extDark.body else {
            Issue.record("expected color body")
            return
        }
        #expect(extBody.components == [Double(Float(-0.2)), 0.5])
        #expect(Array(CSIWriter.color(name: "ExtGray", body: extBody)[212...])
            == Array(bytes("524c4f43010000000600000002000000000000a09999c9bf000000000000e03f")))
    }

    @Test("Integer component strings divide exactly in Double (actool parses Float32 first)")
    func integerComponentPrecision() throws {
        // Apple's iconBackgroundColor oracle: "235" -> 235/255 =
        // 0.9215686274509803 as the exact Double — the Float32 pass happens
        // on the parsed string value (235 is exact), NOT on the quotient.
        let json = """
        {
          "info" : { "version" : 1, "author" : "xcode" },
          "colors" : [
            {
              "idiom" : "universal",
              "color" : {
                "color-space" : "srgb",
                "components" : { "red" : "235", "green" : "235", "blue" : "237", "alpha" : "255" }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "IntColor", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        let expected: [Double] = [235.0 / 255, 235.0 / 255, 237.0 / 255, 1.0]
        #expect(body.components == expected)
        // The stored Float64 is the exact quotient, not float32(235/255)
        // widened (which would be 0.9215686321258545).
        #expect(body.components[0] != Double(Float(235.0 / 255)))
    }

    /// Renders the numeric test components as JSON strings.
    private func stringified(_ values: [Double]) -> String {
        values.map { value in
            let rounded = (value * 1000).rounded() / 1000
            return String(format: "%.3f", rounded)
        }.joined(separator: ", ")
    }

    @Test("Decodes the real fullScreenBackgroundColor colorset (gray-gamma-22 dark)")
    func realGrayColorset() throws {
        let json = """
        {
          "info" : { "version" : 1, "author" : "xcode" },
          "colors" : [
            {
              "idiom" : "universal",
              "color" : { "platform" : "ios", "reference" : "systemBackgroundColor" }
            },
            {
              "idiom" : "universal",
              "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ],
              "color" : {
                "platform" : "ios",
                "color-space" : "gray-gamma-22",
                "components" : { "white" : "0.000", "alpha" : "1.000" }
              }
            }
          ]
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(
            name: "fullScreenBackgroundColor",
            directory: URL(fileURLWithPath: "/"),
            contents: contents
        )
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 2)
        let dark = try #require(darkRendition(renditions))
        guard case .color(let body) = dark.body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.components == [0, 1])
        #expect(body.colorSpaceID == COLRColorSpace.grayGamma22.rawValue)

        // Rendition key: 16 bytes, dark, element 85 / part 217, gray fallback
        // name stays a system reference.
        let identifier = UInt16(FacetKeys.nameHash("fullScreenBackgroundColor") & 0xFFFF)
        #expect(RenditionKey(rendition: dark).encode(format: baseKeyFormat)
            == colorKey(appearance: 1, identifier: identifier))
    }

    @Test("BITMAPKEYS carries a colorset row with marker 0x02")
    func colorBitmapKeysRow() throws {
        let set = try loadColorSet(name: "Srgb", space: "srgb",
                                   lightComponents: rgbComponents([1, 0.5, 0.25, 1]),
                                   darkComponents: rgbComponents([0, 0, 0, 1]))
        let renditions = try ColorRenderer.renditions(for: set)
        let descriptor = try #require(BitmapKeys.descriptor(
            forAsset: "Srgb", renditions: renditions, keyFormat: baseKeyFormat))
        // actool 27.0 value for a universal light+dark colorset, verbatim.
        let encoded = descriptor.encode()
        if encoded != bytes("01000000000000002400000008000000ffffffff01000000020000000100000001000000ffffffffffffffffffffffff") {
            Issue.record("descriptor mismatch: \(encoded.map { String(format: "%02x", $0) }.joined())")
        }
    }

    @Test("System color references resolve to per-color placeholder bodies")
    func systemColorPlaceholders() throws {
        func referenceSet(named name: String, referencing reference: String) throws -> LoadedColorSet {
            let json = """
            {
              "colors" : [
                {
                  "idiom" : "universal",
                  "color" : { "platform" : "ios", "reference" : "\(reference)" }
                }
              ],
              "info" : { "author" : "xcode", "version" : 1 }
            }
            """
            let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
            return LoadedColorSet(name: name, directory: URL(fileURLWithPath: "/"), contents: contents)
        }

        func bodyHex(_ data: Data) -> String {
            data[212...].map { String(format: "%02x", $0) }.joined()
        }

        // systemBackgroundColor: extended gray, white (light) / black (dark).
        let bg = CSIWriter.color(
            name: "SysBG",
            body: .init(
                components: SystemColorPlaceholders.placeholder(named: "systemBackgroundColor", dark: false).components,
                colorSpaceID: 1,
                systemName: "systemBackgroundColor",
                systemColorSpaceID: SystemColorPlaceholders.placeholder(named: "systemBackgroundColor", dark: false).colorSpaceID))
        #expect(bodyHex(bg) == "524c4f43010000000601000002000000000000000000f03f000000000000f03f524c4f43010000001500000073797374656d4261636b67726f756e64436f6c6f72")
        let bgDark = CSIWriter.color(
            name: "SysBG",
            body: .init(
                components: SystemColorPlaceholders.placeholder(named: "systemBackgroundColor", dark: true).components,
                colorSpaceID: 1,
                systemName: "systemBackgroundColor",
                systemColorSpaceID: SystemColorPlaceholders.placeholder(named: "systemBackgroundColor", dark: true).colorSpaceID))
        #expect(bodyHex(bgDark) == "524c4f430100000006010000020000000000000000000000000000000000f03f524c4f43010000001500000073797374656d4261636b67726f756e64436f6c6f72")

        // systemRedColor: sRGB RGBA placeholder, dark differs.
        let redLight = SystemColorPlaceholders.placeholder(named: "systemRedColor", dark: false)
        #expect(redLight.colorSpaceID == 0x101 && redLight.components == [1, 0.22, 0.235, 1])
        let redDark = SystemColorPlaceholders.placeholder(named: "systemRedColor", dark: true)
        #expect(redDark.colorSpaceID == 0x101 && redDark.components == [1, 0.259, 0.271, 1])

        // The spaces can differ per appearance (grouped background:
        // extended sRGB light, extended gray dark).
        #expect(SystemColorPlaceholders.placeholder(named: "systemGroupedBackgroundColor", dark: false).colorSpaceID == 0x104)
        #expect(SystemColorPlaceholders.placeholder(named: "systemGroupedBackgroundColor", dark: true).colorSpaceID == 0x106)

        // quaternarySystemFillColor bodies, oracle bytes verbatim.
        let quatLightVariant = SystemColorPlaceholders.placeholder(named: "quaternarySystemFillColor", dark: false)
        let quatLight = CSIWriter.color(
            name: "Quat",
            body: .init(
                components: quatLightVariant.components,
                colorSpaceID: 1,
                systemName: "quaternarySystemFillColor",
                systemColorSpaceID: quatLightVariant.colorSpaceID))
        #expect(bodyHex(quatLight) == "524c4f4301000000040100000400000000000060b81edd3f00000060b81edd3f000000406210e03f00000040e17ab43f524c4f4301000000190000007175617465726e61727953797374656d46696c6c436f6c6f72")
        let quatDarkVariant = SystemColorPlaceholders.placeholder(named: "quaternarySystemFillColor", dark: true)
        let quatDark = CSIWriter.color(
            name: "Quat",
            body: .init(
                components: quatDarkVariant.components,
                colorSpaceID: 1,
                systemName: "quaternarySystemFillColor",
                systemColorSpaceID: quatDarkVariant.colorSpaceID))
        #expect(bodyHex(quatDark) == "524c4f43010000000401000004000000000000c0caa1dd3f000000c0caa1dd3f000000406210e03f000000803d0ac73f524c4f4301000000190000007175617465726e61727953797374656d46696c6c436f6c6f72")

        // Unlisted system names keep the historical gray fallback.
        let unknown = SystemColorPlaceholders.placeholder(named: "someFutureSystemColor", dark: false)
        #expect(unknown.colorSpaceID == 0x102 && unknown.components == [0, 1])

        // The real NetNewsWire catalog compiles through the renderer.
        let set = try referenceSet(named: "fullScreenBackgroundColor", referencing: "systemBackgroundColor")
        let renditions = try ColorRenderer.renditions(for: set)
        #expect(renditions.count == 1)
        let light = renditions.first { $0.appearance?.darkLuminosity != true }
        guard let light, case .color(let lightBody) = light.body else {
            Issue.record("expected color body")
            return
        }
        #expect(lightBody.systemName == "systemBackgroundColor")
        #expect(lightBody.systemColorSpaceID == 0x106)
        #expect(lightBody.components == [1, 1])
    }

    @Test("Hex and 0-255 decimal component forms decode like Xcode's")
    func componentForms() throws {
        let json = """
        {
          "colors" : [
            {
              "idiom" : "universal",
              "color" : {
                "platform" : "ios",
                "color-space" : "srgb",
                "components" : { "red" : "255", "green" : "0x80", "blue" : "0", "alpha" : "0xFF" }
              }
            }
          ],
          "info" : { "author" : "xcode", "version" : 1 }
        }
        """
        let contents = try JSONDecoder().decode(ColorSetContents.self, from: Data(json.utf8))
        let set = LoadedColorSet(name: "Forms", directory: URL(fileURLWithPath: "/"), contents: contents)
        let renditions = try ColorRenderer.renditions(for: set)
        guard case .color(let body) = renditions[0].body else {
            Issue.record("expected color body")
            return
        }
        #expect(body.components == [1, 128.0 / 255, 0, 1])
    }
}
