import Foundation
import Testing
@testable import AssetKit

@Suite("CatalogLoader")
struct CatalogLoaderTests {
    @Test("Loads every appiconset and selects primary by name")
    func multipleAppIconSets() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let rootContents = """
        { "info": { "version": 1, "author": "xcode" } }
        """
        try Data(rootContents.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let appIconJSON = """
        { "images": [], "info": { "version": 1, "author": "xcode" } }
        """

        for name in ["AppIcon.appiconset", "AltIcon.appiconset"] {
            let dir = tmp.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(appIconJSON.utf8).write(to: dir.appendingPathComponent("Contents.json"))
        }

        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: tmp)
        #expect(Set(loaded.appIcons.map(\.name)) == ["AppIcon", "AltIcon"])
        #expect(loaded.appIcon(named: "AltIcon")?.name == "AltIcon")
        #expect(loaded.appIcon(named: nil) == nil)
        #expect(loaded.appIcon(named: "Missing") == nil)
        #expect(loaded.alternateAppIcons(primary: "AppIcon").map(\.name) == ["AltIcon"])
        #expect(Set(loaded.alternateAppIcons(primary: "Missing").map(\.name)) == ["AppIcon", "AltIcon"])
    }

    @Test("Loads empty catalog")
    func empty() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).xcassets", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let rootContents = """
        { "info": { "version": 1, "author": "xcode" } }
        """
        try Data(rootContents.utf8).write(to: tmp.appendingPathComponent("Contents.json"))

        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: tmp)
        #expect(loaded.imageSets.isEmpty)
        #expect(loaded.colorSets.isEmpty)
        #expect(loaded.appIcons.isEmpty)
    }
}
