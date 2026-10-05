import Foundation

/// Builds the renditions actool emits for one `.symbolset` (Apple symbol
/// oracle: Xcode 27.0 on NetNewsWire's markAllAsRead and markAboveAsRead):
///
/// * one vector-glyph rendition (part 59) per -S/-M/-L template layer,
///   keyed weight Regular (4) and the layer's size class;
/// * nine cached-bitmap renditions (part 181) keyed Glyph Cached Index
///   0..2 (point sizes 15/17/20) × scale 1/2/3, all sized from the Medium
///   layer's bounding box (`ceil(bbox × size/100 × scale)`), metadata-only
///   with the atlas-link TVL;
/// * every symbol rendition keyed at deployment-target token 5 (iOS 13).
///
/// Apple additionally packs the nine cache bitmaps into per-scale
/// ZZZZPackedAsset atlases; the packing layout is CoreUI-internal (two
/// NetNewsWire templates give no single deterministic rule), so the atlas
/// renditions are left out. CoreUI falls back to the vector glyph when a
/// cache lookup misses, which is the path that matters at runtime.
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
    /// Atlas layout for the three cached bitmaps of one scale: one shelf,
    /// widest first, 2 px padding — Apple's observed single-symbol symbol
    /// atlas shape (60x34, 112x64, 164x94 in the full-NNW oracle), whose
    /// placements (2,2)/(24,2)/(43,2)... it reproduces exactly.
    static func atlasLayout(dims: [(width: UInt32, height: UInt32)])
        -> (placements: [(x: UInt32, y: UInt32)], atlasWidth: UInt32, atlasHeight: UInt32)
    {
        let pad: UInt32 = 2
        let order = dims.indices.sorted { dims[$0].width > dims[$1].width }
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

    static func renditions(for set: LoadedSymbolSet, svgRasterizer: any SVGRasterizer) throws -> [Rendition] {
        let svgData: Data
        do {
            svgData = try Data(contentsOf: set.svgURL)
        } catch {
            throw XCAssetCompilerError.missingReferencedFile(asset: set.name, filename: set.filename)
        }
        let template = try SymbolTemplate.parse(svgData, asset: set.name, filename: set.filename)
        let identifier = UInt16(FacetKeys.nameHash(set.name) & 0xFFFF)
        let scale = Double(referencePointSize) / templateSize

        var out: [Rendition] = []

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
            out.append(Rendition(
                name: set.name,
                idiom: .universal,
                scale: .x1,
                deploymentTarget: deploymentTargetToken,
                body: .symbolVector(vector)
            ))
        }

        // Cached bitmaps, sized from the Medium layer (or the only one),
        // plus one packed atlas per scale holding their pixels.
        let cacheLayer = template.layers.first { $0.sizeClass == 2 } ?? template.layers[0]
        let cacheBounds = SymbolTemplate.bounds(of: cacheLayer.children)
        let cacheSVG = SymbolTemplate.rewrittenSVG(layer: cacheLayer, bounds: cacheBounds, scale: scale)
        for factor in [1, 2, 3] {
            var dims: [(width: UInt32, height: UInt32)] = []
            for pointSize in cachedSizes {
                let width = UInt32((cacheBounds.width * pointSize / templateSize * Double(factor)).rounded(.up))
                let height = UInt32((cacheBounds.height * pointSize / templateSize * Double(factor)).rounded(.up))
                dims.append((width, height))
            }
            let layout = atlasLayout(dims: dims)
            var atlas = [UInt8](repeating: 0, count: Int(layout.atlasWidth * layout.atlasHeight * 2))
            for (cachedIndex, pointSize) in cachedSizes.enumerated() {
                let width = dims[cachedIndex].width
                let height = dims[cachedIndex].height
                let place = layout.placements[cachedIndex]
                let png = try rasterizeCached(
                    cacheSVG, svgRasterizer: svgRasterizer, asset: set.name,
                    filename: set.filename, width: width, height: height
                )
                let (rw, rh, rgba) = try PNGSource.decodeBGRA(png)
                for row in 0..<Int(height) {
                    for col in 0..<Int(width) {
                        let src = (row * Int(width) + col) * 4
                        // Template glyphs are black: the gray plane is 0,
                        // alpha carries the coverage.
                        let alpha = rgba[src + 3]
                        let dst = ((Int(place.y) + row) * Int(layout.atlasWidth)
                            + Int(place.x) + col) * 2
                        atlas[dst] = 0
                        atlas[dst + 1] = alpha
                    }
                }
                let cached = SymbolCachedBody(
                    glyphWeight: regularWeightToken,
                    glyphSize: 2,
                    cachedIndex: UInt16(cachedIndex),
                    identifier: identifier,
                    width: width,
                    height: height,
                    atlasX: place.x,
                    atlasY: place.y,
                    renditionName: set.filename
                )
                out.append(Rendition(
                    name: set.name,
                    idiom: .universal,
                    scale: [1: .x1, 2: .x2, 3: .x3][factor]!,
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
                scale: [1: .x1, 2: .x2, 3: .x3][factor]!,
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
