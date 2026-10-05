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
        // -1 marks external variable-length keys (Apple's FACETKEYS /
        // APPEARANCEKEYS); bitPattern keeps that representable.
        w.writeBE(UInt32(bitPattern: Int32(truncatingIfNeeded: keyTrailerLength)))
        w.writeZeros(4)
        precondition(w.offset == 29, "tree header must be 29 bytes; got \(w.offset)")
        return w.data
    }

    /// External-key leaf: the entry table, a zero key-offset region
    /// (count x u32), and — for fixed-length-key trees (RENDITIONS) — the
    /// concatenated key bytes; the whole region is zero-padded to
    /// `blockSize` and `keyAreaLength` more zero bytes are appended (the
    /// key area is reserved twice in the file length, as actool 27.0 does
    /// for RENDITIONS).
    ///
    /// Variable-length-key trees (FACETKEYS, APPEARANCEKEYS) store their
    /// keys in external blocks ONLY: Apple's leaf for those trees is a bare
    /// blockSize-zero region with no inline keys and no trailing key area.
    /// Readers resolve names through the key blocks there; inlining
    /// variable-length keys makes them read misaligned slices (assetutil
    /// rendered "UIAppearanceDark" as "earanceDark" off the padded slots).
    static func leafExternal(
        sorted: [(key: Data, value: Data)],
        keyBlockIDs: [UInt32],
        valueBlockIDs: [UInt32],
        blockSize: UInt32,
        inlineKeys: Bool = true,
        forward: UInt32 = 0,
        backward: UInt32 = 0
    ) -> Data {
        precondition(sorted.count == keyBlockIDs.count && sorted.count == valueBlockIDs.count)
        var w = ByteWriter()
        w.writeBE(UInt16(1))
        w.writeBE(UInt16(sorted.count))
        w.writeBE(forward)
        w.writeBE(backward)
        for i in sorted.indices {
            w.writeBE(valueBlockIDs[i])
            w.writeBE(keyBlockIDs[i])
        }
        w.writeZeros(4)
        return finishPage(&w, keys: sorted.map(\.key), blockSize: blockSize, inlineKeys: inlineKeys)
    }

    /// Branch page over leaves (actool 27.0, Mastodon's 714-rendition car): `count` = children - 1
    /// pairs (child page, key block of that child's last entry), then the last child's page id
    /// in the slot a leaf leaves zero, then the separator keys inline.
    static func branch(children: [UInt32], separatorKeys: [Data], separatorKeyBlockIDs: [UInt32],
                       blockSize: UInt32) -> Data {
        precondition(children.count == separatorKeys.count + 1 && separatorKeys.count == separatorKeyBlockIDs.count)
        var w = ByteWriter()
        w.writeBE(UInt16(0))
        w.writeBE(UInt16(separatorKeys.count))
        w.writeBE(UInt32(0))
        w.writeBE(UInt32(0))
        for i in separatorKeys.indices {
            w.writeBE(children[i])
            w.writeBE(separatorKeyBlockIDs[i])
        }
        w.writeBE(children[children.count - 1])
        return finishPage(&w, keys: separatorKeys, blockSize: blockSize, inlineKeys: true)
    }

    /// Inline keys (if any), then zeros up to `blockSize` plus the key area: actool reserves the
    /// key area a second time, and the page grows past `blockSize` when its keys do not fit.
    private static func finishPage(_ w: inout ByteWriter, keys: [Data], blockSize: UInt32, inlineKeys: Bool) -> Data {
        let keyAreaLength = inlineKeys ? keys.reduce(0) { $0 + $1.count } : 0
        if inlineKeys {
            for key in keys {
                w.write(key)
            }
        }
        w.writeZeros(max(0, Int(blockSize) + keyAreaLength - w.offset))
        return w.data
    }

    /// Most entries a page holds: (blockSize - 12-byte page header) / 8-byte pair; 510 at 4096
    /// (assetutil: "page->numKeys(778) > tree->maxKeys(510)").
    static func maxKeys(blockSize: UInt32) -> Int { (Int(blockSize) - 12) / 8 }

    /// Entry counts per leaf. actool builds the tree by inserting keys in order and splitting a
    /// full leaf in half, so every leaf but the last holds 256 entries (714 renditions: 256 + 458).
    static func leafSizes(count: Int, blockSize: UInt32) -> [Int] {
        var sizes: [Int] = []
        var rest = count
        while rest > maxKeys(blockSize: blockSize) {
            sizes.append(256)
            rest -= 256
        }
        return sizes + [rest]
    }

    /// Entry counts per leaf of an internal-key tree (BITMAPKEYS): actool inserts these out of key
    /// order, so its leaves come out even (Mastodon's 174 bitmap keys: 87 + 87).
    static func evenLeafSizes(count: Int, blockSize: UInt32) -> [Int] {
        let pages = max(1, (count + maxKeys(blockSize: blockSize) - 1) / maxKeys(blockSize: blockSize))
        return (0..<pages).map { count / pages + ($0 < count % pages ? 1 : 0) }
    }

    /// Internal-key leaf (BITMAPKEYS): each entry stores the u32 key inline
    /// (big-endian), followed by a zero offset slot; zero-padded to
    /// `blockSize` with no key area.
    static func leafInternal(
        sorted: [(key: UInt32, value: Data)],
        valueBlockIDs: [UInt32],
        blockSize: UInt32,
        forward: UInt32 = 0,
        backward: UInt32 = 0
    ) -> Data {
        precondition(sorted.count == valueBlockIDs.count)
        var w = ByteWriter()
        w.writeBE(UInt16(1))
        w.writeBE(UInt16(sorted.count))
        w.writeBE(forward)
        w.writeBE(backward)
        for (i, entry) in sorted.enumerated() {
            w.writeBE(valueBlockIDs[i])
            w.writeBE(entry.key)
        }
        w.writeZeros(max(0, Int(blockSize) - w.offset))
        return w.data
    }

    /// Branch over internal-key leaves: (child, that child's last inline key) pairs, then the last
    /// child; zero-padded to `blockSize`, no key area.
    static func branchInternal(children: [UInt32], separatorKeys: [UInt32], blockSize: UInt32) -> Data {
        precondition(children.count == separatorKeys.count + 1)
        var w = ByteWriter()
        w.writeBE(UInt16(0))
        w.writeBE(UInt16(separatorKeys.count))
        w.writeBE(UInt32(0))
        w.writeBE(UInt32(0))
        for (child, key) in zip(children, separatorKeys) {
            w.writeBE(child)
            w.writeBE(key)
        }
        w.writeBE(children[children.count - 1])
        w.writeZeros(max(0, Int(blockSize) - w.offset))
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
