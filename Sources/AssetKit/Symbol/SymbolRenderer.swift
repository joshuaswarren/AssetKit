import Foundation

/// Builds the renditions actool emits for a catalog's `.symbolset`s (Apple
/// symbol oracle: Xcode 27.0 on NetNewsWire's markAllAsRead and
/// markAboveAsRead):
///
/// * one vector-glyph rendition (part 59) per set and -S/-M/-L template
///   layer, keyed weight Regular (4) and the layer's size class;
/// * nine cached-bitmap renditions (part 181) per set, keyed Glyph Cached
///   Index 0..2 (point sizes 15/17/20) × scale 1/2/3, all sized from the
///   Medium layer's bounding box (`ceil(bbox × size/100 × scale)`),
///   metadata-only with the atlas-link TVL;
/// * ONE packed ZZZZPackedAsset atlas (element 9 / part 181) per scale
///   holding every set's cached sprites, as actool does (NNW oracle: one
///   atlas per scale for the whole catalog);
/// * every symbol rendition keyed at deployment-target token 5 (iOS 13).
enum SymbolRenderer {
    /// Reference point size the vector metrics are expressed at.
    static let referencePointSize = 17.0
    /// Template em size ("Typeset at 100 points").
    static let templateSize = 100.0
    /// Point sizes of the Medium size class, by Glyph Cached Index.
    static let cachedSizes: [Double] = [15, 17, 20]
    /// Glyph-weight token: Regular (the only weight symbol templates
    /// classify without explicit weight layer names).
    static let regularWeightToken: UInt16 = 4
    /// Symbol renditions key at the OS that introduced symbol sets.
    static let deploymentTargetToken: UInt16 = 5
    /// Side margins reported in TVL 1018, observed as a template constant
    /// pair on both NetNewsWire symbols (identical across S/M/L vectors),
    /// at the 17 pt reference size. Pinned to Apple's exact Float32 bits
    /// (0x3FBE2FFA, 0x3F94C000).
    static let leftMarginPoints = Float(bitPattern: 0x3FBE2FFA)
    static let rightMarginPoints = Float(bitPattern: 0x3F94C000)
    /// Atlas layout for the cached bitmaps of one scale: one shelf, widest
    /// first, 2 px padding — Apple's observed single-symbol symbol atlas
    /// shape (60x34, 112x64, 164x94 in the full-NNW oracle), whose
    /// placements (2,2)/(24,2)/(43,2)... it reproduces exactly. Ties break
    /// by input index so the layout is deterministic.
    static func atlasLayout(dims: [(width: UInt32, height: UInt32)])
        -> (placements: [(x: UInt32, y: UInt32)], atlasWidth: UInt32, atlasHeight: UInt32)
    {
        let pad: UInt32 = 2
        let order = dims.indices.sorted {
            (dims[$0].width, $0) > (dims[$1].width, $1)
        }
        var x = pad
        var placements = [(x: UInt32, y: UInt32)](
            repeating: (0, 0), count: dims.count)
        var maxHeight: UInt32 = 0
        for i in order {
            placements[i] = (x, pad)
            x += dims[i].width + pad
            maxHeight = max(maxHeight, dims[i].height)
        }
        return (placements, x, maxHeight + 2 * pad)
    }

    /// One `.symbolset` prepared for atlas assembly: the set's vector
    /// renditions plus, per scale factor (1, 2, 3) and cached point size,
    /// the rasterized gray-alpha sprite.
    struct PreparedSymbolSet: Sendable {
        let vectors: [Rendition]
        let name: String
        let filename: String
        let identifier: UInt16
        /// Sprites per scale-factor index, each per cached point size.
        var sprites: [[(width: UInt32, height: UInt32, plane: [UInt8])]]
    }

    /// Parses one `.symbolset`, builds its vector renditions and rasterizes
    /// its cached sprites. Atlas placement happens catalog-wide in
    /// `renditions(for:)`.
    static func prepare(for set: LoadedSymbolSet, svgRasterizer: any SVGRasterizer) throws -> PreparedSymbolSet {
        let svgData: Data
        do {
            svgData = try Data(contentsOf: set.svgURL)
        } catch {
            throw XCAssetCompilerError.missingReferencedFile(asset: set.name, filename: set.filename)
        }
        let template = try SymbolTemplate.parse(svgData, asset: set.name, filename: set.filename)
        let identifier = UInt16(FacetKeys.nameHash(set.name) & 0xFFFF)
        let scale = Double(referencePointSize) / templateSize

        var vectors: [Rendition] = []

        // Vector glyph per template layer. The Medium vector carries the
        // available-sizes list the cache entries key into.
        for layer in template.layers {
            let layerBounds = SymbolTemplate.bounds(of: layer.children)
            // Baseline distance below the drawing bottom, in the layer's
            // local space: the guides sit relative to the Symbols origin
            // and the rewrite drops the layer's own translate, so the
            // baseline's local height is originOffset minus the dropped
            // translate y.
            guard let originOffset = template.baselineOffset[layer.sizeClass],
                  let capHeight = template.capHeight[layer.sizeClass] else {
                throw XCAssetCompilerError.unsupportedAssetType(
                    "\(set.name): no Guides lines for size class \(layer.sizeClass)")
            }
            let baselineUnits = layerBounds.maxY - (originOffset - layer.translation.dy)
            // Apple computes the metrics in Float32 arithmetic (the
            // baseline bit pattern matches Float(39.6094) * Float(0.17)
            // exactly, not the Double product rounded).
            let baseline = Float(baselineUnits) * Float(scale)
            let capline = Float(capHeight) * Float(scale)
            let vector = SymbolVectorBody(
                glyphWeight: regularWeightToken,
                glyphSize: UInt16(layer.sizeClass),
                identifier: identifier,
                baseline: baseline,
                capline: capline,
                leftMargin: leftMarginPoints,
                rightMargin: rightMarginPoints,
                availableSizes: layer.sizeClass == 2
                    ? [(0, 15), (1, 17), (2, 20)].map { (index: UInt32($0.0), pointSize: UInt32($0.1)) }
                    : nil,
                svg: SymbolTemplate.rewrittenSVG(layer: layer, bounds: layerBounds, scale: scale),
                renditionName: set.filename
            )
            vectors.append(Rendition(
                name: set.name,
                idiom: .universal,
                scale: .x1,
                deploymentTarget: deploymentTargetToken,
                body: .symbolVector(vector)
            ))
        }

        // Cached bitmaps, sized from the Medium layer (or the only one).
        let cacheLayer = template.layers.first { $0.sizeClass == 2 } ?? template.layers[0]
        let cacheBounds = SymbolTemplate.bounds(of: cacheLayer.children)
        let cacheSVG = SymbolTemplate.rewrittenSVG(layer: cacheLayer, bounds: cacheBounds, scale: scale)
        var sprites: [[(width: UInt32, height: UInt32, plane: [UInt8])]] = []
        for factor in [1, 2, 3] {
            var perFactor: [(width: UInt32, height: UInt32, plane: [UInt8])] = []
            for pointSize in cachedSizes {
                let width = UInt32((cacheBounds.width * pointSize / templateSize * Double(factor)).rounded(.up))
                let height = UInt32((cacheBounds.height * pointSize / templateSize * Double(factor)).rounded(.up))
                let png = try rasterizeCached(
                    cacheSVG, svgRasterizer: svgRasterizer, asset: set.name,
                    filename: set.filename, width: width, height: height
                )
                let d = try PNGSource.decodeBGRA(png)
                var plane = [UInt8](repeating: 0, count: Int(width * height) * 2)
                for row in 0..<Int(height) {
                    for col in 0..<Int(width) {
                        let src = (row * Int(width) + col) * 4
                        // Template glyphs are black: the gray plane is 0,
                        // alpha carries the coverage.
                        plane[(row * Int(width) + col) * 2 + 1] = d.bgra8[src + 3]
                    }
                }
                perFactor.append((width, height, plane))
            }
            sprites.append(perFactor)
        }
        return PreparedSymbolSet(
            vectors: vectors, name: set.name, filename: set.filename,
            identifier: identifier, sprites: sprites)
    }

    /// Renditions for every `.symbolset` in the catalog. Apple packs the
    /// cached bitmaps into ONE ZZZZPackedAsset atlas per scale for the whole
    /// catalog (NNW oracle: one atlas per scale); CoreUI resolves the packed
    /// key (element 9, part 181, identifier 0) to the first rendition in the
    /// car, so per-set atlases under the same key left every sprite of the
    /// other sets out of bounds whenever a narrower atlas came first — the
    /// sorted catalog walk of 98ff033 flipped IceCubes into exactly that
    /// order and App Store processing never finished (upload f3a1784f; the
    /// same car with the pair order swapped went VALID).
    static func renditions(for sets: [PreparedSymbolSet]) -> [Rendition] {
        var out: [Rendition] = []
        for prepared in sets {
            out.append(contentsOf: prepared.vectors)
        }
        let scaleNames = [1: Scale.x1, 2: Scale.x2, 3: Scale.x3]
        for (factorIndex, factor) in [1, 2, 3].enumerated() {
            // One shelf across every set's sprites at this scale.
            let dims = sets.enumerated().flatMap { setIndex, set in
                set.sprites[factorIndex].indices.map { index in
                    (setIndex: setIndex, cachedIndex: index,
                     width: set.sprites[factorIndex][index].width,
                     height: set.sprites[factorIndex][index].height)
                }
            }
            guard !dims.isEmpty else { continue }
            let layout = atlasLayout(dims: dims.map { (width: $0.width, height: $0.height) })
            var atlas = [UInt8](repeating: 0, count: Int(layout.atlasWidth * layout.atlasHeight * 2))
            for (slot, sprite) in dims.enumerated() {
                let place = layout.placements[slot]
                let plane = sets[sprite.setIndex].sprites[factorIndex][sprite.cachedIndex].plane
                for row in 0..<Int(sprite.height) {
                    for col in 0..<Int(sprite.width) {
                        let src = (row * Int(sprite.width) + col) * 2
                        let dst = ((Int(place.y) + row) * Int(layout.atlasWidth)
                            + Int(place.x) + col) * 2
                        atlas[dst] = plane[src]
                        atlas[dst + 1] = plane[src + 1]
                    }
                }
            }
            for (index, sprite) in dims.enumerated() {
                let set = sets[sprite.setIndex]
                let cached = SymbolCachedBody(
                    glyphWeight: regularWeightToken,
                    glyphSize: 2,
                    cachedIndex: UInt16(sprite.cachedIndex),
                    identifier: set.identifier,
                    width: sprite.width,
                    height: sprite.height,
                    atlasX: layout.placements[index].x,
                    atlasY: layout.placements[index].y,
                    renditionName: set.filename
                )
                out.append(Rendition(
                    name: set.name,
                    idiom: .universal,
                    scale: scaleNames[factor]!,
                    deploymentTarget: deploymentTargetToken,
                    body: .symbolCached(cached)
                ))
            }
            let packed = SymbolPackedBody(
                width: layout.atlasWidth,
                height: layout.atlasHeight,
                pixelsGA: atlas,
                scale: UInt16(factor),
                renditionName: "ZZZZPackedAsset-\(factor).0.1-gamut0"
            )
            out.append(Rendition(
                name: packed.renditionName,
                idiom: .universal,
                scale: scaleNames[factor]!,
                deploymentTarget: deploymentTargetToken,
                body: .symbolPacked(packed)
            ))
        }
        return out
    }

    /// Rasterises the cached-bitmap drawing at one exact pixel size,
    /// mapping rasteriser failures to the catalog error surface.
    static func rasterizeCached(
        _ svg: Data,
        svgRasterizer: any SVGRasterizer,
        asset: String,
        filename: String,
        width: UInt32,
        height: UInt32
    ) throws -> Data {
        do {
            return try svgRasterizer.rasterize(svgData: svg, pixelWidth: width, pixelHeight: height)
        } catch {
            throw XCAssetCompilerError.svgRasterizationFailed(
                asset: asset, filename: filename, underlying: String(describing: error))
        }
    }
}
