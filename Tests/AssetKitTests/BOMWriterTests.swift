import Foundation
import Testing
@testable import AssetKit

@Suite("BOMWriter")
struct BOMWriterTests {
    @Test("Header has BOMStore magic and points to non-zero index/vars")
    func headerLayout() {
        var bom = BOMWriter()
        let id = bom.addBlock(Data([0xAA, 0xBB, 0xCC]))
        bom.setVariable("DEMO", blockID: id)
        let data = bom.finalize()
        let bytes = [UInt8](data)
        #expect(Array(bytes.prefix(8)) == Array("BOMStore".utf8))
        // version is BE u32 at 0x08
        #expect(bytes[8...11] == [0, 0, 0, 1])
        // numberOfBlocks is BE u32 at 0x0C; actool counts real blocks only
        // (block 0 is the reserved null entry, not counted) — 1 here.
        #expect(bytes[12...15] == [0, 0, 0, 1])
        let indexOff = readU32BE(data, 0x10)
        let varsOff = readU32BE(data, 0x18)
        #expect(indexOff > 0)
        #expect(varsOff > indexOff)
    }

    @Test("Tree round-trip: parse our own output structurally")
    func treeRoundTrip() {
        let sorted: [(key: Data, value: Data)] = [
            (key: Data("alpha".utf8), value: Data([0x01])),
            (key: Data("bravo".utf8), value: Data([0x02])),
            (key: Data("charlie".utf8), value: Data([0x03])),
        ]
        var keyIDs: [UInt32] = []
        var valueIDs: [UInt32] = []
        var next: UInt32 = 1
        for _ in sorted {
            keyIDs.append(next)
            valueIDs.append(next + 1)
            next += 2
        }
        let perKeyLen = sorted.first?.key.count ?? 0
        let leafData = BOMTree.leafExternal(
            sorted: sorted,
            keyBlockIDs: keyIDs,
            valueBlockIDs: valueIDs,
            blockSize: BOMTree.defaultBlockSize)
        let headerData = BOMTree.header(
            leafBlockID: next, blockSize: BOMTree.defaultBlockSize,
            pathCount: sorted.count, isInternal: false, keyTrailerLength: perKeyLen)

        // Parse the leaf structurally.
        let leafBytes = [UInt8](leafData)
        let isLeaf = Int(leafBytes[0]) << 8 | Int(leafBytes[1])
        let count = Int(leafBytes[2]) << 8 | Int(leafBytes[3])
        #expect(isLeaf == 1)
        #expect(count == 3)
        // Entry table, then a single zero u32, then embedded keys.
        let entryEnd = 12 + count * 8
        #expect(leafBytes[entryEnd..<(entryEnd + 4)].allSatisfy { $0 == 0 })
        let keyArea = 16 + count * 8
        _ = entryEnd
        var cursor = keyArea
        for entry in sorted {
            let key = Array(leafBytes[cursor..<cursor + entry.key.count])
            #expect(key == Array(entry.key))
            cursor += entry.key.count
        }
        // Padded to blockSize, then the zero-filled key-area reserve
        // (reserve length = total embedded key bytes, like actool).
        let keyBytesTotal = sorted.reduce(0) { $0 + $1.key.count }
        #expect(leafBytes.count == Int(BOMTree.defaultBlockSize) + keyBytesTotal)
        #expect(leafBytes[Int(BOMTree.defaultBlockSize)...].allSatisfy { $0 == 0 })

        // Parse the header structurally.
        let headerBytes = [UInt8](headerData)
        let magic = headerBytes.prefix(4)
        #expect(Array(magic) == Array("tree".utf8))
        let childBlock = Int(headerBytes[8]) << 24 | Int(headerBytes[9]) << 16
            | Int(headerBytes[10]) << 8 | Int(headerBytes[11])
        #expect(childBlock == next)
        var trailerValue: Int = 0
        for offset in 21...24 {
            trailerValue = trailerValue << 8 | Int(headerBytes[offset])
        }
        #expect(trailerValue == perKeyLen)
    }

    private func readU32BE(_ data: Data, _ offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.index(data.startIndex, offsetBy: offset)])
        let b1 = UInt32(data[data.index(data.startIndex, offsetBy: offset + 1)])
        let b2 = UInt32(data[data.index(data.startIndex, offsetBy: offset + 2)])
        let b3 = UInt32(data[data.index(data.startIndex, offsetBy: offset + 3)])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private func readU16BE(_ data: Data, _ offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.index(data.startIndex, offsetBy: offset)])
        let b1 = UInt16(data[data.index(data.startIndex, offsetBy: offset + 1)])
        return (b0 << 8) | b1
    }
}
