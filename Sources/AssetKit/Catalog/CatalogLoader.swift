import Foundation

struct LoadedCatalog: Sendable {
    var url: URL
    var imageSets: [LoadedImageSet]
    var colorSets: [LoadedColorSet]
    var symbolSets: [LoadedSymbolSet]
    /// Every `.appiconset` in the catalog. The primary icon and the
    /// alternate icons (actool's `--alternate-app-icon` / `--include-all-app-icons`)
    /// are all appiconsets; the caller selects by name.
    var appIcons: [LoadedAppIcon]

    /// The primary `.appiconset`: the one named `appIconName`. When no name
    /// is given, the single appiconset of the catalog. A name with no
    /// matching set selects nothing (the primary icon may be an Icon
    /// Composer `.icon` outside the catalog).
    func appIcon(named appIconName: String?) -> LoadedAppIcon? {
        if let appIconName {
            return appIcons.first(where: { $0.name == appIconName })
        }
        return appIcons.count == 1 ? appIcons[0] : nil
    }

    /// Every appiconset except the primary name, in catalog order. The
    /// primary is matched by NAME, not by a resolved set: with an Icon
    /// Composer `.icon` primary there is no `.appiconset` carrying the
    /// primary name, and every appiconset is then an alternate.
    func alternateAppIcons(primary appIconName: String?) -> [LoadedAppIcon] {
        guard let appIconName else { return appIcons }
        return appIcons.filter { $0.name != appIconName }
    }
}

/// One `.symbolset`: a custom SF Symbol template SVG plus its Contents.json.
struct LoadedSymbolSet: Sendable {
    var name: String
    var directory: URL
    /// The template SVG filename declared in Contents.json.
    var filename: String
    var svgURL: URL { directory.appendingPathComponent(filename) }
}

struct LoadedImageSet: Sendable {
    var name: String
    var directory: URL
    var contents: ImageSetContents
}

struct LoadedColorSet: Sendable {
    var name: String
    var directory: URL
    var contents: ColorSetContents
}

struct LoadedAppIcon: Sendable {
    var name: String
    var directory: URL
    var contents: AppIconContents
}

struct CatalogLoader: Sendable {
    init() {}

    func load(catalog url: URL) async throws -> LoadedCatalog {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw XCAssetCompilerError.notADirectory(path: url.path)
        }

        let decoder = JSONDecoder()

        var imageSets: [LoadedImageSet] = []
        var colorSets: [LoadedColorSet] = []
        var symbolSets: [LoadedSymbolSet] = []
        var appIcons: [LoadedAppIcon] = []

        try walk(url, prefix: "", fileManager: fm) { entry, prefix in
            let ext = entry.pathExtension
            let name = prefix + entry.deletingPathExtension().lastPathComponent
            switch ext {
            case "imageset":
                let contents = try decode(ImageSetContents.self, at: entry, decoder: decoder)
                imageSets.append(LoadedImageSet(name: name, directory: entry, contents: contents))
            case "colorset":
                let contents = try decode(ColorSetContents.self, at: entry, decoder: decoder)
                colorSets.append(LoadedColorSet(name: name, directory: entry, contents: contents))
            case "symbolset":
                let contents = try decode(SymbolSetContents.self, at: entry, decoder: decoder)
                guard let filename = contents.symbols.first?.filename, !filename.isEmpty else {
                    throw XCAssetCompilerError.missingReferencedFile(asset: name, filename: "(symbols[0].filename)")
                }
                symbolSets.append(LoadedSymbolSet(name: name, directory: entry, filename: filename))
            case "appiconset":
                let contents = try decode(AppIconContents.self, at: entry, decoder: decoder)
                appIcons.append(LoadedAppIcon(name: name, directory: entry, contents: contents))
            default:
                if !ext.isEmpty {
                    throw XCAssetCompilerError.unsupportedAssetType("\(name).\(ext)")
                }
            }
        }

        return LoadedCatalog(
            url: url,
            imageSets: imageSets,
            colorSets: colorSets,
            symbolSets: symbolSets,
            appIcons: appIcons
        )
    }

    private func decode<T: Decodable>(_ type: T.Type, at directory: URL, decoder: JSONDecoder) throws -> T {
        let contentsURL = directory.appendingPathComponent("Contents.json")
        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            throw XCAssetCompilerError.missingContentsJSON(path: directory.path)
        }
        do {
            let data = try Data(contentsOf: contentsURL)
            return try decoder.decode(T.self, from: data)
        } catch let error as XCAssetCompilerError {
            throw error
        } catch {
            throw XCAssetCompilerError.malformedContentsJSON(
                path: contentsURL.path,
                underlying: String(describing: error)
            )
        }
    }

    /// Visits every asset directory. A folder whose Contents.json sets
    /// `properties.provides-namespace` prefixes its assets' names with `<folder>/`, as actool does.
    private func walk(_ root: URL, prefix: String, fileManager fm: FileManager,
                      visit: (URL, String) throws -> Void) throws {
        // Sorted: directory listing order is unspecified, and it drives the
        // rendition order, hence the car's block layout.
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else { continue }
            let ext = child.pathExtension
            if ["imageset", "colorset", "appiconset", "symbolset"].contains(ext) {
                try visit(child, prefix)
            } else {
                let namespaced = providesNamespace(child)
                try walk(child, prefix: namespaced ? prefix + child.lastPathComponent + "/" : prefix,
                         fileManager: fm, visit: visit)
            }
        }
    }

    private func providesNamespace(_ folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("Contents.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let properties = json["properties"] as? [String: Any] else { return false }
        return properties["provides-namespace"] as? Bool ?? false
    }
}
