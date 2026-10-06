import Foundation
import Testing
@testable import AssetKit

/// Key / CSI / BITMAPKEYS shapes for PDF imagesets, verified against the
/// Xcode 27.0 NNW oracle: every PDF set emits one vector rendition plus
/// three bitmaps; `preserves-vector-representation` moves the vector
/// rendition between the vector part (scale 1) and the generic-image part
/// (scale 0); template-rendering-intent lands in the bitmap CSI flags; a
/// neutral-content page compiles to gray gamma 22.
@Suite("PDF source shapes")
struct PDFSourceTests {

    // MARK: - Rendition fan-out

    @Test("One PDF asset compiles to one vector + three bitmap renditions")
    func renditionFanout() throws {
        let renditions = try compile(fill: (255, 0, 255, 255))
        #expect(renditions.count == 4, "expected 1 vector + 3 bitmap renditions, got \(renditions.count)")
        let bitmaps = renditions.filter { if case .bitmap = $0.body { return true } else { return false } }
        #expect(Set(bitmaps.compactMap(\.scale)) == Set<Scale>([.x1, .x2, .x3]))
    }

    @Test("Bitmap pixel grid is round(points × scale); rasteriser overshoot is cropped")
    func rasterGridAndCrop() throws {
        let stub = StubPDFRasterizer(pageSize: (100.4, 50.6))
        stub.overshoots = true
        let renditions = try compile(rasteriser: stub)
        let bitmaps = renditions.filter { if case .bitmap = $0.body { return true } else { return false } }
        // 100.4 × 50.6 pt: 100/51, 201/101, 301/152 (round), while the stub
        // answers poppler's ceil grid (+1); the crop takes it back.
        let expected: [(Scale, UInt32, UInt32)] = [(.x1, 100, 51), (.x2, 201, 101), (.x3, 301, 152)]
        for (scale, width, height) in expected {
            let rendition = try #require(bitmaps.first { $0.scale == scale })
            let body = try #require(bitmapBody(rendition))
            #expect(body.width == width, "width at \(scale)")
            #expect(body.height == height, "height at \(scale)")
        }
        // The stub answers poppler's ceil grid (+1 per axis); the compiler
        // always asks for the exact rounded target grid.
        #expect(stub.callsRecorded.map { [$0.width, $0.height] }
            == [[100, 51], [201, 101], [301, 152]], "rasteriser asked for the target grid")
    }

    @Test("Neutral-content pages compile to gray gamma 22; color pages stay sRGB")
    func grayClassification() throws {
        for renditions in [try compile(fill: (9, 9, 9, 255)), try compile(fill: (0, 0, 0, 0))] {
            for rendition in renditions {
                guard case .bitmap(let body) = rendition.body else { continue }
                #expect(body.pixelFormat == .gray8, "neutral page should rasterise to gray")
            }
        }
        for rendition in try compile(fill: (9, 9, 8, 255)) {
            guard case .bitmap(let body) = rendition.body else { continue }
            #expect(body.pixelFormat == .bgra8, "colored page should stay ARGB")
        }
    }

    // MARK: - Rendition key slots

    @Test("Preserving sets key the vector at part 42 scale 1; others at part 181 scale 0")
    func vectorKeySlots() throws {
        let preserved = try #require(
            try compile(preservesVector: true).first { if case .preservedSource = $0.body { return true } else { return false } })
        let preservedKey = RenditionKey(rendition: preserved)
        #expect(preservedKey.part == 42)
        #expect(preservedKey.scale == 1)
        #expect(preservedKey.element == 85)

        let discarded = try #require(
            try compile(preservesVector: false).first { if case .preservedSource = $0.body { return true } else { return false } })
        let discardedKey = RenditionKey(rendition: discarded)
        #expect(discardedKey.part == 181)
        #expect(discardedKey.scale == 0)
        #expect(discarded.scale == nil, "non-preserving vector renditions carry no scale")
    }

    // MARK: - CSI records

    @Test("PDF vector CSI header+TVL matches the NNW oracle byte-for-byte")
    func vectorCSIBytes() throws {
        let body = PreservedSourceBody(
            format: .pdf(preservesVector: true),
            sourceData: Data(),
            renditionName: "bazqux-any.pdf"
        )
        let encoded = [UInt8](CSIWriter.preservedSource(body: body, scaleFactor: 0))
        let reference = [UInt8](try loadReference("PdfPreserved.csi.head.bin"))
        #expect(encoded.count > reference.count)
        // Byte-identical except the renditionLength slot (180..<184), which
        // depends on the wrapped payload size this test leaves empty.
        #expect(Array(encoded[0..<180]) == Array(reference[0..<180]),
                "CSI header + TVL must equal the oracle record (flags 0x04, 'PDF ', name, TVL 28)")
        #expect(Array(encoded[184..<reference.count]) == Array(reference[184..<reference.count]))
    }

    @Test("PDF vector body is a raw DWAR envelope around the source bytes")
    func vectorEnvelopeIsRaw() {
        let payload: [UInt8] = [0x25, 0x50, 0x44, 0x46] // "%PDF"
        let body = PreservedSourceBody(
            format: .pdf(preservesVector: false),
            sourceData: Data(payload),
            renditionName: "NewsBlur.pdf"
        )
        let encoded = [UInt8](CSIWriter.preservedSource(body: body, scaleFactor: 0))
        // Envelope starts after the 184-byte header + 28-byte TVL.
        let envelope = Array(encoded.suffix(12 + payload.count))
        #expect(Array(envelope.prefix(4)) == Array("DWAR".utf8))
        #expect(Array(envelope[4..<8]) == [0, 0, 0, 0], "PDF payloads are raw, not LZFSE")
        #expect(Array(envelope[8..<12]) == [UInt8(payload.count), 0, 0, 0])
        #expect(Array(envelope.dropFirst(12)) == payload)
        // pixelFormat 'PDF ' sits in the header as an LE multi-char constant.
        #expect(Array(encoded[24..<28]) == [0x20, 0x46, 0x44, 0x50])
    }

    @Test("Bitmap renditionFlags encode preservation and template intent")
    func bitmapFlags() throws {
        // (preservesVector, intent) -> expected flags, from the NNW oracle:
        // pv+original 0x104, non-pv+original 0x4, non-pv+automatic 0x14,
        // non-pv+template 0xc.
        let cases: [(Bool, BitmapBody.RenderingIntent, UInt32)] = [
            (true, .original, 0x104),
            (false, .original, 0x004),
            (false, .automatic, 0x014),
            (false, .template, 0x00c),
            (false, .unspecified, 0x014),
        ]
        for (preserves, intent, expected) in cases {
            let renditions = try compile(preservesVector: preserves, intent: intent)
            let bitmap = try #require(renditions.first { if case .bitmap = $0.body { return true } else { return false } })
            let body = try #require(bitmapBody(bitmap))
            let flags = flagsOf(CSIWriter.bitmap(name: bitmap.name, body: body, scaleFactor: 100))
            #expect(flags == expected, "flags for preserves=\(preserves) intent=\(intent)")
        }
        // SVG sources keep their verified flags: 0x10 category + 0x104.
        let svgBody = BitmapBody(
            width: 4, height: 4, pixelsBGRA: [UInt8](repeating: 0, count: 64),
            colorSpaceID: 1, kind: .image, derivedFromVector: true,
            renditionName: "Svg.svg"
        )
        let svgFlags = flagsOf(CSIWriter.bitmap(name: "Svg", body: svgBody, scaleFactor: 100))
        #expect(svgFlags == 0x114, "existing SVG behavior must not change")
        // PNG images keep the plain category bit.
        let pngBody = BitmapBody(
            width: 4, height: 4, pixelsBGRA: [UInt8](repeating: 0, count: 64),
            colorSpaceID: 1, kind: .image, renditionName: "Icon.png"
        )
        #expect(flagsOf(CSIWriter.bitmap(name: "Icon", body: pngBody, scaleFactor: 100)) == 0x10)
    }

    // MARK: - BITMAPKEYS

    @Test("BITMAPKEYS marker is 0x0e for preserving sets and 0x0f for others")
    func bitmapKeysMarker() throws {
        func marker(for renditions: [Rendition]) -> UInt32 {
            let descriptor = BitmapKeys.descriptor(forAsset: "Pdf", renditions: renditions, keyFormat: v1KeyFormat)!
            let bytes = [UInt8](descriptor.encode())
            return UInt32(bytes[24]) | (UInt32(bytes[25]) << 8)
                | (UInt32(bytes[26]) << 16) | (UInt32(bytes[27]) << 24)
        }
        #expect(marker(for: try compile(preservesVector: true)) == 0x0e)
        #expect(marker(for: try compile(preservesVector: false)) == 0x0f)
    }

    // MARK: - Helpers

    private func bitmapBody(_ rendition: Rendition) -> BitmapBody? {
        if case .bitmap(let body) = rendition.body { return body }
        return nil
    }

    private func flagsOf(_ csi: Data) -> UInt32 {
        let bytes = [UInt8](csi)
        return UInt32(bytes[8]) | (UInt32(bytes[9]) << 8)
            | (UInt32(bytes[10]) << 16) | (UInt32(bytes[11]) << 24)
    }

    private func compile(
        preservesVector: Bool = true,
        intent: BitmapBody.RenderingIntent = .original,
        fill: (r: UInt8, g: UInt8, b: UInt8, a: UInt8) = (255, 0, 255, 255),
        rasteriser: StubPDFRasterizer? = nil
    ) throws -> [Rendition] {
        let stub: StubPDFRasterizer
        if let rasteriser {
            stub = rasteriser
        } else {
            stub = StubPDFRasterizer(fill: fill)
        }
        let context = PDFSource.Context(
            assetName: "Pdf",
            idiom: .universal,
            appearance: nil,
            filename: "Icon.pdf",
            preservesVectorRepresentation: preservesVector,
            renderingIntent: intent
        )
        return try PDFSource.renditions(
            bytes: Data([0x25, 0x50, 0x44, 0x46]),
            context: context,
            rasteriser: stub
        )
    }

    private func loadReference(_ name: String) throws -> Data {
        let url = try fixtureBaseURL()
            .deletingLastPathComponent()
            .appendingPathComponent("Reference")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    private func fixtureBaseURL() throws -> URL {
        guard let url = Bundle.module.url(
            forResource: "Test",
            withExtension: "xcassets",
            subdirectory: "Fixtures"
        ) else {
            throw FixtureError.missingTestXCAssets
        }
        return url
    }

    private enum FixtureError: Error { case missingTestXCAssets }
}
