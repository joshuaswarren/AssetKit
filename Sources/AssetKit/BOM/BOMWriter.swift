import Foundation

/// Writes a BOM (Bill of Materials) container in actool 27.0's layout.
///
/// Container layout (verified byte-level against Apple's output):
/// - 512-byte header at offset 0
/// - Block payloads packed sequentially
/// - Zero padding to 16-byte boundary
/// - Vars table (count u32-BE, then {blockID u32-BE, nameLen u8, name} per entry)
/// - Zero padding to 16-byte boundary
/// - Block index table (count u32-BE = 256, then {addr u32-BE, len u32-BE} per entry,
///   entry 0 reserved null, unused entries zero-length), padded to 256 entries
struct BOMWriter {
    struct Block {
        var data: Data
    }

    struct Variable {
        var name: String
        var blockID: UInt32
    }

    /// actool 27.0 writes a fixed-capacity block index: 256 entries, unused
    /// tail entries zero-length. Larger catalogs grow in 256-entry steps.
    static let indexCapacity = 256

    private var blocks: [Block] = []
    private var variables: [Variable] = []

    init() {
        // Block 0 is reserved/null.
        blocks.append(Block(data: Data()))
    }

    @discardableResult
    mutating func addBlock(_ data: Data) -> UInt32 {
        blocks.append(Block(data: data))
        return UInt32(blocks.count - 1)
    }

    mutating func setVariable(_ name: String, blockID: UInt32) {
        variables.append(Variable(name: name, blockID: blockID))
    }

    func finalize() -> Data {
        var writer = ByteWriter()

        // Header placeholder; patched after all data is written.
        writer.write(Array("BOMStore".utf8)) // 0x00: magic (8 bytes)
        writer.writeBE(UInt32(1))            // 0x08: version
        writer.writeBE(UInt32(UInt32(blocks.count - 1))) // 0x0C: numberOfBlocks (real, excl. null entry 0)
        writer.writeBE(UInt32(0))            // 0x10: indexOffset (patched)
        writer.writeBE(UInt32(0))            // 0x14: indexLength (patched)
        writer.writeBE(UInt32(0))            // 0x18: varsOffset (patched)
        writer.writeBE(UInt32(0))            // 0x1C: varsLength (patched)
        writer.writeZeros(512 - writer.offset)

        // Blocks sequentially.
        var blockOffsets: [UInt32] = [0] // block 0 is reserved/null
        for block in blocks.dropFirst() {
            blockOffsets.append(UInt32(writer.offset))
            writer.write(block.data)
        }

        // Index table immediately after blocks.
        let indexOffset = UInt32(writer.offset)
        let indexCount = max(Self.indexCapacity, blocks.count)
        writer.writeBE(UInt32(indexCount))
        for i in 0..<indexCount {
            let addr = i < blocks.count ? (i == 0 ? UInt32(0) : blockOffsets[i]) : UInt32(indexOffset)
            let len = i < blocks.count ? UInt32(blocks[i].data.count) : 0
            writer.writeBE(addr)
            writer.writeBE(len)
        }
        // 4-byte zero gap between the index entries and the vars table
        // (Apple's layout; its indexLength spans to EOF including this gap
        // and the vars table).
        writer.writeZeros(4)

        // Vars table after the gap.
        let varsOffset = UInt32(writer.offset)
        writer.writeBE(UInt32(variables.count))
        for v in variables {
            writer.writeBE(v.blockID)
            let nameBytes = Array(v.name.utf8)
            precondition(nameBytes.count <= 255)
            writer.write(byte: UInt8(nameBytes.count))
            writer.write(nameBytes)
        }
        let varsLength = UInt32(writer.offset) - varsOffset
        // Apple's indexLength runs from the index start to end-of-file,
        // swallowing the gap and the vars table.
        let indexLength = UInt32(writer.offset) - indexOffset

        writer.patchBE(indexOffset, at: 0x10)
        writer.patchBE(indexLength, at: 0x14)
        writer.patchBE(varsOffset, at: 0x18)
        writer.patchBE(varsLength, at: 0x1C)

        return writer.data
    }
}
