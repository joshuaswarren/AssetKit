# AssetKit

A clean-room Swift implementation of Apple's `actool` that compiles `.xcassets` catalogs into the `Assets.car` file format.

Targets CoreUI 970 (Xcode 26 / iOS 16+). See [docs/coreui-970-format.md](docs/coreui-970-format.md) for the format reference.

## Usage

```swift
.package(url: "https://github.com/xtool-org/AssetKit", .upToNextMinor(from: "1.0.0")),
```

```swift
import AssetKit

// `svgRasterizer` defaults to `RsvgConvertRasterizer()`, which shells out
// to `rsvg-convert` (install with `apt install librsvg2-tools`,
// `dnf install librsvg2-tools`, or `brew install librsvg`). Replace it
// with your own `SVGRasterizer` if you'd rather not depend on a system
// binary. `pdfRasterizer` works the same way: the default
// `PdftoCairoRasterizer()` shells out to poppler's `pdfinfo` and
// `pdftocairo` (Arch `poppler`, Debian/Ubuntu `poppler-utils`,
// macOS `brew install poppler`).
let compiler = XCAssetCompiler(deploymentTarget: "16.0")
let result = try await compiler.compile(catalog: catalogURL)

try result.carData.write(to: outputURL.appendingPathComponent("Assets.car"))

if let bundle = result.appIconBundle {
    // Merge bundle.infoPlistAdditions into the app's Info.plist
    // Write each bundle.looseFiles entry into the bundle root for SpringBoard's
    // icon-render fallback path
}
```

## What it supports

- `.imageset`
  - PNG sources (1x/2x/3x scales, sRGB and display-P3, dark/light appearances)
  - SVG sources, each emitted as one preserved vector rendition (XML kept verbatim, LZFSE-compressed inside a DWAR envelope) plus three rasterised bitmap fallbacks at 1x/2x/3x (because `UIImage(named:)` reads the rasterised fallbacks; the vector rendition is what other CoreUI consumers and future iOS versions may prefer). Rasterisation is delegated to an injectable `SVGRasterizer`; the default shells out to `rsvg-convert`.
  - JPG sources stored as preserved raw renditions (JPEG bytes passed through; original compression preserved)
  - PDF sources, each emitted as one preserved vector rendition (PDF bytes kept raw inside a DWAR envelope, `'PDF '` pixelFormat) plus three rasterised bitmap fallbacks at `round(page points × scale)` — the Xcode 27.0 shapes verified against the NetNewsWire oracle. Neutral-content (DeviceGray) pages compile to gray gamma 22; `preserves-vector-representation` moves the vector rendition between the vector part (scale 1) and the generic-image part (scale 0); `template-rendering-intent` lands in the bitmap renditionFlags. Rasterisation is delegated to an injectable `PDFRasterizer`; the default (`PdftoCairoRasterizer`) shells out to poppler's `pdfinfo` and `pdftocairo` (Arch: `pacman -S poppler`, Debian/Ubuntu: `apt install poppler-utils`, macOS: `brew install poppler`).
- `.colorset` (sRGB and display-P3, hex or float components, dark/light appearances)
- `.appiconset` (per-idiom and per-size, with the loose-PNG fallback that SpringBoard expects alongside `Assets.car`). PNG sources only; SVG/JPG/PDF are rejected because SpringBoard's icon-render pipeline requires PNG.

## What it deliberately doesn't support

- Multi-rendition fanout — actool emits multiple compression variants per asset (`deepmap-lzfse`, `deepmap2`, `palette-img`); this writer emits one rendition per `(idiom, scale, appearance)` tuple per source format. Sufficient for iOS 16+.
- Data sets, sticker sets, AR reference objects
- macOS / tvOS / watchOS asset variants beyond what the structural attribute IDs encode

These can be added; the format mechanisms in `Sources/AssetKit/CAR/` are general enough.

## Compression

Bitmap renditions are compressed with LZFSE on every platform via a vendored
copy of Apple's reference encoder (`Sources/CLZFSE/`, BSD 3-Clause). CAR
output is byte-deterministic across Linux and macOS.

## Tests

```sh
swift test
```

The test suite includes a macOS-only gate (`AssetutilParseTests`) that compiles a fixture catalog and verifies Apple's own `xcrun assetutil --info` parses the bytes and reports the expected rendition fields. This is the durable verification for CoreUI format compatibility and gates merges via CI.

## License

MIT. See [LICENSE](LICENSE).
