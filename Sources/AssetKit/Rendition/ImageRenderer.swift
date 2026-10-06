import Foundation

/// Dispatches each source file in an asset to the matching source-format
/// handler (`PNGSource`, `SVGSource`, `JPEGSource`). Owns filesystem I/O,
/// missing-file detection, and the imageset / appiconset iteration; the
/// handlers own per-format rendition construction.
enum ImageRenderer {
    static func renditions(
        for set: LoadedImageSet,
        svgRasterizer: any SVGRasterizer,
        pdfRasterizer: any PDFRasterizer,
        heicDecoder: any HEICDecoder
    ) throws -> [Rendition] {
        var out: [Rendition] = []
        for image in set.contents.images {
            guard let filename = image.filename, !filename.isEmpty else { continue }
            let src = set.directory.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: src.path) else {
                throw XCAssetCompilerError.missingReferencedFile(asset: set.name, filename: filename)
            }
            guard let format = SourceFormat.detect(filename: filename) else {
                throw XCAssetCompilerError.unsupportedAssetType(filename)
            }
            let bytes = try Data(contentsOf: src)
            let appearance = image.appearances?.first { $0.darkLuminosity }
            switch format {
            case .png:
                let ctx = PNGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    gamut: image.displayGamut ?? .sRGB,
                    filename: filename,
                    kind: .image
                )
                out.append(contentsOf: try PNGSource.renditions(bytes: bytes, context: ctx))
            case .svg:
                let ctx = SVGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    appearance: appearance,
                    filename: filename
                )
                out.append(contentsOf: try SVGSource.renditions(
                    bytes: bytes,
                    context: ctx,
                    rasteriser: svgRasterizer
                ))
            case .jpeg:
                let ctx = JPEGSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    filename: filename
                )
                out.append(contentsOf: try JPEGSource.renditions(bytes: bytes, context: ctx))
            case .heic:
                let ctx = HEICSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    scale: image.scale,
                    appearance: appearance,
                    gamut: image.displayGamut ?? .sRGB,
                    filename: filename,
                    kind: .image
                )
                out.append(contentsOf: try HEICSource.renditions(
                    bytes: bytes,
                    context: ctx,
                    decoder: heicDecoder
                ))
            case .pdf:
                let properties = set.contents.properties
                let intent: BitmapBody.RenderingIntent = switch properties?
                    .templateRenderingIntent {
                case "template": .template
                case "original": .original
                case "automatic": .automatic
                default: .unspecified
                }
                let ctx = PDFSource.Context(
                    assetName: set.name,
                    idiom: image.idiom,
                    appearance: appearance,
                    filename: filename,
                    preservesVectorRepresentation: properties?.preservesVectorRepresentation ?? false,
                    renderingIntent: intent
                )
                out.append(contentsOf: try PDFSource.renditions(
                    bytes: bytes,
                    context: ctx,
                    rasteriser: pdfRasterizer
                ))
            }
        }
        return out
    }

    static func appIconRenditions(for appIcon: LoadedAppIcon, files: [IconFile]) throws -> [Rendition] {
        // Decode each source once, keeping its IconFile for index assignment.
        var decoded: [(file: IconFile, rendition: Rendition)] = []
        for file in files {
            let filename = file.sourceURL.lastPathComponent
            guard SourceFormat.detect(filename: filename) == .png else {
                throw XCAssetCompilerError.unsupportedAppIconSource(asset: appIcon.name, filename: filename)
            }
            let bytes = try Data(contentsOf: file.sourceURL)
            let scale: Scale = {
                switch file.scale {
                case 1: return .x1
                case 2: return .x2
                case 3: return .x3
                default: return .x1
                }
            }()
            // The appiconset's basename ("AppIcon") is the rendition name in
            // the CSI header for the reference; the per-file outputName
            // ("AppIcon60x60") is only used for CFBundleIconFiles in
            // Info.plist. We pass the source filename through as renditionName
            // because actool uses the filename (not the asset name) here.
            let ctx = PNGSource.Context(
                assetName: appIcon.name,
                idiom: file.idiom,
                scale: scale,
                appearance: file.appearance,
                gamut: .sRGB,
                filename: filename,
                kind: .appIcon
            )
            for rendition in try PNGSource.renditions(bytes: bytes, context: ctx) {
                decoded.append((file, rendition))
            }
        }

        // "Icon Index" = the rank of the rendition's point size among the
        // appiconset's distinct point sizes, ascending — shared across idioms
        // and scales (60 pt @2x and @3x are both index 1; an ipad 20 pt and
        // an iphone 20 pt are also both index 1). Both oracle runs agree.
        //
        // When the set provides an iphone 60 pt @3x source, actool also keys
        // it as the 90 pt large-phone home icon (subtype 1792, scale 2); the
        // 90 pt size then joins the ranking. Without a 60 pt @3x source no
        // 1792 variant is emitted (second oracle run).
        let largePhonePointSize = 90.0
        let hasLargePhoneVariant = files.contains {
            $0.appearance == nil && $0.idiom == .iphone && $0.pointSize == 60 && $0.scale == 3
        }
        var sizes = Set(files.map(\.pointSize))
        if hasLargePhoneVariant { sizes.insert(largePhonePointSize) }
        let iconIndexOfSize: [Double: UInt16] = Dictionary(
            uniqueKeysWithValues: sizes.sorted().enumerated().map { ($0.element, UInt16($0.offset + 1)) }
        )

        var out: [Rendition] = []
        // (idiom, subtype) -> point size -> icon index. One MultiSized
        // rendition is emitted per group, mirroring the reference output.
        var groups: [MultiSizedGroup: [UInt32: UInt32]] = [:]
        for (file, rendition) in decoded {
            var icon = rendition
            icon.iconIndex = iconIndexOfSize[file.pointSize]
            if file.appearance?.darkLuminosity == true {
                // Dark variant: identical ARGB pixels, key carries
                // UIAppearanceDark (NNW oracle renditions 328/326).
                out.append(icon)
                continue
            }
            if file.appearance?.tintedLuminosity == true {
                // Tinted variant. A neutral source (R = G = B) becomes TWO
                // renditions per idiom: 8-bit gray gamma 22 ('GA8 ', cs 2)
                // and 16-bit extended gray ('GA16', cs 6, key display-gamut
                // P3); the gray channel is the source's luma (NNW oracle: its
                // GA16 pixels equal src16/65535 as half floats). actool
                // dithers the 8-bit encoding; we round instead (at most 1/255
                // on near-black pixels). A colored source stays in color like
                // the base variant: ARGB, plus ARGB-16 under the P3 rule
                // (IceCubes Icon.appiconset oracle).
                if case .bitmap(let body) = icon.body, body.pixelFormat == .bgra8,
                   PNGSource.grayAlpha(premultipliedBGRA: body.pixelsBGRA) != nil {
                    out.append(contentsOf: tintedRenditions(from: icon))
                } else {
                    out.append(icon)
                }
                continue
            }
            out.append(icon)
            addMultiSizedEntry(
                &groups, idiom: file.idiom, subtype: 0,
                pointSize: UInt32(file.pointSize), index: UInt32(icon.iconIndex!)
            )
            if file.idiom == .iphone, file.pointSize == 60, file.scale == 3 {
                // The 90 pt subtype-1792 home icon reuses the 60 pt @3x
                // image verbatim (both are 180 px); only its key differs.
                var large = rendition
                large.scale = .x2
                large.subtype = 1792
                large.iconIndex = iconIndexOfSize[largePhonePointSize]
                out.append(large)
                addMultiSizedEntry(
                    &groups, idiom: .iphone, subtype: 1792,
                    pointSize: UInt32(largePhonePointSize), index: UInt32(large.iconIndex!)
                )
            }
        }
        // Dictionary order is randomized per process; emit groups in key order.
        for (group, entries) in groups.sorted(by: {
            ($0.key.idiom.rawValueByte, $0.key.subtype) < ($1.key.idiom.rawValueByte, $1.key.subtype)
        }) {
            out.append(Rendition(
                name: appIcon.name,
                idiom: group.idiom,
                scale: .x1,
                appearance: nil,
                gamut: nil,
                subtype: group.subtype == 0 ? nil : group.subtype,
                body: .multiSized(MultiSizedBody(
                    sizes: entries.sorted { $0.key < $1.key }.map {
                        MultiSizedBody.Size(pointWidth: $0.key, pointHeight: $0.key, iconIndex: $0.value)
                    }
                ))
            ))
        }
        return out
    }

    private struct MultiSizedGroup: Hashable {
        var idiom: Idiom
        var subtype: UInt16
    }

    /// Builds the two tinted-icon renditions (8-bit and 16-bit gray) from a
    /// decoded ARGB icon rendition. The gray channel is Rec. 709 luma of the
    /// 8-bit source values; the alpha channel passes through.
    private static func tintedRenditions(from base: Rendition) -> [Rendition] {
        guard case .bitmap(var body) = base.body else { return [] }
        let pixelCount = Int(body.width) * Int(body.height)
        precondition(body.pixelsBGRA.count == pixelCount * 4)

        var gray8 = [UInt8]()
        gray8.reserveCapacity(pixelCount * 2)
        var gray16 = [UInt8]()
        gray16.reserveCapacity(pixelCount * 4)
        for pixel in 0..<pixelCount {
            let offset = pixel * 4
            // pixelsBGRA layout: [b, g, r, a] per pixel.
            let blue = Double(body.pixelsBGRA[offset])
            let green = Double(body.pixelsBGRA[offset + 1])
            let red = Double(body.pixelsBGRA[offset + 2])
            let alpha = body.pixelsBGRA[offset + 3]
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            let gray = UInt8(max(0, min(255, luma.rounded())))
            gray8.append(gray)
            gray8.append(alpha)
            // 16-bit extended gray stores half floats (NNW oracle: alpha
            // 0x3C00 = 1.0, gray = value/255 as half). Derived from the
            // 8-bit luma: our decode pipeline is 8-bit, so the extra
            // precision actool gets from 16-bit sources is not recoverable.
            let halfGray = halfBits(Double(gray) / 255.0)
            let halfAlpha = halfBits(Double(alpha) / 255.0)
            gray16.append(UInt8(halfGray & 0xFF))
            gray16.append(UInt8((halfGray >> 8) & 0xFF))
            gray16.append(UInt8(halfAlpha & 0xFF))
            gray16.append(UInt8((halfAlpha >> 8) & 0xFF))
        }

        body.pixelsBGRA = gray8
        body.pixelFormat = .gray8
        body.colorSpaceID = 2
        let gray8Rendition = Rendition(
            name: base.name,
            idiom: base.idiom,
            scale: base.scale,
            appearance: base.appearance,
            gamut: nil,
            subtype: base.subtype,
            iconIndex: base.iconIndex,
            body: .bitmap(body)
        )

        var body16 = body
        body16.pixelsBGRA = gray16
        body16.pixelFormat = .gray16
        body16.colorSpaceID = 6
        let gray16Rendition = Rendition(
            name: base.name,
            idiom: base.idiom,
            scale: base.scale,
            appearance: base.appearance,
            // Keyed display-P3 in the rendition key's gamut slot (NNW
            // oracle: tint16 gamut token 1, tint8 token 0).
            gamut: .displayP3,
            subtype: base.subtype,
            iconIndex: base.iconIndex,
            body: .bitmap(body16)
        )
        return [gray8Rendition, gray16Rendition]
    }

    /// IEEE 754 half-precision bit pattern for a value in [0, 1]. Gray and
    /// alpha come from 8-bit samples, so only 0 and normal-range values
    /// occur, but the conversion is exact for every normal half anyway.
    static func halfBits(_ value: Double) -> UInt16 {
        let bits = Float(max(0, min(1, value))).bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let biased = Int((bits >> 23) & 0xFF)
        let mantissa = UInt16((bits >> 13) & 0x3FF)
        if biased == 0xFF { return sign | 0x7C00 } // inf/NaN: clamp to inf
        let exponent = biased - 127
        if biased == 0 || exponent < -14 { return sign } // zero / underflow to zero
        return sign | UInt16(exponent + 15) << 10 | mantissa
    }

    private static func addMultiSizedEntry(
        _ groups: inout [MultiSizedGroup: [UInt32: UInt32]],
        idiom: Idiom,
        subtype: UInt16,
        pointSize: UInt32,
        index: UInt32
    ) {
        groups[MultiSizedGroup(idiom: idiom, subtype: subtype), default: [:]][pointSize] = index
    }
}
