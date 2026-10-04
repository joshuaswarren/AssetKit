import Foundation

/// Writes BOM B+ trees in actool 27.0's physical layout.
///
/// Leaf layout (verified byte-level against actool 27.0 output):
///
/// `[isLeaf u16-BE][count u16-BE][forward u32-BE][backward u32-BE]`
/// `[count × { valueBlockID u32-BE, keyBlockID u32-BE }]`
/// `[count × u32-BE zeros]` — a vestigial per-key offset array (zeroed in
/// actool 27.0 output)
/// `[key bytes concatenated]`
///
/// The whole leaf is zero-padded to the tree's block size (4096; 1024 for
/// BITMAPKEYS) and then `keyAreaLength` extra zero bytes are appended — the
/// key area is reserved twice in the file length.
///
/// The tree header records `keyTrailerLength` = the per-entry key byte
/// length (18 for rendition keys, the facet name length for FACETKEYS, 0
/// for internal-key trees).
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
        w.writeBE(UInt32(isInternal ? 0 : keyTrailerLength))
        w.writeZeros(4)
        precondition(w.offset == 29, "tree header must be 29 bytes; got \(w.offset)")
        return w.data
    }

    /// External-key leaf: the entry table, a zero key-offset region
    /// (count x u32), and the concatenated key bytes — then the whole leaf
    /// is zero-padded to `blockSize` and `keyAreaLength` more zero bytes are
    /// appended (the key area is reserved twice in the file length, as
    /// actool 27.0 does).
    static func leafExternal(
        sorted: [(key: Data, value: Data)],
        keyBlockIDs: [UInt32],
        valueBlockIDs: [UInt32],
        blockSize: UInt32
    ) -> Data {
        precondition(sorted.count == keyBlockIDs.count && sorted.count == valueBlockIDs.count)
        var w = ByteWriter()
        w.writeBE(UInt16(1))
        w.writeBE(UInt16(sorted.count))
        w.writeBE(UInt32(0))
        w.writeBE(UInt32(0))
        for (i, entry) in sorted.enumerated() {
            w.writeBE(valueBlockIDs[i])
            w.writeBE(keyBlockIDs[i])
        }
        w.writeZeros(4)
        for entry in sorted {
            w.write(entry.key)
        }
        let keyAreaLength = sorted.reduce(0) { $0 + $1.key.count }
        if w.offset < Int(blockSize) {
            w.writeZeros(Int(blockSize) - w.offset)
        }
        w.writeZeros(keyAreaLength)
        return w.data
    }

    /// Internal-key leaf (BITMAPKEYS): each entry stores the u32 key inline
    /// (big-endian), followed by a zero offset slot; zero-padded to
    /// `blockSize` with no key area.
    static func leafInternal(
        sorted: [(key: UInt32, value: Data)],
        valueBlockIDs: [UInt32],
        blockSize: UInt32
    ) -> Data {
        precondition(sorted.count == valueBlockIDs.count)
        var w = ByteWriter()
        w.writeBE(UInt16(1))
        w.writeBE(UInt16(sorted.count))
        w.writeBE(UInt32(0))
        w.writeBE(UInt32(0))
        for (i, entry) in sorted.enumerated() {
            w.writeBE(valueBlockIDs[i])
            w.writeBE(entry.key)
        }
        if w.offset < Int(blockSize) {
            w.writeZeros(Int(blockSize) - w.offset)
        }
        return w.data
    }

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
