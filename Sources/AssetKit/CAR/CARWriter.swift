import Foundation

/// Orchestrates the BOM container and CAR-specific blocks/trees.
///
/// Physical layout matches actool 27.0's output byte-order (block allocation
/// order, vars order, tree shapes) because App Store ingest validates the
/// container, not just the parsed content:
///
/// 1. CARHEADER
/// 2. RENDITIONS tree header + leaf
/// 3. FACETKEYS tree header + leaf
/// 4. APPEARANCEKEYS tree header + leaf
/// 5. APPEARANCEKEYS entry data (key block, value block per entry)
/// 6. FACETKEYS entry data
/// 7. KEYFORMAT
/// 8. RENDITIONS entry data, in rendition list order
/// 9. EXTENDED_METADATA
/// 10. BITMAPKEYS tree header + leaf (1024-padded, inline u32 keys) + value
///     blocks
/// 11. Block index padded to 256 entries.
///
/// Tree leaves embed the sorted key bytes after a per-entry key-offset array
/// (see `BOMTree`); the same key/value bytes live in their own blocks.
struct CARWriter: Sendable {
    var deploymentTarget: String
    var renditions: [Rendition]

    func write() throws -> Data {
        var bom = BOMWriter()

        let layout = CARLayout(renditions: renditions)

        // KEYFORMAT is catalog-wide and actool only lists the attributes in
        // use: the base eight, plus dimension2 when some rendition carries
        // an Icon Index (app icons), plus appearance / displayGamut when
        // dark or tinted icon variants widen the tuple.
        let keyFormat = KeyFormat.format(for: renditions)

        // ---- Tree contents ----
        let renditionData: [(key: Data, value: Data)] = renditions.map { rendition in
            (RenditionKey(rendition: rendition).encode(format: keyFormat), csiData(for: rendition))
        }
        let facetData: [(key: Data, value: Data)] = layout.assets
            .map { asset in (Data(asset.name.utf8), FacetKeys.value(for: asset.name, kind: asset.kind)) }
            .sorted { BOMTree.byteCompare($0.key, $1.key) < 0 }
        let appearanceData: [(key: Data, value: Data)] = AppearanceKeys.entries(used: layout.usedAppearances)
            .map { (key: $0.key, value: $0.value) }
            .sorted { BOMTree.byteCompare($0.key, $1.key) < 0 }
        let bitmapData: [(key: Data, value: Data)] = bitmapEntries(layout: layout)
            .sorted { BOMTree.byteCompare($0.key, $1.key) < 0 }

        // ---- Deterministic block ids (1-based, actool order) ----
        var next: UInt32 = 1
        func take() -> UInt32 { defer { next += 1 }; return next }
        func takePair() -> (key: UInt32, value: UInt32) {
            defer { next += 2 }
            return (next, next + 1)
        }

        let carHeaderID = take()
        let renditionsTree = takePair() // (header, leaf)
        let facetTree = takePair()
        let appearanceTree = takePair()
        let appearanceDataIDs = (0..<appearanceData.count).map { _ in takePair() }
        let facetDataIDs = (0..<facetData.count).map { _ in takePair() }
        let keyFormatID = take()
        let renditionsDataIDs = (0..<renditionData.count).map { _ in takePair() }
        let extendedMetadataID = take()
        let bitmapTreeHeaderID = take()
        let bitmapLeafID = take()
        let bitmapValueIDs = (0..<bitmapData.count).map { _ in take() }

        // ---- Blocks ----
        bom.addBlock(CARHeaderBlock.data(renditionCount: UInt32(renditions.count)))

        bom.addBlock(BOMTree.header(
            leafBlockID: renditionsTree.value, blockSize: BOMTree.defaultBlockSize,
            pathCount: renditionData.count, isInternal: false,
            keyTrailerLength: renditionData.first?.key.count ?? 0))
        // Leaf entries are key-sorted; data blocks stay in list order.
        let renditionsWithIDs = zip(renditionData, renditionsDataIDs)
            .map { entry, ids in (entry: entry, ids: ids) }
            .sorted { BOMTree.byteCompare($0.entry.key, $1.entry.key) < 0 }
        bom.addBlock(BOMTree.leafExternal(
            sorted: renditionsWithIDs.map { $0.entry },
            keyBlockIDs: renditionsWithIDs.map { $0.ids.key },
            valueBlockIDs: renditionsWithIDs.map { $0.ids.value },
            blockSize: BOMTree.defaultBlockSize))
        bom.addBlock(BOMTree.header(
            leafBlockID: facetTree.value, blockSize: BOMTree.defaultBlockSize,
            pathCount: facetData.count, isInternal: false,
            // -1 (0xFFFFFFFF) marks "variable-length keys, external
            // blocks" — Apple's FACETKEYS/APPEARANCEKEYS headers carry -1,
            // RENDITIONS the exact fixed key length.
            keyTrailerLength: -1))
        bom.addBlock(BOMTree.leafExternal(
            sorted: facetData,
            keyBlockIDs: facetDataIDs.map { $0.key },
            valueBlockIDs: facetDataIDs.map { $0.value },
            blockSize: BOMTree.defaultBlockSize,
            // Variable-length string keys stay in external blocks only;
            // Apple's FACETKEYS leaf carries no inline key area.
            inlineKeys: false))

        bom.addBlock(BOMTree.header(
            leafBlockID: appearanceTree.value, blockSize: BOMTree.defaultBlockSize,
            pathCount: appearanceData.count, isInternal: false,
            keyTrailerLength: -1))
        bom.addBlock(BOMTree.leafExternal(
            sorted: appearanceData,
            keyBlockIDs: appearanceDataIDs.map { $0.key },
            valueBlockIDs: appearanceDataIDs.map { $0.value },
            blockSize: BOMTree.defaultBlockSize,
            // Same as FACETKEYS: external key blocks only.
            inlineKeys: false))

        for (entry, _) in zip(appearanceData, appearanceDataIDs) {
            bom.addBlock(entry.key)
            bom.addBlock(entry.value)
        }
        for (entry, _) in zip(facetData, facetDataIDs) {
            bom.addBlock(entry.key)
            bom.addBlock(entry.value)
        }
        bom.addBlock(KeyFormatBlock.data(attributes: keyFormat))
        // Rendition data blocks follow the list order (the ids were assigned
        // in list order; the leaf references them by id).
        for (entry, _) in zip(renditionData, renditionsDataIDs) {
            bom.addBlock(entry.key)
            bom.addBlock(entry.value)
        }
        bom.addBlock(ExtendedMetadata.data(deploymentTarget: deploymentTarget))

        if !bitmapData.isEmpty {
            bom.addBlock(BOMTree.header(
                leafBlockID: bitmapLeafID, blockSize: 1024,
                pathCount: bitmapData.count, isInternal: true, keyTrailerLength: 0))
            bom.addBlock(BOMTree.leafInternal(
                sorted: bitmapData.map { entry in
                    let inline = entry.key.withContiguousStorageIfAvailable { bytes -> UInt32 in
                        UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
                            | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                    } ?? 0
                    return (key: inline, value: entry.value)
                },
                valueBlockIDs: bitmapValueIDs.map { $0 },
                blockSize: 1024))
            for entry in bitmapData {
                bom.addBlock(entry.value)
            }
        }

        // ---- Variables table (actool order) ----
        bom.setVariable("CARHEADER", blockID: carHeaderID)
        bom.setVariable("RENDITIONS", blockID: renditionsTree.key)
        bom.setVariable("FACETKEYS", blockID: facetTree.key)
        bom.setVariable("APPEARANCEKEYS", blockID: appearanceTree.key)
        bom.setVariable("KEYFORMAT", blockID: keyFormatID)
        bom.setVariable("EXTENDED_METADATA", blockID: extendedMetadataID)
        if !bitmapData.isEmpty {
            bom.setVariable("BITMAPKEYS", blockID: bitmapTreeHeaderID)
        }

        return bom.finalize()
    }

    /// BITMAPKEYS entries: inline u32 key = NameIdentifier (big-endian 4
    /// bytes), value = the 52/48-byte descriptor. Color-only assets produce
    /// no row.
    private func bitmapEntries(layout: CARLayout) -> [(key: Data, value: Data)] {
        layout.assets.compactMap { asset in
            guard let descriptor = BitmapKeys.descriptor(
                forAsset: asset.name,
                renditions: asset.renditions
            ) else { return nil }
            let identifier = UInt32(FacetKeys.nameHash(asset.name) & 0xFFFF)
            return (key: Data([
                UInt8(truncatingIfNeeded: identifier >> 24),
                UInt8(truncatingIfNeeded: identifier >> 16),
                UInt8(truncatingIfNeeded: identifier >> 8),
                UInt8(truncatingIfNeeded: identifier),
            ]), value: descriptor.encode())
        }
    }

    private func csiData(for rendition: Rendition) -> Data {
        switch rendition.body {
        case .bitmap(let body):
            let scaleFactor = UInt32(rendition.scale?.factor ?? 1) * 100
            return CSIWriter.bitmap(name: rendition.name, body: body, scaleFactor: scaleFactor)
        case .multiSized(let body):
            return CSIWriter.multiSized(name: rendition.name, body: body)
        case .color(let body):
            return CSIWriter.color(name: rendition.name, body: body)
        case .preservedSource(let body):
            // SVG and PDF renditions are scale-free; the reference leaves
            // scaleFactor=0 for them. JPGs respect the @Nx suffix the same
            // way PNGs do.
            let scaleFactor: UInt32 = {
                switch body.format {
                case .svg, .pdf: return 0
                case .jpeg: return UInt32(rendition.scale?.factor ?? 1) * 100
                }
            }()
            return CSIWriter.preservedSource(body: body, scaleFactor: scaleFactor)
        }
    }
}
