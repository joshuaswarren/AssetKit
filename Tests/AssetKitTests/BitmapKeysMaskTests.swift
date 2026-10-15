import Foundation
import Testing
@testable import AssetKit

/// BITMAPKEYS descriptor fields are value masks over the asset's own
/// renditions. Pinned against Apple `assetutil -U` (Xcode 27.0, macOS 26.6),
/// which rewrote exactly these fields of an AssetKit-built IceCubes car and
/// left every other descriptor alone; `assetutil --validate-file` reported
/// `invalid bitmapindex` for the car before and passed it after.
@Suite("BITMAPKEYS value masks")
struct BitmapKeysMaskTests {
    /// [appearance, localization, scale, idiom, subtype, glyphWeight, glyphSize,
    ///  dimension2, deploymentTarget, displayGamut, identifier, element, part]
    private let format = canonicalKeyOrder.filter { $0 != .dimension1 }

    private func words(_ descriptor: BitmapKeys.Descriptor) -> [UInt32] {
        let data = descriptor.encode()
        return (0..<data.count / 4).map { i in
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self) }
        }
    }

    private func bitmap(_ name: String, scale: Scale, deploymentTarget: UInt16?) -> Rendition {
        let body = BitmapBody(
            width: 1, height: 1, pixelsBGRA: [0, 0, 0, 0], colorSpaceID: 1, kind: .image, renditionName: name)
        return Rendition(
            name: name, idiom: .universal, scale: scale, deploymentTarget: deploymentTarget, body: .bitmap(body))
    }

    @Test("A deployment-target token on some renditions sets its bit; the others keep bit 0")
    func deploymentTargetMask() throws {
        // IceCubes avatar: the HEIF rendition is keyed deploymentTarget 2, the PNG fallback 0.
        let renditions = [
            bitmap("avatar", scale: .x1, deploymentTarget: nil),
            bitmap("avatar", scale: .x1, deploymentTarget: 2),
        ]
        let descriptor = try #require(BitmapKeys.descriptor(
            forAsset: "avatar", renditions: renditions, keyFormat: format))
        // Apple: [1, 0, 56, 13, -1, 1, 2, 1, 1, 1, 1, 1, 5, 1, -1, -1, -1]
        #expect(words(descriptor) == [
            1, 0, 56, 13, 0xFFFF_FFFF, 1, 0x02, 1, 1, 1, 1, 1, 0b101, 1, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF,
        ])
    }

    @Test("A symbol keyed at glyph sizes 1 and 2 carries glyph-size mask 6")
    func symbolGlyphSizeMask() throws {
        func vector(size: UInt16) -> Rendition {
            let body = SymbolVectorBody(
                glyphWeight: 4, glyphSize: size, identifier: 1, baseline: 0, capline: 0,
                leftMargin: 0, rightMargin: 0, availableSizes: nil, svg: Data(), renditionName: "rocket.svg")
            return Rendition(
                name: "rocket", idiom: .universal, scale: .x1, deploymentTarget: 5, body: .symbolVector(body))
        }
        func cached(scale: Scale, index: UInt16) -> Rendition {
            let body = SymbolCachedBody(
                glyphWeight: 4, glyphSize: 2, cachedIndex: index, identifier: 1, width: 1, height: 1,
                renditionName: "rocket.svg")
            return Rendition(
                name: "rocket", idiom: .universal, scale: scale, deploymentTarget: 5, body: .symbolCached(body))
        }
        let renditions = [vector(size: 1)] + [Scale.x1, .x2, .x3].enumerated().map { cached(scale: $1, index: UInt16($0)) }
        let descriptor = try #require(BitmapKeys.descriptor(
            forAsset: "rocket", renditions: renditions, keyFormat: format))
        // Apple: [1, 0, 56, 13, -1, 1, 14, 1, 1, 16, 6, 7, 32, 1, -1, -1, -1]
        #expect(words(descriptor) == [
            1, 0, 56, 13, 0xFFFF_FFFF, 1, 0x0E, 1, 1, 0x10, 6, 7, 0x20, 1, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF,
        ])
    }
}
