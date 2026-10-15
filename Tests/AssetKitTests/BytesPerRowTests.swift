import Foundation
import Testing
@testable import AssetKit

/// The TVL 1007 stride must equal the byte width of the pixel rows in the
/// MLEC chunks. Apple `assetutil --validate-file` decodes each chunk with
/// that stride: a 16-byte-aligned stride over unpadded rows made it report
/// `early EOF ... at row N` and `Image data corrupted` for the packed symbol
/// atlases of an AssetKit-built IceCubes car (118x25 GA8: rows of 236 bytes,
/// stride written as 240). The same car with the stride written as 236
/// passed. Apple's car stores the exact stride.
@Suite("TVL bytes per row")
struct BytesPerRowTests {
    /// The 1007 entry's stride value inside a CSI blob, found by its type and length fields.
    private func stride(in csi: Data) -> UInt32? {
        let needle: [UInt8] = [0xEF, 0x03, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00]
        let bytes = [UInt8](csi)
        guard bytes.count > needle.count + 4 else { return nil }
        for i in 0...(bytes.count - needle.count - 4) where Array(bytes[i..<i + needle.count]) == needle {
            let o = i + needle.count
            return UInt32(bytes[o]) | UInt32(bytes[o + 1]) << 8 | UInt32(bytes[o + 2]) << 16 | UInt32(bytes[o + 3]) << 24
        }
        return nil
    }

    @Test("Packed GA8 atlas of width 118 carries stride 236, not 240")
    func packedAtlasStride() throws {
        let body = SymbolPackedBody(
            width: 118, height: 25, pixelsGA: [UInt8](repeating: 0, count: 118 * 25 * 2), scale: 1,
            renditionName: "ZZZZPackedAsset-1.0.1-gamut0")
        #expect(stride(in: CSIWriter.symbolPacked(body: body, scaleFactor: 100)) == 236)
    }

    @Test("BGRA bitmap of width 3 carries stride 12, not 16")
    func bitmapStride() throws {
        let body = BitmapBody(
            width: 3, height: 2, pixelsBGRA: [UInt8](repeating: 0, count: 3 * 2 * 4), colorSpaceID: 1,
            kind: .image, renditionName: "x.png")
        #expect(stride(in: CSIWriter.bitmap(name: "x", body: body, scaleFactor: 100)) == 12)
    }
}
