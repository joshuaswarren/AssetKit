import Foundation

/// Produces PNG bytes from HEIC/HEIF source data at the image's full pixel
/// size.
///
/// xcasset-compiler does not ship its own HEIF decoder: the container is
/// ISO-BMFF over HEVC (or AV1) bitstreams, and any vendored decoder would
/// re-implement a substantial chunk of it. The default implementation shells
/// out to `heif-convert` from libheif (Arch: `pacman -S libheif`), mirroring
/// how SVG and PDF sources shell out to `rsvg-convert` and `pdftocairo`.
/// Replace it by passing a different `HEICDecoder` to `XCAssetCompiler.init`.
public protocol HEICDecoder: Sendable {
    /// Decodes HEIC/HEIF bytes to PNG bytes at the image's full pixel size.
    /// Throws if decoding fails for any reason; the caller wraps the
    /// underlying error into `XCAssetCompilerError.heicDecodeFailed` before
    /// surfacing it to the user.
    func decodeToPNG(heicData: Data) throws -> Data
}

/// Default `HEICDecoder`: writes the source to a temp file, runs
/// `heif-convert`, and reads the PNG it writes next to it. libheif applies
/// the container's irot/imir transforms, so the PNG is orientation-corrected.
public struct HeifConvertDecoder: HEICDecoder {
    /// Absolute path to the `heif-convert` binary. Defaults to letting
    /// `/usr/bin/env` resolve it from `PATH`.
    public var executablePath: String

    public init(executablePath: String = "/usr/bin/env") {
        self.executablePath = executablePath
    }

    public func decodeToPNG(heicData: Data) throws -> Data {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("assetkit-heic-\(UUID().uuidString)")
        let input = temp.appendingPathExtension("heic")
        let output = temp.appendingPathExtension("png")
        let fm = FileManager.default
        defer {
            try? fm.removeItem(at: input)
            try? fm.removeItem(at: output)
        }
        try heicData.write(to: input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        // heif-convert takes input and output paths; the output format
        // follows the output file extension.
        var arguments: [String] = []
        if (executablePath as NSString).lastPathComponent == "env" {
            arguments.append("heif-convert")
        }
        arguments.append(contentsOf: [input.path, output.path])
        process.arguments = arguments
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DecodeError(
                "Could not launch heif-convert via \(executablePath); "
                + "install libheif (`pacman -S libheif`), or supply an "
                + "alternative HEICDecoder. Underlying error: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            throw DecodeError("heif-convert exited \(process.terminationStatus): "
                + String(decoding: stderr, as: UTF8.self))
        }
        return try Data(contentsOf: output)
    }

    /// Internal error type thrown by decoder steps. The catalog compiler
    /// catches anything thrown by a `HEICDecoder.decodeToPNG` call and wraps
    /// the description into `XCAssetCompilerError.heicDecodeFailed`, so the
    /// specific shape of this type is implementation detail.
    private struct DecodeError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}

/// HEIC/HEIF source handler (iPhone photos, IceCubes' avatar.imageset).
/// Apple's actool emits TWO renditions per HEIC source (Xcode 27.0 oracle,
/// avatar probe): the source file preserved inside a DWAR envelope as a
/// 'HEIF' rendition keyed at the deployment target that introduced CoreUI
/// HEIF decoding, plus a decoded bitmap rendition for lookups elsewhere.
/// CoreUI prefers the HEIF rendition at runtime and falls back to the
/// bitmap. PNG and JPEG sources have no such pair — one rendition each.
enum HEICSource {
    struct Context {
        var assetName: String
        var idiom: Idiom
        var scale: Scale?
        var appearance: Appearance?
        var gamut: Gamut
        var filename: String
        var kind: BitmapBody.Kind
    }

    /// HEIF rendition key: actool keys it at the OS token for iOS 11, the
    /// release that shipped HEIF decoding (avatar oracle: rendition key
    /// deployment-target token 2, assetutil "DeploymentTarget": "2017";
    /// the symbol oracle's iOS 13 token is 5 in the same slot).
    static let heifDeploymentTargetToken: UInt16 = 2

    static func renditions(bytes: Data, context: Context, decoder: any HEICDecoder) throws -> [Rendition] {
        let png: Data
        do {
            png = try decoder.decodeToPNG(heicData: bytes)
        } catch {
            throw XCAssetCompilerError.heicDecodeFailed(asset: context.assetName, filename: context.filename, underlying: String(describing: error))
        }
        var dims: (width: UInt32, height: UInt32) = (0, 0)
        do {
            dims = try pngDimensions(png)
        } catch {
            throw XCAssetCompilerError.heicDecodeFailed(asset: context.assetName, filename: context.filename, underlying: String(describing: error))
        }
        var out: [Rendition] = try PNGSource.renditions(bytes: png, context: .init(
            assetName: context.assetName,
            idiom: context.idiom,
            scale: context.scale,
            appearance: context.appearance,
            gamut: context.gamut,
            filename: context.filename,
            kind: context.kind
        ))
        out.append(Rendition(
            name: context.assetName,
            idiom: context.idiom,
            scale: context.scale,
            appearance: context.appearance,
            gamut: nil,
            deploymentTarget: heifDeploymentTargetToken,
            body: .preservedSource(PreservedSourceBody(
                format: .heif(width: dims.width, height: dims.height),
                sourceData: bytes,
                renditionName: context.filename
            ))
        ))
        return out
    }

    /// PNG IHDR dimensions: signature (8) + length (4) + "IHDR" (4) + width
    /// (4) + height (4). The decoder returns a fresh PNG, so the header is
    /// always well-formed from libheif's writer; still, verify the magic to
    /// catch a decoder that returned something else entirely.
    static func pngDimensions(_ png: Data) throws -> (width: UInt32, height: UInt32) {
        let bytes = [UInt8](png)
        guard bytes.count >= 24,
              bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
              bytes[12] == 0x49, bytes[13] == 0x48, bytes[14] == 0x44, bytes[15] == 0x52
        else {
            throw MalformedPNG("HEIC decoder did not return a PNG")
        }
        func be32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
        }
        return (be32(16), be32(20))
    }

    private struct MalformedPNG: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
