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
        /// actool's --platform value. `macosx` compiles the macOS icon set:
        /// flat icon images at 16 to 1024 pt for the system appearance,
        /// an `.icns`, and the CFBundleIconFile/CFBundleIconName plist keys.
        public var platform: String

        public init(name: String, directory: URL, idioms: [String], platform: String = "iphoneos") {
            self.name = name
            self.directory = directory
            self.idioms = idioms
            self.platform = platform
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
        /// The fill came from a plain "fill" key, not fill-specializations.
        var plainFill = false
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
                var fills = layer["fill-specializations"] as? [[String: Any]] ?? []
                if fills.isEmpty, let fill = layer["fill"] {
                    fills = [["value": fill]]
                }
                var blends = layer["blend-mode-specializations"] as? [[String: Any]] ?? []
                if let mode = layer["blend-mode"] as? String, !blends.contains(where: { $0["appearance"] == nil }) {
                    blends.insert(["value": mode], at: 0)
                }
                layers.append(Layer(
                    imageName: layer["image-name"] as? String ?? "",
                    scale: (position["scale"] as? NSNumber)?.doubleValue ?? 1,
                    translation: (translation.first ?? 0, translation.count > 1 ? translation[1] : 0),
                    fills: fills,
                    plainFill: layer["fill-specializations"] == nil && layer["fill"] != nil,
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
            // A bare fill is the light background. Dark with no specialization is
            // system-dark, except for a clear solid fill: actool keeps it clear in
            // every appearance.
            fills = isClear(fill) ? [["value": fill]]
                : [["value": fill], ["appearance": "dark", "value": "system-dark"]]
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

    /// Extended-gray white: Color-1 of every icon, and the light background
    /// of an icon.json without any fill.
    static let white = IconColor(colorSpaceID: 6, components: [1, 1])

    /// A solid fill with alpha 0 (Icon Composer's clear background).
    static func isClear(_ value: Any) -> Bool {
        guard let solid = (value as? [String: Any])?["solid"] as? String,
              let color = parseColor(solid) else { return false }
        return color.components.last == 0
    }

    /// The background fill of one appearance (actool 27.0, macosx and
    /// iphoneos oracles): the resolved fill; else system-dark in dark, white
    /// for an icon.json without any fill, system-light for "automatic".
    static func backgroundFill(_ model: IconModel, appearance: Appearance?) -> Fill {
        if let fill = resolveFill(model.fills, appearance: appearance) { return fill }
        if appearance == .dark { return presetFill("system-dark")! }
        return model.fills.isEmpty ? .solid(white) : presetFill("system-light")!
    }

    /// A dark layer's fill when the dark background is automatic (not the
    /// light one): a light-shaped layer without fill-specializations takes
    /// the light background fill. A layer with a plain fill of its own takes
    /// it too, opaque (half-transparent red background: Color-7, alpha 1).
    /// nil: the layer keeps its own dark fill.
    static func automaticDarkFill(_ model: IconModel, layer: Layer, lightShape: Bool) -> Fill? {
        guard layer.fills.isEmpty || layer.plainFill, lightShape else { return nil }
        let light = backgroundFill(model, appearance: nil)
        guard backgroundFill(model, appearance: .dark) != light else { return nil }
        if layer.plainFill, case .solid(var color) = light {
            color.components[color.components.count - 1] = 1
            return .solid(color)
        }
        return light
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
        var colors: [IconColor] = [white]
        var colorNames: [IconColor: String] = [white: "\(input.name)_Assets/Color-1"]
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
        // A fill equal to a preset gradient uses the preset's facet.
        func namedFillSlot(_ fill: Fill) -> String {
            for preset in ["system-light", "system-dark"] where fill == presetFill(preset) {
                return presetSlot(preset)
            }
            return fillSlot(fill)
        }
        func backgroundSlot(_ appearance: Appearance?) -> String {
            namedFillSlot(backgroundFill(model, appearance: appearance))
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
                    if appearance == .dark, let inherited = automaticDarkFill(
                        model, layer: layer, lightShape: GlassRender.lightShape(image)) {
                        name = namedFillSlot(inherited)
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
            // A solid background is a color facet (part 217), else a gradient (247).
            let solid = if case .solid = backgroundFill(model, appearance: appearance) { true } else { false }
            var children = [IconStackChild(
                part: solid ? RenditionKey.Part.color.rawValue : 247, identifier: backgroundIdentifier,
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
        // macOS renders its own flat icon set (compileMacIcons): no iOS
        // per-idiom pre-renders, so no render pass here.
        let idioms = input.platform == "macosx" ? [] : input.idioms.map { Idiom(rawValue: $0) ?? .universal }
        var iconRenditions: [Rendition] = []
        var lightPixels: [UInt8] = []
        for appearance in input.platform == "macosx" ? [] : appearances {
            let pixels = render(model: model, images: images, appearance: appearance)
            if appearance == nil { lightPixels = pixels }
            let renditionTag = renditionUUIDTag(name: input.name, appearance: appearance, pixels: pixels)
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

        if input.platform == "macosx" {
            return try compileMacIcons(
                input: input, model: model, images: images,
                otherRenditions: colorRenditions + gradientRenditions + imageRenditions
                    + groupRenditions + stackRenditions)
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

    /// macOS: the flat icon images Finder and the Dock draw (actool 27.0
    /// macosx oracle). Seven Icon Image renditions for the system appearance
    /// only, 16 to 512 pt at 2x and 1024 pt at 1x, Icon Index 1 to 7; one
    /// MultiSized container listing the seven sizes; the `.icns`; and the
    /// flat CFBundleIconFile/CFBundleIconName keys. The dark and tinted
    /// looks come from the layered stack, as on Apple-built bundles.
    static func compileMacIcons(
        input: Input, model: IconModel, images: [String: LoadedImage], otherRenditions: [Rendition]
    ) throws -> Result {
        let straight = macIconCanvas(
            straightRGBA(fromPremultipliedBGRA: render(model: model, images: images, appearance: nil)))
        let light = premultipliedBGRA(fromStraightRGBA: straight)
        var downsampled: [Int: [PNG.RGBA<UInt8>]] = [:]
        func pixels(side: Int) -> [PNG.RGBA<UInt8>] {
            if let cached = downsampled[side] { return cached }
            let result = downsampleRGBA(straight, from: canvasSide, to: side)
            downsampled[side] = result
            return result
        }
        let sizes: [(points: Int, scale: Scale)] = [
            (16, .x2), (32, .x2), (64, .x2), (128, .x2), (256, .x2), (512, .x2), (1024, .x1),
        ]
        var icons: [Rendition] = []
        var sizeEntries: [MultiSizedBody.Size] = []
        for (index, size) in sizes.enumerated() {
            let side = size.points * size.scale.factor
            let bitmap = side == canvasSide ? light : premultipliedBGRA(fromStraightRGBA: pixels(side: side))
            icons.append(Rendition(
                name: input.name, idiom: .universal, scale: size.scale,
                appearance: nil,
                iconComposerSource: true, iconIndex: UInt16(index + 1),
                body: .bitmap(BitmapBody(
                    width: UInt32(side), height: UInt32(side),
                    pixelsBGRA: bitmap, colorSpaceID: 1, kind: .appIcon,
                    renditionName:
                        "\(input.name)\(size.points)x\(size.points)_NSAppearanceNameSystem_\(renditionUUIDTag(name: input.name, appearance: nil, pixels: bitmap)).png"))))
            sizeEntries.append(.init(
                pointWidth: UInt32(size.points), pointHeight: UInt32(size.points), iconIndex: UInt32(index + 1)))
        }
        let multiSized = Rendition(
            name: input.name, idiom: .universal, scale: .x1,
            body: .multiSized(MultiSizedBody(sizes: sizeEntries)))

        var pngs: [Int: Data] = [:]
        for side in [16, 32, 128, 256] {
            pngs[side] = try pngData(pixels(side: side), side: side)
        }
        let bundle = AppIconBundle(
            primaryIconName: input.name,
            infoPlistAdditions: [
                "CFBundleIconFile": input.name,
                "CFBundleIconName": input.name,
            ] as [String: any Sendable],
            looseFiles: [LooseFile(
                name: "\(input.name).icns",
                data: try IcnsWriter.write(iconName: input.name, pngs: pngs))])
        return Result(renditions: otherRenditions + icons + [multiSized], appIconBundle: bundle)
    }

    /// The macOS app icon on its 1024 px canvas, from the full-bleed design
    /// render: the design scaled to an 824 px body at (100, 100), a rounded
    /// rectangle with 186 px corners, over a black drop shadow (Gaussian,
    /// sigma 16, 8 px down, opacity 0.248). Fitted to actool 27.0's flat
    /// 1024 px icon: the body edge matches to under half a pixel on
    /// average. macOS before 26 draws these flat images as they are.
    static func macIconCanvas(_ design: [PNG.RGBA<UInt8>]) -> [PNG.RGBA<UInt8>] {
        let n = canvasSide, origin = 100, side = 824, radius = 186.0
        let body = downsampleRGBA(design, from: n, to: side)

        // Body coverage, 4x4 supersampled.
        var coverage = [Float](repeating: 0, count: side * side)
        let half = Double(side) / 2, inner = half - radius
        for y in 0..<side {
            for x in 0..<side {
                var hits = 0
                for sy in 0..<4 {
                    for sx in 0..<4 {
                        let px = abs(Double(x) + (Double(sx) + 0.5) / 4 - half) - inner
                        let py = abs(Double(y) + (Double(sy) + 0.5) / 4 - half) - inner
                        let qx = max(px, 0), qy = max(py, 0)
                        if qx * qx + qy * qy <= radius * radius { hits += 1 }
                    }
                }
                coverage[y * side + x] = Float(hits) / 16
            }
        }

        // Shadow: the coverage 8 px lower, blurred (separable Gaussian).
        var shadow = [Float](repeating: 0, count: n * n)
        for y in 0..<side {
            for x in 0..<side {
                shadow[(y + origin + 8) * n + x + origin] = coverage[y * side + x]
            }
        }
        let sigma: Float = 16, reach = 48
        let kernel = (-reach...reach).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let total = kernel.reduce(0, +)
        let weights = kernel.map { $0 / total }
        var pass = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                var sum: Float = 0
                for k in -reach...reach where x + k >= 0 && x + k < n {
                    sum += shadow[y * n + x + k] * weights[k + reach]
                }
                pass[y * n + x] = sum
            }
        }
        for y in 0..<n {
            for x in 0..<n {
                var sum: Float = 0
                for k in -reach...reach where y + k >= 0 && y + k < n {
                    sum += pass[(y + k) * n + x] * weights[k + reach]
                }
                shadow[y * n + x] = sum * 0.248
            }
        }

        // Body over the black shadow, straight alpha.
        var out = [PNG.RGBA<UInt8>]()
        out.reserveCapacity(n * n)
        for y in 0..<n {
            for x in 0..<n {
                let bx = x - origin, by = y - origin
                var bodyAlpha: Float = 0
                var color = (r: Float(0), g: Float(0), b: Float(0))
                if bx >= 0, bx < side, by >= 0, by < side {
                    let p = body[by * side + bx]
                    bodyAlpha = coverage[by * side + bx] * Float(p.a) / 255
                    color = (Float(p.r), Float(p.g), Float(p.b))
                }
                let a = bodyAlpha + shadow[y * n + x] * (1 - bodyAlpha)
                func channel(_ c: Float) -> UInt8 {
                    a <= 0 ? 0 : UInt8(min(255, (c * bodyAlpha / a).rounded()))
                }
                out.append(PNG.RGBA(channel(color.r), channel(color.g), channel(color.b),
                                    UInt8(min(255, (a * 255).rounded()))))
            }
        }
        return out
    }

    /// Straight-alpha RGBA from premultiplied BGRA (the render's format).
    static func straightRGBA(fromPremultipliedBGRA bgra: [UInt8]) -> [PNG.RGBA<UInt8>] {
        stride(from: 0, to: bgra.count, by: 4).map { i in
            let a = Int(bgra[i + 3])
            func un(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, Int(c) * 255 / a)) }
            return PNG.RGBA(un(bgra[i + 2]), un(bgra[i + 1]), un(bgra[i]), bgra[i + 3])
        }
    }

    /// Premultiplied BGRA (BitmapBody's format) from straight-alpha RGBA.
    static func premultipliedBGRA(fromStraightRGBA rgba: [PNG.RGBA<UInt8>]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(rgba.count * 4)
        for p in rgba {
            let a = Int(p.a)
            out.append(UInt8(Int(p.b) * a / 255))
            out.append(UInt8(Int(p.g) * a / 255))
            out.append(UInt8(Int(p.r) * a / 255))
            out.append(p.a)
        }
        return out
    }

    static func pngData(_ rgba: [PNG.RGBA<UInt8>], side: Int) throws -> Data {
        let image = PNG.Image(
            packing: rgba, size: (side, side), layout: .init(format: .rgba8(palette: [], fill: nil)))
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("iconcomposer-\(UUID().uuidString).png").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try image.compress(path: path, level: 9)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    static func appearanceNameTag(_ appearance: Appearance?) -> String {
        switch appearance {
        case .dark: return "UIAppearanceDark"
        case .tinted: return "ISAppearanceTintable"
        default: return "UIAppearanceAny"
        }
    }

    /// The RenditionName suffix in Apple's shape: UUID, process id, 64-bit
    /// counter. actool fills it with a fresh UUID, its pid and a clock value,
    /// so its own cars differ per compile (IceCubes oracle runs: pids 53704
    /// and 53930). We derive all three from the content instead, so the same
    /// inputs give a byte-identical car. The UUID bytes keep Apple's RFC-4122
    /// v4 shape (version nibble 4, variant 10xx): 98ff033's raw hash nibbles
    /// and per-rendition pid are the only untested deltas against the VALID
    /// 9f509fe car, so both now match actool's observable shape. The pid is
    /// one value per compile in actool (it is a process id), so it is a
    /// constant here.
    static func renditionUUIDTag(name: String, appearance: Appearance?, pixels: [UInt8]) -> String {
        func fnv1a(_ seed: UInt64) -> UInt64 {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325 ^ seed
            for byte in name.utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
            for byte in appearanceNameTag(appearance).utf8 { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
            for byte in pixels { h = (h ^ UInt64(byte)) &* 0x100_0000_01B3 }
            return h
        }
        let a = fnv1a(1), b = fnv1a(2), c = fnv1a(3)
        var bytes = [UInt8]()
        for value in [a, b] {
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02X", $0) }.joined()
        let chars = Array(hex)
        let uuid = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
        return "\(uuid)-\(53_704)-\(String(format: "%016llX", c >> 8))"
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
