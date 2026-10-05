import Foundation

/// MLEC wrapper for bitmap pixels, framed in one or four KCBC chunks.
///
/// Layout verified against actool's reference Assets.car:
///
///   MLEC magic        4 bytes
///   flags             u32  (bit 0 set for these LZFSE chunk payloads; bit 1 =
///                           every alpha sample is full: assetutil "Opaque".
///                           IceCubes oracle car: 120 opaque bitmaps carry 2/3,
///                           31 with partial alpha carry 0/1)
///   bytesPerPixel     u32  (actool writes the CONSTANT 4 — even for GA8,
///                           whose payload chunks are 2 bytes per pixel;
///                           verified on the base+tinted oracle car)
///   chunkCount        u32  (3 or 4)
///   then chunkCount * KCBC chunks
///
/// Each KCBC chunk:
///
///   KCBC magic        4 bytes
///   reserved          8 zero bytes
///   chunkHeight       u32  (rows covered by this chunk)
///   payloadSize       u32  (bytes of compressed payload following)
///   payload[]         LZFSE bvx2 stream
///
/// Chunking policy mirrors actool: three chunks of floor(height/3) rows,
/// plus a fourth chunk carrying the remainder when height does not divide
/// by three (1024 -> 341/341/341/1; 120 -> 3x40). The GA8/GA16 oracle cars
/// confirm the four-chunk split for 1024-row icons; CoreUI also accepts a
/// single chunk, but App Store processing compares against actool's shape.
enum MLECBody {
    static func encode(
        width: UInt32,
        height: UInt32,
        bytesPerPixel: UInt32 = 4,
        opaque: Bool,
        pixels: [UInt8]
    ) -> Data {
        let bytesPerRow = Int(width) * Int(bytesPerPixel)
        let rowsPerChunk = height / 3
        let remainder = height % 3
        var chunks: [(rows: UInt32, payload: [UInt8])] = []
        if rowsPerChunk == 0 {
            // Height 1..2: the three-way split degenerates; one chunk.
            chunks.append((rows: height, payload: LZFSE.encode(pixels)))
        } else {
            for i in 0..<3 {
                let start = Int(i) * Int(rowsPerChunk) * bytesPerRow
                let end = start + Int(rowsPerChunk) * bytesPerRow
                chunks.append((rows: rowsPerChunk, payload: LZFSE.encode(Array(pixels[start..<end]))))
            }
            if remainder > 0 {
                let start = 3 * Int(rowsPerChunk) * bytesPerRow
                chunks.append((rows: remainder, payload: LZFSE.encode(Array(pixels[start...]))))
            }
        }

        var w = ByteWriter()
        w.writeFourCC("MLEC")
        w.writeLE(UInt32(opaque ? 3 : 1))
        w.writeLE(UInt32(4))                    // bytesPerPixel: constant 4, like actool
        w.writeLE(UInt32(chunks.count))

        for chunk in chunks {
            w.writeFourCC("KCBC")
            w.writeZeros(8)                     // reserved
            w.writeLE(chunk.rows)               // chunkHeight (rows)
            w.writeLE(UInt32(chunk.payload.count))
            w.write(chunk.payload)
        }
        return w.data
    }
}
