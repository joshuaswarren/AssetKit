import Foundation
import PNG

/// Compiles an Icon Composer `.icon` bundle (icon.json + Assets/ layer
/// images) into the layered rendition set Apple actool 27.0 emits: named
/// colors, named gradients, one image rendition per layer bitmap, one group
/// rendition per (group, appearance), one icon image stack per appearance,
/// the per-appearance pre-rendered 1024 px icon bitmaps, and the MultiSized
/// containers (IceCubesApp `AppIcon.icon` oracle).
///
/// The pre-rendered bitmaps reproduce Apple's composition (background fill,
/// layers at scale/translation, per-appearance fills, blend modes, and the
/// tinted appearance as grayscale content over black). Apple's Liquid Glass
/// lighting is not reproduced; the pixel delta is measured by the
/// verification harness and reported by the caller.
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
        var fills: [[String: Any]]   // fill-specializations, verbatim
        var blends: [[String: Any]]  // blend-mode-specializations, verbatim
        var glass: Bool
    }

    struct Group {
        var layers: [Layer]
        var blurStrength: Double
        var shadowStyle: UInt32
        var shadowOpacity: Double
        var translucency: [[String: Any]] // translucency-specializations
    }

    struct IconModel {
        var fills: [[String: Any]]       // top-level fill-specializations
        var groups: [Group]
    }

    enum IconComposerError: Error, CustomStringConvertible {
        case corruptJSON

        var description: String { "icon.json is not a JSON object" }
    }

    static func parseModel(_ json: [String: Any]) throws -> IconModel {
        var groups: [Group] = []
        for group in json["groups"] as? [[String: Any]] ?? [] {
            var layers: [Layer] = []
            for layer in group["layers"] as? [[String: Any]] ?? [] {
                guard layer["hidden"] as? Bool != true else { continue }
                let position = layer["position"] as? [String: Any] ?? [:]
                let translation = position["translation-in-points"] as? [Double] ?? [0, 0]
                layers.append(Layer(
                    imageName: layer["image-name"] as? String ?? "",
                    scale: position["scale"] as? Double ?? 1,
                    translation: (translation.first ?? 0, translation.count > 1 ? translation[1] : 0),
                    fills: layer["fill-specializations"] as? [[String: Any]] ?? [],
                    blends: layer["blend-mode-specializations"] as? [[String: Any]] ?? [],
                    glass: layer["glass"] as? Bool ?? false))
            }
            let shadow = group["shadow"] as? [String: Any]
            let blur = (group["blur-material"] as? NSNumber)?.doubleValue
                ?? (group["blur-material-specializations"] as? [[String: Any]] ?? [])
                    .first { $0["appearance"] == nil }.flatMap { ($0["value"] as? NSNumber)?.doubleValue }
            groups.append(Group(
                layers: layers,
                blurStrength: blur ?? 0,
                shadowStyle: shadow == nil ? 0 : 2,  // kind layer-color -> style 2 (oracle)
                shadowOpacity: shadow?["opacity"] as? Double ?? 0,
                translucency: group["translucency-specializations"] as? [[String: Any]] ?? []))
        }
        return IconModel(fills: json["fill-specializations"] as? [[String: Any]] ?? [], groups: groups)
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

    /// Resolves a fill value for one appearance: the entry matching the
    /// appearance first, else the appearance-less entry. "automatic"
    /// resolves to nothing for light and dark, and to the light value for
    /// tinted (oracle: the tinted group rendition of IceCubes' Group 2
    /// carries the light solid Color-8).
    static func resolveFill(_ specializations: [[String: Any]], appearance: Appearance?) -> Fill? {
        guard let value = specializedValue(specializations, appearance: appearance) else { return nil }
        if let name = value as? String {
            if name == "automatic" {
                guard appearance == .tinted else { return nil }
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

    /// Resolves the translucency value for one appearance: enabled ? value : 0.
    static func resolveTranslucency(_ specializations: [[String: Any]], appearance: Appearance?) -> Float {
        guard let dict = specializedValue(specializations, appearance: appearance) as? [String: Any],
              let value = dict["value"] as? Double else { return 0 }
        return (dict["enabled"] as? Bool ?? true) ? Float(value) : 0
    }

    // MARK: - Rendering

    /// Straight-alpha pixel with source-over compositing and the blend modes
    /// Icon Composer layers use.
    struct Pixel {
        var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0, a: UInt8 = 0

        mutating func blend(source s: (UInt8, UInt8, UInt8), sourceAlpha sa: UInt8, lighten: Bool) {
            let src: (UInt8, UInt8, UInt8) = lighten
                ? (max(r, s.0), max(g, s.1), max(b, s.2))
                : s
            let inv = 255 - Int(sa)
            func over(_ d: UInt8, _ v: UInt8) -> UInt8 {
                UInt8((Int(v) * Int(sa) + Int(d) * inv + 127) / 255)
            }
            r = over(r, src.0); g = over(g, src.1); b = over(b, src.2)
            a = UInt8(min(255, Int(sa) + Int(a) * inv / 255))
        }
    }

    static let canvasSide = 1024

    struct LoadedImage {
        var width: Int
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
        return LoadedImage(width: image.size.x, pixels: rgba.map { Pixel(r: $0.r, g: $0.g, b: $0.b, a: $0.a) })
    }

    /// Paints a vertical gradient (top -> bottom) over the whole canvas.
    static func paintBackground(_ fill: Fill, into canvas: inout [Pixel]) {
        for y in 0..<canvasSide {
            let color = sample(fill, t: Double(y) / Double(canvasSide - 1))
            for x in 0..<canvasSide {
                paint(color: color, lighten: false, into: &canvas[y * canvasSide + x])
            }
        }
    }

    static func sample(_ fill: Fill, t: Double) -> IconColor {
        switch fill {
        case .solid(let c):
            return c
        case .gradient(let top, let bottom):
            return IconColor(
                colorSpaceID: top.colorSpaceID,
                components: zip(top.components, bottom.components).map { $0 + ($1 - $0) * t })
        }
    }

    static func paint(color: IconColor, alpha: Double = 1, lighten: Bool, into pixel: inout Pixel) {
        var c = color.components
        if c.count < 4 { c = [c[0], c[0], c[0], c.count > 1 ? c[1] : 1] }
        // Fills in gray/p3 spaces paint through the sRGB canvas; Apple's
        // pre-renders are sRGB bitmaps, so quantize components to 8 bits.
        func q(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        let sa = UInt8((min(max(c[3] * alpha, 0), 1) * 255).rounded())
        pixel.blend(source: (q(c[0]), q(c[1]), q(c[2])), sourceAlpha: sa, lighten: lighten)
    }

    /// Liquid Glass wash, measured from actool 27.0 controlled variants
    /// (glass-lab/wash-profiles.json): inside the layer's glass region (the
    /// content box inset by 10% per side) the baked pre-render mixes each
    /// pixel toward white with a weight W(s) — a top-rim glow, a body
    /// gradient rising toward the bottom, and a bottom-edge glow. W depends
    /// on the group's translucency and the appearance. Specular and
    /// blur-material do not affect the pre-render (verified: 0.000 mean).
    static func washValue(_ tables: [[Double]], _ translucency: Float, _ s: Double) -> Double {
        guard s >= 0, s <= 1 else { return 0 }
        let tr = Double(max(0, min(1, translucency)))
        func at(_ table: [Double]) -> Double {
            let x = s * 110
            let i = min(109, Int(x))
            let f = x - Double(i)
            return table[i] + (table[i + 1] - table[i]) * f
        }
        if tr >= 1 { return at(tables[3]) }
        if tr > 0.25 {
            // piecewise-linear between the measured 0.25/0.5/0.75/1.0 tables
            let lower = Int((tr - 0.25) / 0.25) // 0, 1, 2
            let f = (tr - (0.25 + Double(lower) * 0.25)) / 0.25
            let a = at(tables[lower]), b = at(tables[lower + 1])
            return a + (b - a) * f
        }
        // glass-only material curve blended toward the 0.25 table
        let f = tr / 0.25
        let a = at(tables[4]), b = at(tables[0])
        return a + (b - a) * f
    }

    static func washTables(_ appearance: Appearance?) -> [[Double]] {
        appearance == .dark ? [GlassWash.dark[0], GlassWash.dark[1], GlassWash.dark[2], GlassWash.dark[3], GlassWash.g0Dark]
            : (appearance == .tinted ? [GlassWash.tinted[0], GlassWash.tinted[1], GlassWash.tinted[2], GlassWash.tinted[3], GlassWash.g0Tinted]
            : [GlassWash.light[0], GlassWash.light[1], GlassWash.light[2], GlassWash.light[3], GlassWash.g0Light])
    }

    /// Draws one layer image at its scale/translation with an optional fill
    /// masked by the image alpha, blended per the layer's blend mode.
    /// `wash` (level-indexed tables + group translucency) applies the Liquid
    /// Glass white-mix inside the glass region (content box inset 10%/side).
    static func drawLayer(
        _ image: LoadedImage, fill: Fill?, scale: Double,
        translation: (Double, Double), lighten: Bool,
        wash: (tables: [[Double]], translucency: Float)? = nil,
        weights: UnsafeMutablePointer<Float>? = nil, into canvas: inout [Pixel]
    ) {
        let side = max(1, Int((Double(canvasSide) * scale).rounded()))
        let x0 = (canvasSide - side) / 2 + Int(translation.0.rounded())
        let y0 = (canvasSide - side) / 2 + Int(translation.1.rounded())
        let regionTop = Double(y0) + Double(side) / 10
        let regionHeight = Double(side) * 0.8
        for y in 0..<side {
            let canvasY = y0 + y
            guard canvasY >= 0, canvasY < canvasSide else { continue }
            let sy = (Double(y) + 0.5) * Double(image.width) / Double(side) - 0.5
            let sy0 = max(0, min(image.width - 1, Int(sy.rounded(.down))))
            let sy1 = max(0, min(image.width - 1, sy0 + 1))
            let fy = max(0, min(1, sy - Double(sy0)))
            let s = (Double(canvasY) + 0.5 - regionTop) / regionHeight
            let w = wash.map { washValue($0.tables, $0.translucency, s) } ?? 0
            for x in 0..<side {
                let canvasX = x0 + x
                guard canvasX >= 0, canvasX < canvasSide else { continue }
                let sx = (Double(x) + 0.5) * Double(image.width) / Double(side) - 0.5
                let sx0 = max(0, min(image.width - 1, Int(sx.rounded(.down))))
                let sx1 = max(0, min(image.width - 1, sx0 + 1))
                let fx = max(0, min(1, sx - Double(sx0)))
                let p = bilinear(image, sx0, sy0, sx1, sy1, fx, fy)
                if p.a == 0 { continue }
                var out = canvas[canvasY * canvasSide + canvasX]
                if let fill {
                    let t = side > 1 ? Double(y) / Double(side - 1) : 0
                    paint(color: sample(fill, t: t), alpha: Double(p.a) / 255, lighten: lighten, into: &out)
                } else {
                    out.blend(source: (p.r, p.g, p.b), sourceAlpha: p.a, lighten: lighten)
                }
                if w != 0 {
                    let cov = Double(p.a) / 255
                    if let weights {
                        let idx = canvasY * canvasSide + canvasX
                        weights[idx] = max(weights[idx], Float(w * cov))
                    } else {
                        func mixWash(_ v: UInt8) -> UInt8 {
                            UInt8((Double(v) + w * (255 - Double(v)) * cov).rounded())
                        }
                        out = Pixel(r: mixWash(out.r), g: mixWash(out.g), b: mixWash(out.b), a: out.a)
                    }
                }
                canvas[canvasY * canvasSide + canvasX] = out
            }
        }
    }

    static func bilinear(
        _ image: LoadedImage, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int,
        _ fx: Double, _ fy: Double
    ) -> Pixel {
        func lerp(_ a: Pixel, _ b: Pixel, _ t: Double) -> Pixel {
            func mix(_ u: UInt8, _ v: UInt8) -> UInt8 {
                UInt8((Double(u) + (Double(v) - Double(u)) * t).rounded())
            }
            return Pixel(r: mix(a.r, b.r), g: mix(a.g, b.g), b: mix(a.b, b.b), a: mix(a.a, b.a))
        }
        let top = lerp(image.pixels[y0 * image.width + x0], image.pixels[y0 * image.width + x1], fx)
        let bottom = lerp(image.pixels[y1 * image.width + x0], image.pixels[y1 * image.width + x1], fx)
        return lerp(top, bottom, fy)
    }

    /// Renders the 1024 px pre-render for one appearance as opaque BGRA.
    /// Light and dark paint the background fill then every group in json
    /// order; the tinted appearance paints content only (no background) and
    /// reduces it to grayscale luminance over black, matching Apple's
    /// tinted rendition.
    static func render(model: IconModel, images: [String: LoadedImage], appearance: Appearance?) -> [UInt8] {
        var canvas = [Pixel](repeating: Pixel(), count: canvasSide * canvasSide)
        let background = resolveFill(model.fills, appearance: appearance)
        let tinted = appearance == .tinted
        if let background, !tinted {
            paintBackground(background, into: &canvas)
        }
        // Tinted applies the glass wash after the grayscale reduction (the
        // measured tables are effects on the final tinted bitmap).
        var washWeights: [Float] = []
        if tinted { washWeights = [Float](repeating: 0, count: canvasSide * canvasSide) }
        let tables = washTables(appearance)
        for group in model.groups {
            let tr = resolveTranslucency(group.translucency, appearance: appearance)
            for layer in group.layers {
                guard let image = images[layer.imageName] else { continue }
                let blendValue = specializedValue(layer.blends, appearance: appearance) as? String
                let wash = layer.glass
                    ? (tables: tables, translucency: tr) as (tables: [[Double]], translucency: Float)? : nil
                drawLayer(
                    image, fill: resolveFill(layer.fills, appearance: appearance),
                    scale: layer.scale, translation: layer.translation,
                    lighten: blendValue == "lighten", wash: wash,
                    weights: tinted ? UnsafeMutablePointer(mutating: washWeights) : nil,
                    into: &canvas)
            }
        }
        var out = [UInt8]()
        out.reserveCapacity(canvas.count * 4)
        for (idx, p) in canvas.enumerated() {
            if tinted {
                let luma = (0.299 * Double(p.r) + 0.587 * Double(p.g) + 0.114 * Double(p.b))
                    * Double(p.a) / 255
                let w = Double(washWeights[idx])
                let g = UInt8((luma + w * (255 - luma)).rounded())
                out.append(contentsOf: [g, g, g, 255])
            } else {
                out.append(contentsOf: [p.b, p.g, p.r, 255])
            }
        }
        return out
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
        for group in model.groups {
            for layer in group.layers {
                guard images[layer.imageName] == nil else { continue }
                let url = assets.appendingPathComponent(layer.imageName)
                if layer.imageName.lowercased().hasSuffix(".svg") {
                    let png = try RsvgConvertRasterizer()
                        .rasterize(svgData: Data(contentsOf: url),
                                   pixelWidth: UInt32(canvasSide), pixelHeight: UInt32(canvasSide))
                    images[layer.imageName] = try decodePNG(png)
                } else {
                    images[layer.imageName] = try decodePNG(Data(contentsOf: url))
                }
            }
        }

        func facetStem(_ imageName: String) -> String {
            (imageName as NSString).deletingPathExtension
        }

        // Color and gradient naming, in Apple's allocation order: the
        // always-present extended-gray white (Color-1; the shadow/specular
        // slot), the preset backgrounds (their colors follow), then layer
        // fills in traversal order. Custom gradients number from 3 — after
        // the two presets.
        var colors: [IconColor] = [IconColor(colorSpaceID: 6, components: [1, 1])]
        var colorNames: [IconColor: String] = [:]
        func colorSlot(_ c: IconColor) -> String {
            if let known = colorNames[c] { return known }
            colors.append(c)
            let name = "\(input.name)_Assets/Color-\(colors.count)"
            colorNames[c] = name
            return name
        }

        // Presets are always materialized (the oracle emits system-light /
        // system-dark and their colors even for icons that do not use them).
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
        _ = presetSlot("system-light")
        _ = presetSlot("system-dark")

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
            let image = images[imageName]!
            imageRenditions.append(Rendition(
                name: facet, idiom: .universal, scale: .x1, appearance: nil,
                iconComposerSource: true,
                body: .bitmap(BitmapBody(
                    width: UInt32(image.width), height: UInt32(image.width),
                    pixelsBGRA: premultipliedBGRA(image), colorSpaceID: 1, kind: .image,
                    renditionName: "image.png"))))
        }

        // Groups, one rendition per (group, appearance). Group facet names:
        // "AppIcon/Group", then "AppIcon/Group 2", "AppIcon/Group 3", ...
        var groupRenditions: [Rendition] = []
        var groupFacets: [(facet: String, identifier: UInt16, group: Group)] = []
        for (index, group) in model.groups.enumerated() {
            let facet = index == 0 ? "\(input.name)/Group" : "\(input.name)/Group \(index + 1)"
            groupFacets.append((facet, UInt16(FacetKeys.nameHash(facet) & 0xFFFF), group))
            for appearance in appearances {
                let layers = group.layers.map { layer -> IconGroupLayer in
                    let size = max(1, Int((Double(canvasSide) * layer.scale).rounded()))
                    let half = Int32((-(Double(size - canvasSide)) / 2).rounded())
                    return IconGroupLayer(
                        imageFacetName: "",
                        imageIdentifier: imageIdentifiers[facetStem(layer.imageName)] ?? 0,
                        positionX: half + Int32(layer.translation.0.rounded()),
                        positionY: half + Int32(layer.translation.1.rounded()),
                        width: UInt32(size), height: UInt32(size),
                        blendMode: blendWord(layer, appearance),
                        opacity: 1,
                        fillName: fillName(layer, appearance))
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
        for appearance in appearances {
            let backgroundName = presetSlot(appearance == .dark ? "system-dark" : "system-light")
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
