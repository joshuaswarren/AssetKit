import Foundation

/// Writes BOM B+ trees in actool 27.0's physical layout.
///
/// Layout (verified byte-level against actool 27.0 output):
///
/// - **Header block (29 bytes):** `'tree' u32-BE, version u32-BE(1), leaf
///   blockID u32-BE, blockSize u32-BE (4096, or 1024 for BITMAPKEYS),
///   pathCount u32-BE, isPathInternal u8, keyTrailerLength u32-BE, 4 zero
///   bytes. The trailer length is the size of the key-byte run appended after
///   the leaf's padding (0 for inline-key trees).
/// - **Leaf block:** `isLeaf u16-BE(1), count u16-BE, forward u32-BE, backward
///   u32-BE`, then `count * { valueBlockID u32-BE, keyBlockID u32-BE }` (or
///   `{ valueBlockID u32-BE, inlineKey u32-BE }` when internal), zero-padded to
///   blockSize, then the concatenated key bytes (`trailer`).
/// - **Data blocks:** one block per key and one per value, allocated
///   separately from the leaf.
enum BOMTree {
    struct Entry {
        var key: Data
        var value: Data
    }

    static let treeMagic: UInt32 = 0x74726565 // 'tree'
    static let defaultBlockSize: UInt32 = 4096

    /// Header block for a tree whose leaf lives in `leafBlockID`.
    static func header(
        leafBlockID: UInt32,
        blockSize: UInt32,
        pathCount: Int,
        isInternal: Bool,
        keyTrailerLength: Int
    ) -> Data {
        var w = ByteWriter()
        w.writeBE(treeMagic)
        w.writeBE(UInt32(1))
        w.writeBE(leafBlockID)
        w.writeBE(blockSize)
        w.writeBE(UInt32(pathCount))
        w.write(byte: isInternal ? 1 : 0)
        w.writeBE(UInt32(keyTrailerLength))
        w.writeZeros(4)
        precondition(w.offset == 29, "tree header must be 29 bytes; got \(w.offset)")
        return w.data
    }

    /// Leaf block: entry table zero-padded to `blockSize`, then `trailer`
    /// (the concatenated key bytes) appended after the padding. `keyIDs` are
    /// the key data block ids, or the inline u32 keys when `isInternal`.
    static func leaf(
        entries: [(valueBlockID: UInt32, keyID: UInt32)],
        blockSize: UInt32,
        isInternal: Bool,
        trailer: Data
    ) -> Data {
        var w = ByteWriter()
        w.writeBE(UInt16(1)) // isLeaf
        w.writeBE(UInt16(entries.count))
        w.writeBE(UInt32(0)) // forward
        w.writeBE(UInt32(0)) // backward
        for entry in entries {
            w.writeBE(entry.valueBlockID)
            w.writeBE(entry.keyID)
        }
        if w.offset < Int(blockSize) {
            w.writeZeros(Int(blockSize) - w.offset)
        }
        w.write(trailer)
        return w.data
    }

    /// Sorts entries by raw key bytes; BOM trees use byte-wise comparison and
    /// CoreUI binary-searches rendition keys.
    static func byteCompare(_ a: Data, _ b: Data) -> Int {
        let count = min(a.count, b.count)
        for i in 0..<count {
            let av = a[a.index(a.startIndex, offsetBy: i)]
            let bv = b[b.index(b.startIndex, offsetBy: i)]
            if av != bv { return av < bv ? -1 : 1 }
        }
        if a.count != b.count { return a.count < b.count ? -1 : 1 }
        return 0
    }
}
