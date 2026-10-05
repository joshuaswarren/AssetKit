import Foundation

/// Builds the per-rendition CSI ("CTSI") record CoreUI binary-searches at
/// runtime: 184-byte header + TVL metadata block + body bytes.
///
/// Three orchestrators, one per rendition body kind. Each composes a header
/// (`CSIHeader`), a list of TVL entries (`TVLEntry` + `CSITVL`), and a body
/// (`MLECBody` for bitmaps, `DWAREnvelope` for preserved-source, an inline
/// COLR block for color).
enum CSIWriter {
    static func bitmap(name: String, body: BitmapBody, scaleFactor: UInt32) -> Data {
        let fourCCBytes = Array(body.pixelFormat.fourCC.utf8)
        // LE multi-char constant: the first string char lands in the HIGH
        // byte, so the on-disk field reads the string reversed ("ARGB" is
        // stored as 0x41524742, bytes 'B','G','R','A').
        var pixelFormat: UInt32 = 0
        for (index, byte) in fourCCBytes.prefix(4).enumerated() {
            pixelFormat |= UInt32(byte) << (8 * (3 - index))
        }
        // Gray renditions carry actool's gray color-space ids regardless of
        // the body's RGB space: GA8 is gray gamma 22 (2), GA16 is extended
        // gray (6). Verified against the NNW oracle CSI headers.
        let colorSpace: UInt32
        switch body.pixelFormat {
        case .bgra8: colorSpace = UInt32(body.colorSpaceID)
        case .gray8: colorSpace = 2
        case .gray16: colorSpace = 6
        }
        let tvl = CSITVL.encode([
            .bitmapDescriptor(width: body.width, height: body.height),
            .destRect(width: body.width, height: body.height),
            .sliceScale,
            .bitmapFlag,
            .bytesPerRow(width: body.width, bytesPerPixel: body.pixelFormat.bytesPerPixel),
        ])
        let payload = MLECBody.encode(
            width: body.width,
            height: body.height,
            bytesPerPixel: body.pixelFormat.bytesPerPixel,
            pixels: body.pixelsBGRA
        )

        // Native-bitmap category bit (0x10): set for `.image`, cleared for
        // `.appIcon`.
        //
        // Vector-rasterised bitmaps drop the category bit; their flag bits
        // are 0x04 ("raster derived from a vector source"), 0x100 when the
        // vector data is also preserved in the car, and the
        // template-rendering-intent in the low bits (template 0x8,
        // automatic/unspecified 0x10, original none). Verified against the
        // NNW oracle: preserving original-intent sets 0x104, non-preserving
        // ones 0x4, faviconTemplateImage (automatic) 0x14, disclosure
        // (template) 0xc; SVG imagesets keep 0x114 (unspecified intent
        // behaves as automatic). PNG / appicon bitmaps are unchanged.
        let renditionFlags: UInt32
        if body.derivedFromVector {
            let intentBits: UInt32
            switch body.renderingIntent {
            case .template: intentBits = 0x8
            case .original: intentBits = 0x0
            case .automatic, .unspecified: intentBits = 0x10
            }
            renditionFlags = 0x4
                | intentBits
                | (body.preservesVectorRepresentation ? 0x100 : 0)
        } else {
            renditionFlags = (body.kind == .image) ? 0x10 : 0x00
        }

        let header = CSIHeader.encode(
            renditionFlags: renditionFlags,
            width: body.width,
            height: body.height,
            scaleFactor: scaleFactor,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            layout: .bitmapIcon,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// Preserved-source rendition for `.svg` and `.jpg`. The CSI header is
    /// the same shape as for bitmaps (184 bytes) but several fields encode
    /// "not a decoded bitmap": dimensions, scaleFactor (for SVG), and
    /// colorSpace are all zero. The body is a DWAR envelope wrapping the
    /// original source bytes, with LZFSE compression for SVG and raw
    /// passthrough for JPG. Layout, pixelFormat, renditionFlags, and TVL
    /// shape all differ by source format.
    static func preservedSource(body: PreservedSourceBody, scaleFactor: UInt32) -> Data {
        let layout: CSIHeader.Layout
        let pixelFormat: UInt32
        let renditionFlags: UInt32
        let tvl: Data
        let envelope: Data
        switch body.format {
        case .svg:
            layout = .vector
            pixelFormat = CSIHeader.pixelFormatSVG
            // Bit 2 set; this distinguishes the vector category from the
            // generic-image bitmap category (bit 4) in the reference output.
            renditionFlags = 0x04
            // Trimmed TVL for vector renditions: only slice/scale and the
            // bitmap-count flag. Width, height, and bytes-per-row are not
            // meaningful for a scale-free vector source.
            tvl = CSITVL.encode([.sliceScale, .bitmapFlag])
            envelope = DWAREnvelope.encode(flags: 1, payload: LZFSE.encode([UInt8](body.sourceData)))
        case .jpeg(let width, let height):
            layout = .bitmapIcon
            pixelFormat = CSIHeader.pixelFormatJPEG
            // Same bit as generic-image bitmap; JPEG lives in the bitmap
            // category from CoreUI's classification standpoint.
            renditionFlags = 0x10
            // JPG TVL is the bitmap shape with bytes-per-row omitted: stride
            // is a strided-bitmap concept that has no analogue in a JPEG
            // bitstream (CoreUI consumes the JPG by decoding the SOS markers
            // itself).
            tvl = CSITVL.encode([
                .bitmapDescriptor(width: width, height: height),
                .destRect(width: width, height: height),
                .sliceScale,
                .bitmapFlag,
            ])
            envelope = DWAREnvelope.encode(flags: 0, payload: [UInt8](body.sourceData))
        case .pdf:
            // Same shape as SVG (NNW oracle: PDF vector renditions carry
            // flags 0x04, pixelFormat 'PDF ', the trimmed vector TVL, and a
            // DWAR envelope with flags 0 — the raw PDF bytes, uncompressed
            // unlike SVG's LZFSE payload).
            layout = .vector
            pixelFormat = CSIHeader.pixelFormatPDF
            renditionFlags = 0x04
            tvl = CSITVL.encode([.sliceScale, .bitmapFlag])
            envelope = DWAREnvelope.encode(flags: 0, payload: [UInt8](body.sourceData))
        }
        let header = CSIHeader.encode(
            renditionFlags: renditionFlags,
            // Width / height live in TVL 1001 for JPG; the CSI header carries
            // zeros for both preserved-source variants in the reference.
            width: 0,
            height: 0,
            scaleFactor: scaleFactor,
            pixelFormat: pixelFormat,
            colorSpace: 0,
            layout: layout,
            name: body.renditionName,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(envelope.count)
        )
        return header + tvl + envelope
    }

    /// MultiSized icon container (layout 1010). Header dimensions, scale,
    /// pixelFormat and colorSpace are all zero like named colors; TVL is the
    /// same all-zero 1004 + 1006:1 pair. The name is the ASSET name (not a
    /// source filename), and the body lists point sizes — 83.5 pt truncates
    /// to 83, as in the reference output.
    static func multiSized(name: String, body: MultiSizedBody) -> Data {
        let tvl = CSITVL.encode([.colorSlice, .bitmapFlag])
        var w = ByteWriter()
        w.writeLE(UInt32(0x4D53_4953))          // 'MSIS' (file bytes SISM)
        w.writeLE(UInt32(1))                    // version
        w.writeLE(UInt32(body.sizes.count))
        for size in body.sizes {
            w.writeLE(size.pointWidth)
            w.writeLE(size.pointHeight)
            w.writeLE(size.iconIndex)
        }
        let payload = w.data
        let header = CSIHeader.encode(
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 0,
            pixelFormat: 0,
            colorSpace: 0,
            layout: .multiSized,
            name: name,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// Named color, in the layout actool 27.0 writes: header scale, colorSpace
    /// and pixelFormat all zero; TVL (1004: zeros, 1006: 1); one body.
    static func color(name: String, body: ColorBody) -> Data {
        let tvl = CSITVL.encode([.colorSlice, .bitmapFlag])
        let payload = colorBody(body: body)
        let header = CSIHeader.encode(
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 0,
            pixelFormat: 0,
            colorSpace: 0,
            layout: .namedColor,
            name: name,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(payload.count)
        )
        return header + tvl + payload
    }

    /// 'COLR' as an LE multi-char constant (file bytes R,L,O,C), version 1,
    /// colorSpaceID, component count, then Float64 components. Components
    /// arrive in actool's final precision (parsed through Float32 in
    /// `Contents.Components.parse`), so they are written verbatim; the
    /// system-color fallback below keeps its own Float32 pass because its
    /// placeholder decimals were transcribed from Apple's output.
    private static func colorBody(body: ColorBody) -> Data {
        var w = ByteWriter()
        w.writeLE(UInt32(0x434F_4C52))
        w.writeLE(UInt32(1))                    // version
        if let name = body.systemName {
            w.writeLE(body.systemColorSpaceID)  // system space + 0x100 flag
            w.writeLE(UInt32(body.components.count))
            for component in body.components {
                w.writeLE(Double(Float(component)).bitPattern)
            }
            w.writeLE(UInt32(0x434F_4C52))
            w.writeLE(UInt32(1))
            w.writeLE(UInt32(name.utf8.count))
            w.write(Array(name.utf8))
            return w.data
        }
        w.writeLE(UInt32(body.colorSpaceID))    // colorSpaceID with flag bits
        w.writeLE(UInt32(body.components.count))
        for component in body.components {
            w.writeLE(component.bitPattern)
        }
        return w.data
    }
}
