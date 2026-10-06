import Foundation
import PNG
@testable import AssetKit

/// Deterministic test-only `HEICDecoder`. Produces a real PNG of fixed
/// dimensions and a configurable fill, recording every call. Tests that
/// exercise HEIC imagesets use this so they don't depend on libheif being
/// installed in the test environment.
final class StubHEICDecoder: HEICDecoder, @unchecked Sendable {
    /// Fill color every decode call paints with.
    var fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)
    /// Decoded pixel size. Tests that compare decode dims with the
    /// preserved rendition's TVL size use this.
    var dimensions: (width: UInt32, height: UInt32)

    private let lock = NSLock()
    private var _calls: [Int] = []
    var callsRecorded: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    init(
        fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 255, 255, 255),
        dimensions: (width: UInt32, height: UInt32) = (1, 1)
    ) {
        self.fill = fill
        self.dimensions = dimensions
    }

    func decodeToPNG(heicData: Data) throws -> Data {
        lock.lock()
        _calls.append(heicData.count)
        lock.unlock()
        let w = Int(dimensions.width)
        let h = Int(dimensions.height)
        let rgba = [PNG.RGBA<UInt8>](
            repeating: PNG.RGBA<UInt8>(fill.r, fill.g, fill.b, fill.a),
            count: w * h
        )
        let layout = PNG.Layout(format: .rgba8(palette: [], fill: nil))
        let image = PNG.Image(packing: rgba, size: (x: w, y: h), layout: layout)
        var stream = MemoryBytestreamDestination()
        try image.compress(stream: &stream)
        return Data(stream.bytes)
    }
}