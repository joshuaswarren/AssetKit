import Foundation

/// PDF source handler: emits one preserved-source vector rendition plus
/// three rasterised bitmap fallbacks at 1x / 2x / 3x — the same fan-out as
/// `SVGSource`, with three PDF-specific differences verified against the
/// Xcode 27.0 NNW oracle:
///
/// - **Pixel grids come from the page's point size**, rounded per axis:
///   `round(points × scale)` (feedbin's 368.203 × 342.891 pt page yields
///   368×343 / 736×686 / 1105×1029).
/// - **Gray pages compile to gray renditions**: a page whose every pixel is
///   neutral (R=G=B, e.g. a DeviceGray source) is stored as `GA8 ` gray
///   gamma 22, matching Apple's Encoding/Colorspace for template glyphs.
/// - **`preserves-vector-representation` moves the vector rendition's key**:
///   preserved → the dedicated vector part at scale 1 (like SVG); not
///   preserved → the generic-image part at scale 0, which is what makes
///   `assetutil` print those Vector rows without a Scale.
enum PDFSource {
    struct Context {
        var assetName: String
        var idiom: Idiom
        var appearance: Appearance?
        var filename: String
        var preservesVectorRepresentation: Bool
        var renderingIntent: BitmapBody.RenderingIntent
    }

    static func renditions(
        bytes: Data,
        context: Context,
        rasteriser: any PDFRasterizer
    ) throws -> [Rendition] {
        var out: [Rendition] = []

        // 1. Vector source rendition. The PDF bytes are preserved verbatim
        //    in a DWAR envelope (raw payload, like JPEG). Slot selection:
        //    preserving sets keep the dedicated vector part at scale 1;
        //    non-preserving sets key the generic-image part at scale 0.
        out.append(Rendition(
            name: context.assetName,
            idiom: context.idiom,
            scale: context.preservesVectorRepresentation ? .x1 : nil,
            appearance: context.appearance,
            gamut: nil,
            body: .preservedSource(PreservedSourceBody(
                format: .pdf(preservesVector: context.preservesVectorRepresentation),
                sourceData: bytes,
                renditionName: context.filename
            ))
        ))

        // 2. Rasterised bitmap fallbacks at 1x / 2x / 3x, pixel grid =
        //    round(page points × scale). The rasteriser returns PNG bytes;
        //    poppler ceils fractional page boxes so the decoded image may
        //    run one pixel over per axis — crop it back to the grid.
        let page = try dimensions(
            bytes, asset: context.assetName, filename: context.filename,
            rasteriser: rasteriser
        )
        for scale: Scale in [.x1, .x2, .x3] {
            let targetWidth = UInt32((page.width * Double(scale.factor)).rounded())
            let targetHeight = UInt32((page.height * Double(scale.factor)).rounded())
            let pngData: Data
            do {
                pngData = try rasteriser.rasterize(
                    pdfData: bytes,
                    pixelWidth: targetWidth,
                    pixelHeight: targetHeight
                )
            } catch {
                throw XCAssetCompilerError.pdfRasterizationFailed(
                    asset: context.assetName,
                    filename: context.filename,
                    underlying: String(describing: error)
                )
            }
            let (rw, rh, bgra): (UInt32, UInt32, [UInt8])
            do {
                let d = try PNGSource.decodeBGRA(pngData)
                (rw, rh, bgra) = (d.width, d.height, d.bgra8)
            } catch {
                throw XCAssetCompilerError.pdfRasterizationFailed(
                    asset: context.assetName,
                    filename: context.filename,
                    underlying: String(describing: error)
                )
            }
            guard rw >= targetWidth, rh >= targetHeight else {
                throw XCAssetCompilerError.pdfRasterizationFailed(
                    asset: context.assetName,
                    filename: context.filename,
                    underlying: "rasteriser produced \(rw)×\(rh) pixels, expected at least "
                        + "\(targetWidth)×\(targetHeight)"
                )
            }
            let pixels = cropped(bgra, from: rw, rh, to: targetWidth, targetHeight)
            // A page whose every pixel is neutral rasterises to gray, the
            // same classification actool applies to DeviceGray sources
            // (NNW oracle: disclosure and faviconTemplateImage are 'GA8 '
            // gray gamma 22, every color logo stays ARGB sRGB).
            let gray = isGray(pixels)
            let body = BitmapBody(
                width: targetWidth,
                height: targetHeight,
                pixelsBGRA: gray ? gray8(pixels) : pixels,
                colorSpaceID: gray ? 2 : Gamut.sRGB.colorSpaceID,
                kind: .image,
                pixelFormat: gray ? .gray8 : .bgra8,
                derivedFromVector: true,
                preservesVectorRepresentation: context.preservesVectorRepresentation,
                renderingIntent: context.renderingIntent,
                renditionName: context.filename
            )
            out.append(Rendition(
                name: context.assetName,
                idiom: context.idiom,
                scale: scale,
                appearance: context.appearance,
                gamut: .sRGB,
                body: .bitmap(body)
            ))
        }
        return out
    }

    static func dimensions(
        _ bytes: Data, asset: String, filename: String, rasteriser: any PDFRasterizer
    ) throws -> (width: Double, height: Double) {
        do {
            let page = try rasteriser.dimensions(pdfData: bytes)
            guard page.width > 0, page.height > 0 else {
                throw RasterizerSizeError("page size \(page) is not positive")
            }
            return page
        } catch {
            throw XCAssetCompilerError.pdfRasterizationFailed(
                asset: asset,
                filename: filename,
                underlying: String(describing: error)
            )
        }
    }

    private struct RasterizerSizeError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    /// True when every pixel's RGB channels are equal (neutral content).
    /// Premultiplied BGRA buffer, 4 bytes per pixel.
    private static func isGray(_ bgra: [UInt8]) -> Bool {
        var index = 0
        while index < bgra.count {
            if bgra[index] != bgra[index + 1] || bgra[index + 1] != bgra[index + 2] {
                return false
            }
            index += 4
        }
        return true
    }

    /// Packs premultiplied BGRA pixels to interleaved gray+alpha bytes
    /// (Rec. 709 luma), the same encoding as the tinted-icon gray path.
    private static func gray8(_ bgra: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(bgra.count / 2)
        var index = 0
        while index < bgra.count {
            let blue = Double(bgra[index])
            let green = Double(bgra[index + 1])
            let red = Double(bgra[index + 2])
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            out.append(UInt8(max(0, min(255, luma.rounded()))))
            out.append(bgra[index + 3])
            index += 4
        }
        return out
    }

    /// Drops trailing rows/columns so a rasteriser that ceiled the page box
    /// lands exactly on the requested grid. Target is never larger than
    /// source (poppler only rounds up).
    private static func cropped(
        _ bgra: [UInt8], from sourceWidth: UInt32, _ sourceHeight: UInt32,
        to targetWidth: UInt32, _ targetHeight: UInt32
    ) -> [UInt8] {
        guard sourceWidth != targetWidth || sourceHeight != targetHeight else { return bgra }
        precondition(
            sourceWidth >= targetWidth && sourceHeight >= targetHeight,
            "rasterised page smaller than the requested grid: "
                + "\(sourceWidth)×\(sourceHeight) < \(targetWidth)×\(targetHeight)")
        var out = [UInt8]()
        out.reserveCapacity(Int(targetWidth) * Int(targetHeight) * 4)
        for y in 0..<Int(targetHeight) {
            let rowStart = y * Int(sourceWidth) * 4
            out.append(contentsOf: bgra[rowStart..<rowStart + Int(targetWidth) * 4])
        }
        return out
    }
}
