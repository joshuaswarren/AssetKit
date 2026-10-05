import Foundation
import PNG
@testable import AssetKit

/// Deterministic test-only `PDFRasterizer`. Claims a fixed page size and
/// produces a real PNG of exactly the requested dimensions filled with a
/// configurable color, recording every call. Lives in `Tests/.../Helpers/`
/// so PDF shape tests run without poppler installed.
final class StubPDFRasterizer: PDFRasterizer, @unchecked Sendable {
    /// Page size in points the stub reports from `dimensions`.
    var pageSize: (width: Double, height: Double)

    /// Fill color every rasterise call paints with. Alpha 0 samples let a
    /// test exercise the transparent-background path; RGB (r, g, b) with
    /// r == g == b exercises gray classification.
    var fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

    /// Whether rasterize() answers with one extra pixel column/row the way
    /// poppler's ceil does for fractional page boxes (exercises the crop).
    var overshoots: Bool = false

    private let lock = NSLock()
    private var _calls: [(width: UInt32, height: UInt32)] = []

    var callsRecorded: [(width: UInt32, height: UInt32)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    init(
        pageSize: (width: Double, height: Double) = (100, 50),
        fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 0, 255, 255)
    ) {
        self.pageSize = pageSize
        self.fill = fill
    }

    func dimensions(pdfData: Data) throws -> (width: Double, height: Double) {
        pageSize
    }

    func rasterize(pdfData: Data, pixelWidth: UInt32, pixelHeight: UInt32) throws -> Data {
        lock.lock()
        _calls.append((pixelWidth, pixelHeight))
        lock.unlock()
        let w = pixelWidth + (overshoots ? 1 : 0)
        let h = pixelHeight + (overshoots ? 1 : 0)
        let rgba = [PNG.RGBA<UInt8>](
            repeating: PNG.RGBA<UInt8>(fill.r, fill.g, fill.b, fill.a),
            count: Int(w) * Int(h)
        )
        let layout = PNG.Layout(format: .rgba8(palette: [], fill: nil))
        let image = PNG.Image(
            packing: rgba,
            size: (x: Int(w), y: Int(h)),
            layout: layout
        )
        var stream = MemoryBytestreamDestination()
        try image.compress(stream: &stream)
        return Data(stream.bytes)
    }
}
