import Foundation
import Testing
@testable import AssetKit

/// End-to-end: compile the fixtures in Fixtures/MacOracle for macosx and
/// compare with facts from Apple's actool 27.0 (Xcode 27A266a, macOS 27.0.1)
/// for the same inputs, in Fixtures/MacOracle/oracle/*.json (made with
/// genoracle.py; Apple's binaries are not in the repo).
///
/// Known gaps, allowed here and nowhere else: Apple's packed atlases
/// (element 9, and the Dimension1 key slot a second atlas adds).
@Suite("macOS output against actool 27.0")
struct MacOracleTests {
    static let fixtures = Bundle.module.url(forResource: "MacOracle", withExtension: nil, subdirectory: "Fixtures")!

    static func oracle(_ name: String) throws -> [String: Any] {
        let url = fixtures.appendingPathComponent("oracle/\(name).json")
        return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func isKnownGap(_ name: String) -> Bool {
        name.isEmpty
    }

    static var icon: IconComposerCompiler.Input {
        .init(name: "Test", directory: fixtures.appendingPathComponent("Test.icon"), idioms: ["mac"])
    }

    static func emptyCatalog() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString).xcassets")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(#"{"info":{"author":"xcode","version":1}}"#.utf8).write(to: url.appendingPathComponent("Contents.json"))
        return url
    }

    func check(_ result: CompileResult, against name: String) throws {
        let apple = try Self.oracle(name)
        let car = try CARReader(result.carData)

        #expect(try car.keySemantics == apple["keySemantics"] as! UInt32)
        #expect(try car.platform == apple["platform"] as! String)
        let appleFormat = (apple["keyFormat"] as! [Int]).map(UInt32.init)
        #expect(try car.keyFormat == appleFormat.filter { $0 != 8 })
        #expect(try car.appearances == (apple["appearances"] as! [String: Int]).mapValues(UInt16.init))

        // Facets: ours are Apple's, with the same part; Apple's extras are gaps.
        let appleFacets = (apple["facets"] as! [String: Int])
        let ours = try car.facets
        for (facet, pairs) in ours {
            let applePart = appleFacets[facet].map(UInt16.init)
            // An Icon Composer icon's facet: actool 27.0 writes part 220 or
            // 245 at random for the same input (6 runs each, both values).
            if pairs[2] == 245, applePart == 220 { continue }
            #expect(applePart == pairs[2], "facet \(facet)")
        }
        for facet in appleFacets.keys where ours[facet] == nil {
            #expect(Self.isKnownGap(facet), "missing facet \(facet)")
        }

        // Rendition keys.
        let appleKeys = (apple["renditions"] as! [String]).map {
            $0.replacingOccurrences(of: #",?Dimension1=\d+"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "|,", with: "|")
        }
        let ourKeys = try car.renditionKeys
        #expect(Set(ourKeys).count == ourKeys.count, "duplicate rendition keys")
        for key in ourKeys {
            #expect(appleKeys.contains(key), "rendition not in Apple's car: \(key)")
        }
        for key in Set(appleKeys).subtracting(ourKeys) {
            #expect(Self.isKnownGap(String(key.prefix { $0 != "|" })), "missing rendition \(key)")
        }

        // BITMAPKEYS rows (Apple's Dimension1 column removed).
        let dimension1 = appleFormat.firstIndex(of: 8)
        let appleRows = (apple["bitmapKeys"] as! [String: [Int]]).mapValues { row -> [UInt32] in
            var row = row.map(UInt32.init)
            if let dimension1 {
                row.remove(at: 4 + dimension1)
                row[2] -= 4
                row[3] -= 1
            }
            return row
        }
        for (facet, row) in try car.bitmapKeys {
            #expect(appleRows[facet] == row, "BITMAPKEYS \(facet)")
        }

        // Partial Info.plist keys and the .icns.
        let plist = try #require(result.appIconBundle?.infoPlistAdditions)
        let applePlist = apple["partialPlist"] as! [String: String]
        #expect(Set(plist.keys) == Set(applePlist.keys))
        for (key, value) in applePlist { #expect(plist[key] as? String == value) }
        #expect(result.appIconBundle?.looseFiles.map(\.name) == ["\(applePlist["CFBundleIconFile"]!).icns"])
    }

    @Test("Icon Composer icon alone")
    func iconAlone() async throws {
        let catalog = try Self.emptyCatalog()
        defer { try? FileManager.default.removeItem(at: catalog) }
        let result = try await XCAssetCompiler(deploymentTarget: "14.0", platform: "macosx")
            .compile(catalog: catalog, appIconName: "Test", iconComposer: Self.icon)
        try check(result, against: "icon")
    }

    @Test("Icon with mac/universal and sRGB/display-P3 variants")
    func iconWithVariants() async throws {
        let result = try await XCAssetCompiler(deploymentTarget: "14.0", platform: "macosx")
            .compile(catalog: Self.fixtures.appendingPathComponent("MacVariants.xcassets"),
                     appIconName: "Test", iconComposer: Self.icon)
        try check(result, against: "variants")
    }

    @Test("Background fill: none, clear, half-transparent", arguments: ["NoFill", "ClearFill", "HalfRed"])
    func backgroundFill(name: String) async throws {
        let catalog = try Self.emptyCatalog()
        defer { try? FileManager.default.removeItem(at: catalog) }
        let icon = IconComposerCompiler.Input(
            name: name, directory: Self.fixtures.appendingPathComponent("\(name).icon"), idioms: ["mac"])
        let result = try await XCAssetCompiler(deploymentTarget: "14.0", platform: "macosx")
            .compile(catalog: catalog, appIconName: name, iconComposer: icon)
        try check(result, against: name.lowercased())
    }

    @Test("mac appiconset with the icon as alternate")
    func appIconSetWithIconAlternate() async throws {
        let result = try await XCAssetCompiler(deploymentTarget: "14.0", platform: "macosx")
            .compile(catalog: Self.fixtures.appendingPathComponent("MacAppIcon.xcassets"),
                     appIconName: "AppIcon", alternateIconComposers: [Self.icon])
        try check(result, against: "alt")
    }

    @Test("Without --app-icon, the one appiconset is not its own alternate")
    func singleAppIconNotItsOwnAlternate() async throws {
        let catalog = try #require(Bundle.module.url(forResource: "Test", withExtension: "xcassets", subdirectory: "Fixtures"))
        let result = try await XCAssetCompiler(deploymentTarget: "16.0", svgRasterizer: StubSVGRasterizer())
            .compile(catalog: catalog)
        #expect(result.appIconBundle?.alternateIconNames == [])
        let keys = try CARReader(result.carData).renditionKeys
        #expect(Set(keys).count == keys.count)
    }
}
