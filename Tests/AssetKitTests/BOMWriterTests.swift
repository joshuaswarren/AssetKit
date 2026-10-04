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
        // numberOfBlocks is BE u32 at 0x0C; we have 2 (block 0 reserved + 1 we added)
        #expect(bytes[12...15] == [0, 0, 0, 2])
        let indexOff = readU32BE(data, 0x10)
        let varsOff = readU32BE(data, 0x18)
        #expect(indexOff > 0)
        #expect(varsOff > indexOff)
    }

    @Test("Tree round-trip: parse our own output structurally")
    func treeRoundTrip() {
        let entries: [BOMTree.Entry] = [
            .init(key: Data("alpha".utf8), value: Data([0x01])),
            .init(key: Data("bravo".utf8), value: Data([0x02])),
            .init(key: Data("charlie".utf8), value: Data([0x03])),
        ]
        let sorted = entries.sorted { BOMTree.byteCompare($0.key, $1.key) < 0 }
        var dataIDs: [(UInt32, UInt32)] = []
        var next: UInt32 = 1
        for _ in sorted {
            dataIDs.append((next, next + 1))
            next += 2
        }
        let trailer = sorted.reduce(Data()) { $0 + $1.key }
        let leafData = BOMTree.leaf(
            entries: sorted.enumerated().map { (index, entry) in
                (valueBlockID: dataIDs[index].1, key: dataIDs[index].0)
            },
            blockSize: BOMTree.defaultBlockSize, isInternal: false, trailer: trailer)
        let headerData = BOMTree.header(
            leafBlockID: next, blockSize: BOMTree.defaultBlockSize,
            pathCount: sorted.count, isInternal: false, keyTrailerLength: trailer.count)

        // Parse the leaf structurally.
        let leafBytes = [UInt8](leafData)
        let isLeaf = Int(leafBytes[0]) << 8 | Int(leafBytes[1])
        let count = Int(leafBytes[2]) << 8 | Int(leafBytes[3])
        #expect(isLeaf == 1)
        #expect(count == 3)
        // Padding to blockSize, then the key trailer.
        #expect(leafBytes.count == Int(BOMTree.defaultBlockSize) + trailer.count)
        #expect(Array(leafBytes[Int(BOMTree.defaultBlockSize)...]) == Array(trailer))

        // Parse the header structurally.
        let headerBytes = [UInt8](headerData)
        let magic = headerBytes.prefix(4)
        #expect(Array(magic) == Array("tree".utf8))
        let childBlock = Int(headerBytes[8]) << 24 | Int(headerBytes[9]) << 16
            | Int(headerBytes[10]) << 8 | Int(headerBytes[11])
        #expect(childBlock == next)
        let trailerLen = Int(headerBytes[21]) << 24 | Int(headerBytes[22]) << 16
            | Int(headerBytes[23]) << 8 | Int(headerBytes[24])
        #expect(trailerLen == trailer.count)
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
