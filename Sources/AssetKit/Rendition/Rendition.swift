import Foundation

struct Rendition: Sendable {
    enum Body: Sendable {
        case bitmap(BitmapBody)
        case color(ColorBody)
        case preservedSource(PreservedSourceBody)
        case multiSized(MultiSizedBody)
        /// Symbol-set renditions (`.symbolset`): the vector glyph CoreUI
        /// renders at any point size, and the pre-rasterised cache entries
        /// keyed per (scale, cached size).
        case symbolVector(SymbolVectorBody)
        case symbolCached(SymbolCachedBody)
        /// Per-scale atlas holding the cached bitmaps of one symbol
        /// (ZZZZPackedAsset, element 9 / part 181).
        case symbolPacked(SymbolPackedBody)
        case namedGradient(NamedGradientBody)
        case iconGroup(IconGroupBody)
        case iconImageStack(IconImageStackBody)
    }

    var name: String
    var idiom: Idiom
    var scale: Scale?
    var appearance: Appearance?
    var gamut: Gamut?
    /// True when the rendition was synthesized from an Icon Composer `.icon`
    /// source. Selects actool's icon-composer BITMAPKEYS descriptors
    /// (marker 0x02) for the asset regardless of rendition category.
    var iconComposerSource: Bool = false
    /// Raw rendition-key subtype token. Non-zero only for icon variants
    /// keyed on a device trait — actool keys the 90 pt large-phone home icon
    /// (derived from the 60 pt @3x slot) at subtype 1792.
    var subtype: UInt16? = nil
    /// App-icon "Icon Index": the rank of this rendition's point size among
    /// the appiconset's distinct point sizes, ascending. Only icon renditions
    /// carry it; assetutil surfaces it as "Icon Index".
    var iconIndex: UInt16? = nil
    /// Deployment-target key token. Symbol renditions are keyed at the OS
    /// version that introduced symbol sets (token 5, assetutil
    /// "DeploymentTarget": "2019"); every other rendition kind leaves the
    /// slot zero (Apple NNW oracle: only symbol and their packed renditions
    /// carry 5).
    var deploymentTarget: UInt16? = nil
    var body: Body
}

/// Vector-glyph rendition of a `.symbolset` (CoreUI part 59, CSI layout
/// 1017, pixelFormat 'SVG '). The body is a DWAR(LZFSE(SVG)) envelope of a
/// rewritten template layer.
struct SymbolVectorBody: Sendable {
    /// Glyph-weight key token (Regular = 4, the only weight NNW's template
    /// carries; token = the weight's rank in actool's weight list).
    var glyphWeight: UInt16
    /// Glyph-size key token: 1 Small, 2 Medium, 3 Large.
    var glyphSize: UInt16
    /// Name-identifier token (CRC32 of the asset name & 0xFFFF).
    var identifier: UInt16
    /// Font metrics at the 17 pt reference size, from the template Guides
    /// (baseline below the drawing bottom, cap height, side margins),
    /// scaled by 17/100.
    var baseline: Float
    var capline: Float
    var leftMargin: Float
    var rightMargin: Float
    /// The (cachedIndex, pointSize) pairs of TVL 1018. Only the Medium
    /// vector carries them (Apple two-symbol oracle: Small/Large vectors
    /// omit the pair list).
    var availableSizes: [(index: UInt32, pointSize: UInt32)]?
    /// Rewritten template-layer SVG (Apple serializer format).
    var svg: Data
    /// The template SVG filename for the CSI name field.
    var renditionName: String
}

/// Pre-rasterised symbol cache entry (part 181, CSI layout 1003,
/// pixelFormat 'GA8 ', no inline pixels — CoreUI resolves the pixel data
/// through the TVL-1010 link to the packed atlas).
struct SymbolCachedBody: Sendable {
    var glyphWeight: UInt16
    var glyphSize: UInt16
    /// Glyph Cached Index (0..2) — the dimension2 key token.
    var cachedIndex: UInt16
    var identifier: UInt16
    var width: UInt32
    var height: UInt32
    /// Placement inside the (unemitted) packed atlas.
    var atlasX: UInt32 = 0
    var atlasY: UInt32 = 0
    /// RenditionName for the CSI name field (the template SVG filename).
    var renditionName: String
}

/// Per-scale symbol cache atlas (CoreUI element 9 / part 181, CSI layout
/// 1004, 'GA8 ' pixels as a dmp2 record — the same pixel encoding as
/// bitmap renditions).
struct SymbolPackedBody: Sendable {
    var width: UInt32
    var height: UInt32
    /// Interleaved gray+alpha bytes (gray plane zero: template glyphs are
    /// black; alpha carries the coverage).
    var pixelsGA: [UInt8]
    /// The atlas scale factor (1, 2, 3).
    var scale: UInt16
    /// Rendition name, e.g. "ZZZZPackedAsset-1.0.1-gamut0".
    var renditionName: String
}

/// Body of a MultiSized icon rendition (CSI layout 1010, 'MSIS' payload).
/// actool emits one per (idiom, subtype) group of icon renditions; each
/// entry maps a point size to the Icon Index of the bitmap rendition that
/// satisfies it. Widths/heights are point sizes (83.5 pt truncates to 83,
/// as in the reference output).
struct MultiSizedBody: Sendable {
    struct Size: Sendable {
        var pointWidth: UInt32
        var pointHeight: UInt32
        var iconIndex: UInt32
    }

    /// One entry per distinct point size, ascending.
    var sizes: [Size]
}

struct BitmapBody: Sendable {
    /// Which CoreUI rendition category this bitmap belongs to. Determines the
    /// `(element, part)` pair we encode in the rendition key and FACETKEYS
    /// value -- actool picks different codes for appicons vs. generic images,
    /// and UIImage(named:) only finds renditions whose part matches the
    /// expected category for the lookup path.
    enum Kind: Sendable {
        /// `element=85, part=220`. Used by SpringBoard's icon-render pipeline.
        case appIcon
        /// `element=85, part=181`. Used by UIImage(named:) for generic image
        /// assets from an `.imageset`.
        case image
    }

    var width: UInt32
    var height: UInt32
    var pixelsBGRA: [UInt8]
    var colorSpaceID: UInt8
    var kind: Kind
    /// Pixel encoding of the CSI record and its MLEC payload. Tinted icon
    /// variants are stored as gray+alpha: actool writes one 8-bit
    /// gray-gamma-22 rendition and one 16-bit extended-gray (P3) rendition
    /// per idiom (NNW oracle CSI: pixfmt 'GA8 ' cs=2, 'GA16' cs=6).
    enum PixelFormat: Sendable {
        /// 'ARGB', colorSpaceID as carried (sRGB = 1), 4 bytes/pixel.
        case bgra8
        /// 'GA8 ', colorSpace 2 (gray gamma 22), 2 bytes/pixel (gray, alpha).
        /// `pixelsBGRA` holds the already-converted interleaved gray+alpha
        /// bytes when this format is selected.
        case gray8
        /// 'GA16', colorSpace 6 (extended gray), 4 bytes/pixel (gray half,
        /// alpha half). `pixelsBGRA` holds the interleaved little-endian
        /// half-float pairs when this format is selected.
        case gray16
        /// 'RGBW' as an LE constant (file bytes W,B,G,R), colorSpace 4
        /// (extended sRGB), 8 bytes/pixel (b, g, r, a half-floats, each
        /// little-endian). The 16-bit rendition actool 27.0 emits beside the
        /// 8-bit downconvert for 16-bit sources (IceCubes oracle: assetutil
        /// Encoding 'ARGB-16', DisplayGamut P3).
        case argb16

        var fourCC: String {
            switch self {
            case .bgra8: return "ARGB"
            case .gray8: return "GA8 "
            case .gray16: return "GA16"
            case .argb16: return "RGBW"
            }
        }

        var bytesPerPixel: UInt32 {
            switch self {
            case .bgra8: return 4
            case .gray8: return 2
            case .gray16: return 4
            case .argb16: return 8
            }
        }
    }

    var pixelFormat: PixelFormat = .bgra8
    /// True iff this bitmap was rasterised from a vector source (SVG, PDF)
    /// rather than supplied directly as bitmap pixels. The reference actool
    /// output tags vector-rasterised bitmaps with extra bits in the CSI
    /// header's `renditionFlags`; some CoreUI runtime paths branch on this
    /// classification (e.g. when re-rasterising via the preserved vector
    /// source at a non-intrinsic size). PNG / appicon bitmaps leave it false.
    var derivedFromVector: Bool = false
    /// Whether the source's vector data is also preserved in the car
    /// (imageset `preserves-vector-representation`). With
    /// `derivedFromVector` this selects the CSI renditionFlags 0x100 bit:
    /// PDF bitmaps of a preserving imageset carry 0x104, a non-preserving
    /// one plain 0x4 (NNW oracle). SVG sources always preserve.
    var preservesVectorRepresentation: Bool = true
    /// The imageset's `template-rendering-intent`. Encoded into the CSI
    /// renditionFlags low bits of vector-rasterised bitmaps (template 0x8,
    /// automatic/unspecified 0x10, original none — NNW oracle: disclosure
    /// 0xc, faviconTemplateImage 0x14, original-intent sets 0x4/0x104).
    enum RenderingIntent: Sendable {
        case unspecified
        case template
        case automatic
        case original
    }

    var renderingIntent: RenderingIntent = .unspecified
    /// The source filename (e.g. "icon@2x.png"). Stored in the CSI header's
    /// 128-char name field; actool uses the filename here, not the asset name.
    var renditionName: String
}

extension BitmapBody {
    /// Every alpha sample is full. Selects the MLEC opaque flag (assetutil
    /// "Opaque"); half-float formats compare against 1.0 = 0x3C00.
    var isOpaque: Bool {
        let p = pixelsBGRA
        switch pixelFormat {
        case .bgra8: return stride(from: 3, to: p.count, by: 4).allSatisfy { p[$0] == 0xFF }
        case .gray8: return stride(from: 1, to: p.count, by: 2).allSatisfy { p[$0] == 0xFF }
        case .gray16: return stride(from: 2, to: p.count, by: 4).allSatisfy { p[$0] == 0x00 && p[$0 + 1] == 0x3C }
        case .argb16: return stride(from: 6, to: p.count, by: 8).allSatisfy { p[$0] == 0x00 && p[$0 + 1] == 0x3C }
        }
    }
}

struct ColorBody: Sendable {
    /// Components in the color space's own order — RGB spaces carry 4
    /// (r, g, b, a), gray spaces carry 2 (white, alpha). actool quantizes
    /// each to Float32 before storing it in the COLR body's Float64 slots
    /// (verified: Xcode 27.0 writes 1.1 as 0x3FF19999A0000000).
    var components: [Double]
    /// COLR colorspace ID. actool 27.0 maps: srgb 1, gray-gamma-22 2,
    /// display-p3 3, extended-srgb 4, extended-linear-srgb 5, extended-gray 6;
    /// the gray fallback for system colors carries 0x102.
    var colorSpaceID: UInt8
    /// System color name ("labelColor"). The components then hold the
    /// per-appearance fallback for that system color (see
    /// `SystemColorPlaceholders`).
    var systemName: String? = nil
    /// COLR colorspace ID for the system-color fallback body: the color's
    /// own space with the 0x100 system flag (0x101 srgb, 0x102 gray-gamma-22,
    /// 0x104 extended-srgb, 0x106 extended-gray). Only read when
    /// `systemName` is set.
    var systemColorSpaceID: UInt32 = 0x102
}

/// Source file kept verbatim inside a DWAR envelope rather than rasterised
/// or re-encoded. Used for `.svg` (LZFSE-compressed XML inner payload) and
/// `.jpg` (raw JPEG inner payload). The source-format distinction is carried
/// in the surrounding CSI header's `pixelFormat` and in `Format` below.
struct PreservedSourceBody: Sendable {
    /// Source format plus the per-format data CoreUI needs alongside the
    /// raw bytes. JPEG carries decoded pixel dimensions (populated by
    /// `JPEGDimensions` and emitted into TVL types 1001 / 1003); SVG carries
    /// nothing extra (vector is scale-free and the reference Assets.car
    /// leaves the dimension TVL entries out for SVG renditions). Keeping
    /// these in the enum makes it unrepresentable to construct a JPEG body
    /// without dimensions.
    enum Format: Sendable {
        case svg
        case jpeg(width: UInt32, height: UInt32)
        /// HEIC/HEIF source preserved verbatim. Like JPEG, the TVL carries
        /// the decoded pixel dimensions (sniffed from the decoder's PNG
        /// output, populated by `HEICSource`).
        case heif(width: UInt32, height: UInt32)
        /// PDF source. `preservesVector` mirrors the imageset's
        /// `preserves-vector-representation`: it selects the rendition key
        /// slot — the dedicated vector part at scale 1 when preserved, the
        /// generic-image part at scale 0 when not (NNW oracle: assetutil
        /// Vector rows without Scale for the latter).
        case pdf(preservesVector: Bool)
    }

    var format: Format
    /// The user-provided source bytes, unmodified. For SVG this is the raw
    /// XML; for JPG this is the entire JPEG file including JFIF / EXIF
    /// segments.
    var sourceData: Data
    /// The source filename (e.g. "Svg.svg", "Jpg@2x.jpg"). Stored in the
    /// CSI header's 128-char name field; actool uses the filename here, not
    /// the asset name.
    var renditionName: String
}
