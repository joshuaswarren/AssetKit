import Foundation

public struct CompileResult: Sendable {
    /// The compiled `Assets.car` bytes. Always present, even if the catalog
    /// contained no assets (callers receive a structurally valid empty CAR).
    public var carData: Data

    /// Number of renditions the catalog produced. actool writes no
    /// `Assets.car` at all when this is zero (Apple oracle: a catalog whose
    /// only asset is dropped for the platform, or an empty one, compiles to
    /// just the partial-info plist), and callers use it to match that.
    public var renditionCount: Int

    /// Glue needed to ship an `.appiconset` as part of an iOS app bundle.
    /// `nil` if the catalog contained no `.appiconset`. Present iff the
    /// catalog contained exactly one `.appiconset`.
    public var appIconBundle: AppIconBundle?

    public init(carData: Data, renditionCount: Int, appIconBundle: AppIconBundle? = nil) {
        self.carData = carData
        self.renditionCount = renditionCount
        self.appIconBundle = appIconBundle
    }
}

/// iOS-app-bundle glue derived from the catalog's `.appiconset`. The .car
/// alone is not enough to ship an iOS app icon: SpringBoard's icon-render
/// pipeline falls back to a set of loose PNGs in the bundle root, and the
/// `Info.plist` must declare them.
public struct AppIconBundle: Sendable {
    /// The basename of the `.appiconset` (e.g. "AppIcon"), used as the
    /// `CFBundleIconName` value.
    public var primaryIconName: String

    /// Alternate icon names compiled alongside the primary (actool's
    /// `--alternate-app-icon` / `--include-all-app-icons` sets, sorted).
    /// Apple's partial plist lists each as
    /// `CFBundleAlternateIcons.<name> = {CFBundleIconName: <name>}`.
    public var alternateIconNames: [String]

    /// Plist keys to merge into the app's `Info.plist`. Includes
    /// `CFBundleIconName`, `CFBundleIcons`, `CFBundleIcons~ipad`, and the
    /// flat `CFBundleIconFiles` fallback list.
    public var infoPlistAdditions: [String: any Sendable]

    /// Loose PNG files that must be copied into the app bundle root
    /// alongside `Assets.car`, named per `CFBundleIconFiles` entries (e.g.
    /// `AppIcon60x60@2x.png`). SpringBoard's icon-rendering pipeline reads
    /// these directly when CoreUI's rendition lookup misses (which happens
    /// when our CRC32-derived NameIdentifier differs from actool's hash) --
    /// without these files, home-screen icons fail to render.
    public var looseFiles: [LooseFile]

    public init(
        primaryIconName: String,
        alternateIconNames: [String] = [],
        infoPlistAdditions: [String: any Sendable],
        looseFiles: [LooseFile]
    ) {
        self.primaryIconName = primaryIconName
        self.alternateIconNames = alternateIconNames
        self.infoPlistAdditions = infoPlistAdditions
        self.looseFiles = looseFiles
    }
}

public struct LooseFile: Sendable {
    /// Filename relative to the app bundle root (e.g. "AppIcon60x60@2x.png").
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct XCAssetCompiler: Sendable {
    public var deploymentTarget: String
    /// Strategy used to rasterise `.svg` sources to PNG bytes. Defaults to
    /// `RsvgConvertRasterizer`, which shells out to `rsvg-convert`. Replace
    /// when you need a different rasteriser (no PATH dep, different
    /// performance profile, sandbox restrictions, etc).
    public var svgRasterizer: any SVGRasterizer
    /// Strategy used to measure and rasterise `.pdf` sources. Defaults to
    /// `PdftoCairoRasterizer`, which shells out to poppler's `pdfinfo` and
    /// `pdftocairo`. Replace when you need a different rasteriser.
    public var pdfRasterizer: any PDFRasterizer
    /// Strategy used to decode `.heic`/`.heif` sources. Defaults to
    /// `HeifConvertDecoder`, which shells out to libheif's `heif-convert`.
    /// Replace when you need a different decoder.
    public var heicDecoder: any HEICDecoder

    public init(
        deploymentTarget: String,
        svgRasterizer: any SVGRasterizer = RsvgConvertRasterizer(),
        pdfRasterizer: any PDFRasterizer = PdftoCairoRasterizer(),
        heicDecoder: any HEICDecoder = HeifConvertDecoder()
    ) {
        self.deploymentTarget = deploymentTarget
        self.svgRasterizer = svgRasterizer
        self.pdfRasterizer = pdfRasterizer
        self.heicDecoder = heicDecoder
    }

    /// - Parameters:
    ///   - catalog: the merged `.xcassets` directory.
    ///   - appIconName: the primary icon's name (actool `--app-icon`).
    ///   - iconComposer: the primary Icon Composer `.icon` source, compiled
    ///     layered instead of through the appiconset path.
    ///   - alternateIconComposers: alternate `.icon` sources; their renditions
    ///     join the car and their names join `CFBundleAlternateIcons`.
    ///
    /// Alternate `.appiconset`s are every loaded appiconset except the
    /// primary (actool `--include-all-app-icons`, or the explicit
    /// `--alternate-app-icon` list already applied by the caller's catalog
    /// merge). Apple 27.0 emits their renditions into the same car and one
    /// `CFBundleAlternateIcons` plist entry each; no loose files.
    public func compile(
        catalog catalogURL: URL,
        appIconName: String? = nil,
        iconComposer: IconComposerCompiler.Input? = nil,
        alternateIconComposers: [IconComposerCompiler.Input] = []
    ) async throws -> CompileResult {
        let loader = CatalogLoader()
        let loaded = try await loader.load(catalog: catalogURL)

        var renditions: [Rendition] = []

        for imageSet in loaded.imageSets {
            renditions.append(contentsOf: try ImageRenderer.renditions(
                for: imageSet,
                svgRasterizer: svgRasterizer,
                pdfRasterizer: pdfRasterizer,
                heicDecoder: heicDecoder
            ))
        }
        for colorSet in loaded.colorSets {
            renditions.append(contentsOf: try ColorRenderer.renditions(for: colorSet))
        }
        for symbolSet in loaded.symbolSets {
            renditions.append(contentsOf: try SymbolRenderer.renditions(for: symbolSet, svgRasterizer: svgRasterizer))
        }

        var appIconBundle: AppIconBundle?
        if let iconComposer {
            // Icon Composer .icon source: the layered rendition set plus the
            // loose home-screen PNGs and partial plist.
            let compiled = try IconComposerCompiler.compile(input: iconComposer)
            renditions.append(contentsOf: compiled.renditions)
            appIconBundle = compiled.appIconBundle
        } else if let appIcon = loaded.appIcon(named: appIconName) {
            let plist = try AppIconPlistEmitter.emit(appIcon)
            renditions.append(contentsOf: try ImageRenderer.appIconRenditions(for: appIcon, files: plist.iconFiles))

            var looseFiles: [LooseFile] = []
            for file in plist.iconFiles {
                let suffix = file.scale == 1 ? "" : "@\(file.scale)x"
                let target = "\(file.outputName)\(suffix).png"
                let data = try Data(contentsOf: file.sourceURL)
                looseFiles.append(LooseFile(name: target, data: data))
            }

            appIconBundle = AppIconBundle(
                primaryIconName: plist.iconName,
                infoPlistAdditions: plist.infoPlistAdditions,
                looseFiles: looseFiles
            )
        }

        var alternates = loaded.alternateAppIcons(primary: appIconName).map(\.name)
        // Each alternate .appiconset renders its own renditions into the car.
        // Apple's partial plist doesn't carry CFBundleIconFiles for them
        // (oracle: only CFBundleIconName), so no per-set plist/loose here.
        for altAppIcon in loaded.alternateAppIcons(primary: appIconName) {
            let plist = try AppIconPlistEmitter.emit(altAppIcon)
            renditions.append(contentsOf: try ImageRenderer.appIconRenditions(
                for: altAppIcon, files: plist.iconFiles))
        }
        for alternate in alternateIconComposers {
            let compiled = try IconComposerCompiler.compile(input: alternate)
            renditions.append(contentsOf: compiled.renditions)
            alternates.append(alternate.name)
        }
        appIconBundle?.alternateIconNames = alternates.sorted()

        let writer = CARWriter(deploymentTarget: deploymentTarget, renditions: renditions)
        let bytes = try writer.write()

        return CompileResult(carData: bytes, renditionCount: renditions.count, appIconBundle: appIconBundle)
    }
}
