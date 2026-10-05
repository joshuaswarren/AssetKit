import Foundation
import PNG

/// Compiles an Icon Composer `.icon` bundle (icon.json + Assets/ layer
/// images) into the layered rendition set Apple actool 27.0 emits: named
/// colors, named gradients, one image rendition per layer bitmap, one group
/// rendition per (group, appearance), one icon image stack per appearance,
/// the per-appearance pre-rendered 1024 px icon bitmaps, and the MultiSized
/// containers (IceCubesApp `AppIcon.icon` oracle).
///
/// The pre-rendered bitmaps follow IconRendering's RenderBox display list (GlassRender): the
/// background fill, per-group shadows, blur material, translucency, glass glow and highlights,
/// the chiclet rim, and the tinted appearance as monochrome content over black.
public enum IconComposerCompiler {
    public struct Input: Sendable {
        /// Icon name without the .icon extension (the --app-icon value).
        public var name: String
        /// The .icon bundle directory.
        public var directory: URL
        /// actool's --target-device values.
        public var idioms: [String]

        public init(name: String, directory: URL, idioms: [String]) {
            self.name = name
            self.directory = directory
            self.idioms = idioms
        }
    }

    struct Result: Sendable {
        var renditions: [Rendition]
        var appIconBundle: AppIconBundle
    }

    // MARK: - icon.json model

    /// An Icon Composer color: COLR color-space code + components.
    struct IconColor: Hashable {
        /// 1 sRGB, 2 gray gamma 22, 3 Display P3, 6 extended gray.
        var colorSpaceID: UInt8
        var components: [Double]
    }

    /// A resolved fill: a color, or two stop colors (vertical gradient).
    enum Fill: Hashable {
        case solid(IconColor)
        case gradient(IconColor, IconColor)
    }

    /// The three appearances actool compiles for an .icon app icon.
    static let appearances: [Appearance?] = [nil, .dark, .tinted]

    struct Layer {
        var imageName: String
        var scale: Double
        var translation: (Double, Double)
        var fills: [[String: Any]]
        var blends: [[String: Any]]
        var opacities: [[String: Any]]
        var glass: Bool
    }

    struct Group {
        var layers: [Layer]
        var scale: Double
        var translation: (Double, Double)
        var blurStrength: Double
        var shadowStyle: UInt32
        var shadowOpacity: Double
        var shadowKind: String?
        var translucency: [[String: Any]]
    }

    struct IconModel {
        var fills: [[String: Any]]       // top-level fill-specializations
        var groups: [Group]
    }

    enum IconComposerError: Error, CustomStringConvertible {
        case corruptJSON

        var description: String { "icon.json is not a JSON object" }
    }

    static func jsonDoubles(_ value: Any?) -> [Double] {
        if let values = value as? [Double] { return values }
        if let values = value as? [NSNumber] { return values.map(\.doubleValue) }
        guard let values = value as? [Any] else { return [] }
        return values.compactMap { ($0 as? NSNumber)?.doubleValue }
    }

    static func parseModel(_ json: [String: Any]) throws -> IconModel {
        var groups: [Group] = []
        for group in json["groups"] as? [[String: Any]] ?? [] {
            let groupPosition = group["position"] as? [String: Any] ?? [:]
            let groupTranslation = jsonDoubles(groupPosition["translation-in-points"])
            var layers: [Layer] = []
            for layer in group["layers"] as? [[String: Any]] ?? [] {
                guard layer["hidden"] as? Bool != true else { continue }
                let position = layer["position"] as? [String: Any] ?? [:]
                let translation = jsonDoubles(position["translation-in-points"])
                var opacities = layer["opacity-specializations"] as? [[String: Any]] ?? []
                if opacities.isEmpty, let opacity = layer["opacity"] {
                    opacities = [["value": opacity]]
                }
                var blends = layer["blend-mode-specializations"] as? [[String: Any]] ?? []
                if let mode = layer["blend-mode"] as? String, !blends.contains(where: { $0["appearance"] == nil }) {
                    blends.insert(["value": mode], at: 0)
                }
                layers.append(Layer(
                    imageName: layer["image-name"] as? String ?? "",
                    scale: (position["scale"] as? NSNumber)?.doubleValue ?? 1,
                    translation: (translation.first ?? 0, translation.count > 1 ? translation[1] : 0),
                    fills: layer["fill-specializations"] as? [[String: Any]] ?? [],
                    blends: blends,
                    opacities: opacities,
                    glass: layer["glass"] as? Bool ?? true))
            }
            let shadow = group["shadow"] as? [String: Any]
            let blur = (group["blur-material"] as? NSNumber)?.doubleValue
                ?? (group["blur-material-specializations"] as? [[String: Any]] ?? [])
                    .first { $0["appearance"] == nil }.flatMap { ($0["value"] as? NSNumber)?.doubleValue }
            var translucency = group["translucency-specializations"] as? [[String: Any]] ?? []
            if translucency.isEmpty, let direct = group["translucency"] as? [String: Any] {
                translucency = [["value": direct]]
            }
            groups.append(Group(
                layers: layers,
                scale: (groupPosition["scale"] as? NSNumber)?.doubleValue ?? 1,
                translation: (groupTranslation.first ?? 0, groupTranslation.count > 1 ? groupTranslation[1] : 0),
                blurStrength: blur ?? 0,
                shadowStyle: shadow == nil ? 0 : ((shadow?["kind"] as? String) == "neutral" ? 3 : 2),
                shadowOpacity: (shadow?["opacity"] as? NSNumber)?.doubleValue ?? 0,
                shadowKind: shadow?["kind"] as? String,
                translucency: translucency))
        }
        var fills = json["fill-specializations"] as? [[String: Any]] ?? []
        if fills.isEmpty, let fill = json["fill"] {
            // A bare fill is the light background. Dark with no specialization is system-dark.
            fills = [["value": fill], ["appearance": "dark", "value": "system-dark"]]
        }
        return IconModel(fills: fills, groups: groups)
    }

    // MARK: - Colors and fills

    /// Parses "srgb:r,g,b,a" / "display-p3:r,g,b,a" into raw Icon Composer
    /// color components (no conversion — colors are stored in their own
    /// space, exactly as the oracle shows: a display-p3 stop stays a p3
    /// COLR rendition).
    static func parseColor(_ string: String) -> IconColor? {
        let parts = string.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let values = parts[1].split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .map { ($0 * 1000).rounded() / 1000 }
        guard values.count == 4 else { return nil }
        switch parts[0] {
        case "srgb":
            return IconColor(colorSpaceID: 1, components: values)
        case "display-p3":
            return IconColor(colorSpaceID: 3, components: values)
        case "gray":
            return IconColor(colorSpaceID: 2, components: [values[0], values[3]])
        default:
            return nil
        }
    }

    /// Preset fills, decoded from the oracle's Named Gradient + Color
    /// renditions (FINDINGS 29): system-light = white to 92.5% gray,
    /// system-dark = 0.192 to 0.078 gray (top to bottom).
    static func presetFill(_ name: String) -> Fill? {
        switch name {
        case "system-light":
            return .gradient(IconColor(colorSpaceID: 2, components: [1, 1]),
                             IconColor(colorSpaceID: 2, components: [0.925, 1]))
        case "system-dark":
            return .gradient(IconColor(colorSpaceID: 2, components: [0.192, 1]),
                             IconColor(colorSpaceID: 2, components: [0.078, 1]))
        default:
            return nil
        }
    }

    /// Resolves a fill for one appearance. "automatic" uses the unqualified
    /// fill (Alt1 dark stores the default white). No unqualified fill means
    /// no overlay (IceCubes front dark).
    static func resolveFill(_ specializations: [[String: Any]], appearance: Appearance?) -> Fill? {
        guard let value = specializedValue(specializations, appearance: appearance) else { return nil }
        if let name = value as? String {
            if name == "automatic" {
                guard appearance != nil else { return nil }
                return resolveFill(specializations, appearance: nil)
            }
            return presetFill(name)
        }
        guard let dict = value as? [String: Any] else { return nil }
        if let solid = dict["solid"] as? String {
            return parseColor(solid).map { Fill.solid($0) }
        }
        if let stops = dict["linear-gradient"] as? [String], stops.count >= 2,
           let top = parseColor(stops[0]), let bottom = parseColor(stops[1]) {
            return Fill.gradient(top, bottom)
        }
        return nil
    }

    /// The specialization list's value for one appearance: the entry with
    /// that appearance first, else the entry without an appearance key.
    static func specializedValue(_ specializations: [[String: Any]], appearance: Appearance?) -> Any? {
        func matches(_ entry: [String: Any]) -> Bool {
            guard let entryAppearance = entry["appearance"] as? String else { return appearance == nil }
            switch entryAppearance {
            case "dark": return appearance == .dark
            case "tinted": return appearance == .tinted
            case "light": return appearance == .light
            default: return false
            }
        }
        return (specializations.first { matches($0) } ?? specializations.first { $0["appearance"] == nil })?["value"]
    }

    static func resolveOpacity(_ specializations: [[String: Any]], appearance: Appearance?) -> Float {
        guard let value = specializedValue(specializations, appearance: appearance) else { return 1 }
        return (value as? NSNumber)?.floatValue ?? 1
    }

    /// Resolves the translucency value for one appearance: enabled ? value : 0.
    static func resolveTranslucency(_ specializations: [[String: Any]], appearance: Appearance?) -> Float {
        guard let dict = specializedValue(specializations, appearance: appearance) as? [String: Any],
              let value = dict["value"] as? Double else { return 0 }
        return (dict["enabled"] as? Bool ?? true) ? Float(value) : 0
    }
    // MARK: - Rendering

    /// Straight-alpha 8-bit pixel of a decoded layer image.
    struct Pixel {
        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 0
    }

    static let canvasSide = 1024

    struct LoadedImage {
        var width: Int
        var height: Int
        var pixels: [Pixel]
    }

    static func decodePNG(_ bytes: Data) throws -> LoadedImage {
        struct Bytestream: PNG.BytestreamSource {
            var bytes: [UInt8]
            var offset: Int = 0
            mutating func read(count: Int) -> [UInt8]? {
                guard offset + count <= bytes.count else { return nil }
                defer { offset += count }
                return Array(bytes[offset..<offset + count])
            }
        }
        var stream = Bytestream(bytes: [UInt8](bytes))
        let image = try PNG.Image.decompress(stream: &stream)
        let rgba = image.unpack(as: PNG.RGBA<UInt8>.self)
        return LoadedImage(width: image.size.x, height: image.size.y, pixels: rgba.map { Pixel(r: $0.r, g: $0.g, b: $0.b, a: $0.a) })
    }
    static func svgPixelSize(_ data: Data) -> (Int, Int) {
        let text = String(decoding: data.prefix(512), as: UTF8.self)
        func attr(_ name: String) -> Int? {
            guard let range = text.range(of: "\(name)=\"") else { return nil }
            let token = text[range.upperBound...].prefix { $0.isNumber || $0 == "." }
            guard let value = Double(token) else { return nil }
            return max(1, Int(value.rounded()))
        }
        return (attr("width") ?? canvasSide, attr("height") ?? canvasSide)
    }

    /// Image pixels times scale, centered, plus layer and group translation. Origin is floored:
    /// half-pixel translations in AppIconAlternate2 land on the assetutil LayerPosition.
    static func placedRect(image: LoadedImage, layer: Layer, group: Group) -> (ox: Int, oy: Int, w: Int, h: Int) {
        let s = layer.scale * group.scale
        let w = max(1, Int((Double(image.width) * s).rounded()))
        let h = max(1, Int((Double(image.height) * s).rounded()))
        let tx = layer.translation.0 * group.scale + group.translation.0
        let ty = layer.translation.1 * group.scale + group.translation.1
        let ox = Int(((Double(canvasSide - w) / 2) + tx).rounded(.down))
        let oy = Int(((Double(canvasSide - h) / 2) + ty).rounded(.down))
        return (ox, oy, w, h)
    }


    /// Renders the 1024 px pre-render for one appearance as opaque BGRA, following
    /// IconRendering's display list (GlassRender).
    static func render(model: IconModel, images: [String: LoadedImage], appearance: Appearance?) -> [UInt8] {
        GlassRender.render(model: model, images: images, appearance: appearance)
    }

    // MARK: - Compilation

    static func compile(input: Input) throws -> Result {
        let jsonURL = input.directory.appendingPathComponent("icon.json")
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any] else {
            throw IconComposerError.corruptJSON
        }
        let model = try parseModel(json)
        let assets = input.directory.appendingPathComponent("Assets")

        // Decode every referenced layer image once.
        var images: [String: LoadedImage] = [:]
        var svgSources: [String: Data] = [:]
        for group in model.groups {
            for layer in group.layers {
                guard images[layer.imageName] == nil else { continue }
                let url = assets.appendingPathComponent(layer.imageName)
                let data = try Data(contentsOf: url)
                if layer.imageName.lowercased().hasSuffix(".svg") {
                    svgSources[layer.imageName] = data
                    let (w, h) = svgPixelSize(data)
                    let png = try RsvgConvertRasterizer()
                        .rasterize(svgData: data, pixelWidth: UInt32(w), pixelHeight: UInt32(h))
                    images[layer.imageName] = try decodePNG(png)
                } else {
                    images[layer.imageName] = try decodePNG(data)
                }
            }
        }

        func facetStem(_ imageName: String) -> String {
            (imageName as NSString).deletingPathExtension
        }

        // Color-1 is the extended-gray white. Backgrounds are allocated in
        // appearance order; a custom light fill is Gradient-1 and a layer
        // gradient after both backgrounds is Gradient-3.
        var colors: [IconColor] = [IconColor(colorSpaceID: 6, components: [1, 1])]
        var colorNames: [IconColor: String] = [:]
        func colorSlot(_ c: IconColor) -> String {
            if let known = colorNames[c] { return known }
            colors.append(c)
            let name = "\(input.name)_Assets/Color-\(colors.count)"
            colorNames[c] = name
            return name
        }

        var gradientFacets: [(facet: String, stops: [IconColor])] = []
        func presetSlot(_ preset: String) -> String {
            let fill = presetFill(preset)!
            if case .gradient(let top, let bottom) = fill {
                if let known = gradientFacets.first(where: { $0.stops == [top, bottom] })?.facet {
                    return known
                }
                _ = colorSlot(top)
                _ = colorSlot(bottom)
                let facet = "\(input.name)_Assets/\(preset)"
                gradientFacets.append((facet, [top, bottom]))
                return facet
            }
            fatalError("preset fills are gradients")
        }

        var fillNames: [Fill: String] = [:]
        func fillSlot(_ fill: Fill) -> String {
            if let known = fillNames[fill] { return known }
            let name: String
            switch fill {
            case .solid(let c):
                name = colorSlot(c)
            case .gradient(let top, let bottom):
                _ = colorSlot(top)
                _ = colorSlot(bottom)
                name = "\(input.name)_Assets/Gradient-\(gradientFacets.count + 1)"
                gradientFacets.append((name, [top, bottom]))
            }
            fillNames[fill] = name
            return name
        }

        // Backgrounds in appearance order, then layer fills. A custom light
        // fill is Gradient-1 and replaces system-light; a later layer gradient
        // is Gradient-3 because system-dark still occupies a slot.
        func backgroundSlot(_ appearance: Appearance?) -> String {
            if let fill = resolveFill(model.fills, appearance: appearance) {
                if case .gradient(let top, let bottom) = fill {
                    for preset in ["system-light", "system-dark"] {
                        if case .gradient(let pt, let pb)? = presetFill(preset), pt == top, pb == bottom {
                            return presetSlot(preset)
                        }
                    }
                }
                return fillSlot(fill)
            }
            return presetSlot(appearance == .dark ? "system-dark" : "system-light")
        }
        let backgroundNames = appearances.map { backgroundSlot($0) }


        // Layer fills, in traversal order (group, layer, appearance).
        for group in model.groups {
            for layer in group.layers {
                for appearance in appearances {
                    if let fill = resolveFill(layer.fills, appearance: appearance) {
                        _ = fillSlot(fill)
                    }
                }
            }
        }

        func fillName(_ layer: Layer, _ appearance: Appearance?) -> String? {
            resolveFill(layer.fills, appearance: appearance).map { fillNames[$0]! }
        }
        func blendWord(_ layer: Layer, _ appearance: Appearance?) -> UInt32 {
            specializedValue(layer.blends, appearance: appearance) as? String == "lighten" ? 5 : 0
        }

        // The single layer image rendition, shared by every group.
        var imageRenditions: [Rendition] = []
        var imageIdentifiers: [String: UInt16] = [:]
        for imageName in images.keys.sorted() {
            let stem = facetStem(imageName)
            let facet = "\(input.name)_Assets/\(stem)"
            imageIdentifiers[stem] = UInt16(FacetKeys.nameHash(facet) & 0xFFFF)
            if let svg = svgSources[imageName] {
                // Apple stores Icon Composer SVG layers as scale-free vectors
                // (CSI name image.svg, 0x0). A raster here makes assetutil SIGSEGV.
                imageRenditions.append(Rendition(
                    name: facet, idiom: .universal, scale: .x1, appearance: nil,
                    iconComposerSource: true,
                    body: .preservedSource(PreservedSourceBody(
                        format: .svg, sourceData: svg, renditionName: "image.svg"))))
            } else {
                let image = images[imageName]!
                imageRenditions.append(Rendition(
                    name: facet, idiom: .universal, scale: .x1, appearance: nil,
                    iconComposerSource: true,
                    body: .bitmap(BitmapBody(
                        width: UInt32(image.width), height: UInt32(image.height),
                        pixelsBGRA: premultipliedBGRA(image), colorSpaceID: 1, kind: .image,
                        renditionName: "image.png"))))
            }
        }

        // Groups, one rendition per (group, appearance). Group facet names:
        // "AppIcon/Group", then "AppIcon/Group 2", "AppIcon/Group 3", ...
        var groupRenditions: [Rendition] = []
        var groupFacets: [(facet: String, identifier: UInt16, group: Group)] = []
        for (index, group) in model.groups.enumerated() {
            let facet = index == 0 ? "\(input.name)/Group" : "\(input.name)/Group \(index + 1)"
            groupFacets.append((facet, UInt16(FacetKeys.nameHash(facet) & 0xFFFF), group))
            for appearance in appearances {
                let layers = group.layers.reversed().map { layer -> IconGroupLayer in
                    let image = images[layer.imageName]!
                    let rect = placedRect(image: image, layer: layer, group: group)
                    var name = fillName(layer, appearance)
                    if name == nil, layer.fills.isEmpty, appearance == .dark,
                       GlassRender.lightShape(image),
                       let inherited = resolveFill(model.fills, appearance: nil) {
                        name = fillSlot(inherited)
                    }
                    return IconGroupLayer(
                        imageFacetName: "",
                        imageIdentifier: imageIdentifiers[facetStem(layer.imageName)] ?? 0,
                        positionX: Int32(rect.ox),
                        positionY: Int32(rect.oy),
                        width: UInt32(rect.w), height: UInt32(rect.h),
                        blendMode: blendWord(layer, appearance),
                        opacity: resolveOpacity(layer.opacities, appearance: appearance),
                        fillName: name,
                        hasLighting: layer.glass)
                }
                groupRenditions.append(Rendition(
                    name: facet, idiom: .universal, scale: .x1,
                    appearance: appearance == nil ? .light : appearance,
                    iconComposerSource: true,
                    body: .iconGroup(IconGroupBody(layers: layers, csiName: "IconGroup"))))

            }
        }

        // The icon image stack, one rendition per appearance. Children: the
        // background gradient, then the groups in reverse json order
        // (topmost first — oracle order for two groups).
        var stackRenditions: [Rendition] = []
        for (appearance, backgroundName) in zip(appearances, backgroundNames) {
            let backgroundIdentifier = UInt16(FacetKeys.nameHash(backgroundName) & 0xFFFF)
            var children = [IconStackChild(
                part: 247, identifier: backgroundIdentifier,
                blurStrength: 0, translucency: 0, shadowStyle: 0, shadowOpacity: 0)]
            for groupFacet in groupFacets.reversed() {
                children.append(IconStackChild(
                    part: 246, identifier: groupFacet.identifier,
                    blurStrength: Float(groupFacet.group.blurStrength),
                    translucency: resolveTranslucency(groupFacet.group.translucency, appearance: appearance),
                    shadowStyle: groupFacet.group.shadowStyle,
                    shadowOpacity: Float(groupFacet.group.shadowOpacity)))
            }
            stackRenditions.append(Rendition(
                name: input.name, idiom: .universal, scale: .x1,
                appearance: appearance == nil ? .light : appearance,
                iconComposerSource: true,
                body: .iconImageStack(IconImageStackBody(
                    canvasSide: UInt32(canvasSide), children: children,
                    csiName: "\(input.name).iconstack"))))
        }

        // Pre-rendered icons per appearance, keyed per idiom, plus the
        // MultiSized containers.
        let idioms = input.idioms.map { Idiom(rawValue: $0) ?? .universal }
        var iconRenditions: [Rendition] = []
        var lightPixels: [UInt8] = []
        for appearance in appearances {
            let pixels = render(model: model, images: images, appearance: appearance)
            if appearance == nil { lightPixels = pixels }
            let renditionTag = renditionUUIDTag()
            for idiom in idioms {
                iconRenditions.append(Rendition(
                    name: input.name, idiom: idiom, scale: .x1,
                    appearance: appearance,
                    iconComposerSource: true, iconIndex: 1,
                    body: .bitmap(BitmapBody(
                        width: UInt32(canvasSide), height: UInt32(canvasSide),
                        pixelsBGRA: pixels, colorSpaceID: 1, kind: .appIcon,
                        renditionName:
                            "\(input.name)1024x1024_\(appearanceNameTag(appearance))_\(renditionTag).png"))))
            }
        }
        var multiSizedRenditions: [Rendition] = []
        for idiom in idioms {
            multiSizedRenditions.append(Rendition(
                name: input.name, idiom: idiom, scale: .x1,
                body: .multiSized(MultiSizedBody(sizes: [.init(pointWidth: 1024, pointHeight: 1024, iconIndex: 1)]))))
        }

        // Colors and gradients.
        var colorRenditions: [Rendition] = []
        for (index, color) in colors.enumerated() {
            colorRenditions.append(Rendition(
                name: "\(input.name)_Assets/Color-\(index + 1)", idiom: .universal, scale: .x1,
                iconComposerSource: true,
                body: .color(ColorBody(
                    components: color.components.map { Double(Float($0)) },
                    colorSpaceID: color.colorSpaceID))))
        }
        var gradientRenditions: [Rendition] = []
        for gradient in gradientFacets {
            gradientRenditions.append(Rendition(
                name: gradient.facet, idiom: .universal, scale: .x1,
                iconComposerSource: true,
                body: .namedGradient(NamedGradientBody(
                    stopColorNames: gradient.stops.map { colorNames[$0]! }))))
        }

        // Order the rendition list by rendition-key bytes: the CARWriter
        // writes rendition data blocks in list order, and the oracle's block
        // order is the key-sorted order.
        let renditions = (colorRenditions + gradientRenditions + imageRenditions
            + multiSizedRenditions + iconRenditions + groupRenditions + stackRenditions)
            .sorted { a, b in
                let ka = RenditionKey(rendition: a).encode(format: v1KeyFormat)
                let kb = RenditionKey(rendition: b).encode(format: v1KeyFormat)
                return BOMTree.byteCompare(ka, kb) < 0
            }

        // App icon bundle: loose home-screen PNGs from the light render and
        // Apple's .icon partial-plist shape (no top-level CFBundleIconName).
        var loose: [LooseFile] = []
        let lightRGBA = stride(from: 0, to: lightPixels.count, by: 4).map {
            PNG.RGBA(lightPixels[$0 + 2], lightPixels[$0 + 1], lightPixels[$0], lightPixels[$0 + 3])
        }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("iconcomposer-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        for (points, scale, suffix) in [(60, 2, "60x60@2x.png"), (76, 2, "76x76@2x~ipad.png")] {
            let file = "\(input.name)\(suffix)"
            guard idioms.contains(points == 60 ? .iphone : .ipad) else { continue }
            let side = points * scale
            let down = downsampleRGBA(lightRGBA, from: canvasSide, to: side)
            let image = PNG.Image(
                packing: down, size: (side, side),
                layout: .init(format: .rgba8(palette: [], fill: nil)))
            let path = scratch.appendingPathComponent(file).path
            try image.compress(path: path, level: 9)
            loose.append(LooseFile(name: file, data: try Data(contentsOf: URL(fileURLWithPath: path))))
        }
        let iphoneIcons = idioms.contains(.iphone) ? ["\(input.name)60x60"] : []
        let ipadIcons = idioms.contains(.ipad) ? ["\(input.name)60x60", "\(input.name)76x76"] : []
        var additions: [String: any Sendable] = [
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": iphoneIcons,
                    "CFBundleIconName": input.name,
                ] as [String: any Sendable],
            ],
        ]
        if !ipadIcons.isEmpty {
            additions["CFBundleIcons~ipad"] = [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ipadIcons,
                    "CFBundleIconName": input.name,
                ] as [String: any Sendable],
            ]
        }
        let bundle = AppIconBundle(
            primaryIconName: input.name,
            infoPlistAdditions: additions,
            looseFiles: loose)

        return Result(renditions: renditions, appIconBundle: bundle)
    }

    static func appearanceNameTag(_ appearance: Appearance?) -> String {
        switch appearance {
        case .dark: return "UIAppearanceDark"
        case .tinted: return "ISAppearanceTintable"
        default: return "UIAppearanceAny"
        }
    }

    /// The RenditionName suffix Apple appends: a per-compile UUID, a process
    /// id and a monotonic counter. Values differ per compile by design; the
    /// shape matches the oracle's.
    static func renditionUUIDTag() -> String {
        let pid = ProcessInfo.processInfo.processIdentifier
        let counter = UInt64(Date().timeIntervalSince1970 * 1000)
        return "\(UUID().uuidString)-\(pid)-\(String(format: "%016llX", counter))"
    }

    /// Premultiplied BGRA bytes for a decoded layer image (PNGSource's
    /// bitmap convention).
    static func premultipliedBGRA(_ image: LoadedImage) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(image.pixels.count * 4)
        for p in image.pixels {
            let a = Int(p.a)
            out.append(UInt8(Int(p.b) * a / 255))
            out.append(UInt8(Int(p.g) * a / 255))
            out.append(UInt8(Int(p.r) * a / 255))
            out.append(p.a)
        }
        return out
    }

    /// Area-average downsample of a square RGBA image, preserving alpha
    /// (premultiplied accumulate, then un-premultiply per target pixel).
    static func downsampleRGBA(
        _ src: [PNG.RGBA<UInt8>], from n: Int, to m: Int
    ) -> [PNG.RGBA<UInt8>] {
        var out: [PNG.RGBA<UInt8>] = []
        out.reserveCapacity(m * m)
        for y in 0..<m {
            let y0 = y * n / m, y1 = max(y0 + 1, (y + 1) * n / m)
            for x in 0..<m {
                let x0 = x * n / m, x1 = max(x0 + 1, (x + 1) * n / m)
                var r = 0, g = 0, b = 0, a = 0, count = 0
                for sy in y0..<y1 {
                    for sx in x0..<x1 {
                        let p = src[sy * n + sx], alpha = Int(p.a)
                        r += Int(p.r) * alpha; g += Int(p.g) * alpha; b += Int(p.b) * alpha
                        a += alpha; count += 1
                    }
                }
                let outAlpha = a / count
                // mean(premultiplied channel) / mean(alpha): straight color.
                // (Multiplying by 255 here saturated opaque content to white —
                // the all-white loose-PNG bug, reproduced in isolation.)
                let unpre: (Int) -> UInt8 = { channel in
                    outAlpha == 0 ? 0 : UInt8(min(255, (channel / count) / outAlpha))
                }
                out.append(PNG.RGBA(unpre(r), unpre(g), unpre(b), UInt8(outAlpha)))
            }
        }
        return out
    }
}
