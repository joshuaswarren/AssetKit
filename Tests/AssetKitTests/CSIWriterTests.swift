import Foundation
import Testing
@testable import AssetKit

@Suite("CSI writer")
struct CSIWriterTests {
    @Test("Bitmap CSI header is 184 bytes with reference field layout (risk-vector-flag)")
    func bitmapHeader() {
        let body = BitmapBody(
            width: 60, height: 60,
            pixelsBGRA: [UInt8](repeating: 0, count: 60 * 60 * 4),
            colorSpaceID: 1,
            kind: .appIcon,
            renditionName: "icon@2x.png"
        )
        let data = CSIWriter.bitmap(name: "AppIcon", body: body, scaleFactor: 200)
        let bytes = [UInt8](data)
        // tag 'CTSI' written as LE multi-char constant -> file bytes 'I','S','T','C'
        #expect(bytes[0] == 0x49)
        #expect(bytes[1] == 0x53)
        #expect(bytes[2] == 0x54)
        #expect(bytes[3] == 0x43)
        // version u32 LE = 1
        #expect(bytes[4] == 0x01)
        // renditionFlags u32 LE = 0 -> bit 1 (vector) cleared
        #expect(bytes[8] == 0)
        #expect(bytes[9] == 0)
        #expect(bytes[10] == 0)
        #expect(bytes[11] == 0)
        // scaleFactor u32 LE = 200 (= scale*100 for 2x)
        #expect(bytes[0x14] == 0xc8)
        #expect(bytes[0x15] == 0x00)
        #expect(bytes[0x16] == 0x00)
        #expect(bytes[0x17] == 0x00)
        // pixelFormat 'ARGB' LE: bytes 'B','G','R','A'
        #expect(bytes[0x18] == 0x42)
        #expect(bytes[0x19] == 0x47)
        #expect(bytes[0x1A] == 0x52)
        #expect(bytes[0x1B] == 0x41)
        // colorSpace u32 LE = 1
        #expect(bytes[0x1C] == 0x01)
        // layout u16 LE = 12 (bitmapIcon)
        #expect(bytes[0x24] == 0x0c)
        #expect(bytes[0x25] == 0x00)
        // name field (128 bytes from offset 0x28) starts with "icon@2x.png"
        let nameStart = 0x28
        let nameBytes = Array(bytes[nameStart..<(nameStart + 11)])
        #expect(nameBytes == Array("icon@2x.png".utf8))
        // bitmap CSI header alone is 184 bytes; body follows
        #expect(data.count >= 184)
    }

    @Test("Bitmap bytes-per-row TVL is the exact stride the rows are packed at", arguments: [29, 58, 60, 87])
    func bytesPerRowIsExact(width: UInt32) throws {
        let body = BitmapBody(
            width: width, height: width,
            pixelsBGRA: [UInt8](repeating: 0, count: Int(width * width) * 4),
            colorSpaceID: 1,
            kind: .appIcon,
            renditionName: "icon.png"
        )
        let bytes = [UInt8](CSIWriter.bitmap(name: "AppIcon", body: body, scaleFactor: 300))
        // TVL type 1007, value length 4, then the stride.
        let tag: [UInt8] = [0xEF, 0x03, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00]
        let start = try #require((184..<(bytes.count - tag.count - 4)).first {
            Array(bytes[$0..<($0 + tag.count)]) == tag
        })
        let value = bytes[(start + 8)..<(start + 12)].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(value == width * 4)
    }

    @Test("Color CSI body starts with COLR magic and four IEEE-754 doubles")
    func colorBody() {
        let body = ColorBody(red: 1, green: 0, blue: 0.5, alpha: 1, colorSpaceID: 0)
        let data = CSIWriter.color(name: "Accent", body: body)
        // CSI header is 184 bytes; body starts at offset 184
        #expect(data.count >= 184 + 4 + 4 + 4 + 4 + 8 * 4)
        let payloadStart = 184
        let magic = data.subdata(in: payloadStart..<(payloadStart + 4))
        #expect(Array(magic) == Array("COLR".utf8))
    }
}
