import Foundation

/// Produces PNG bytes from a PDF source at a requested pixel size, plus the
/// page's point dimensions (media/crop box) that drive the 1x/2x/3x fan-out.
///
/// Like `SVGRasterizer` this is caller-injectable so the library stays
/// dependency-light. The default implementation `PdftoCairoRasterizer`
/// shells out to `pdfinfo` and `pdftocairo` from poppler (Arch package
/// `poppler`, Debian/Ubuntu `poppler-utils`, Fedora `poppler-utils`,
/// macOS `brew install poppler`).
public protocol PDFRasterizer: Sendable {
    /// The first page's dimensions in PDF points (1 pt = 1/72 inch).
    /// Apple's actool rounds `points × scale` per axis to derive each
    /// bitmap's pixel grid; the rasteriser must be able to reproduce that
    /// grid exactly.
    func dimensions(pdfData: Data) throws -> (width: Double, height: Double)

    /// Rasterises `pdfData`'s first page to a PNG of exactly
    /// `pixelWidth × pixelHeight` pixels with transparent background.
    /// Throws if rasterisation fails; the compiler wraps the error into
    /// `XCAssetCompilerError.pdfRasterizationFailed`.
    func rasterize(pdfData: Data, pixelWidth: UInt32, pixelHeight: UInt32) throws -> Data
}

/// Default `PDFRasterizer` implementation on top of poppler's CLI tools.
public struct PdftoCairoRasterizer: PDFRasterizer {
    /// Directory for the temporary input file. Both poppler tools want a
    /// real file path (`pdfinfo -` is not dependable across versions).
    private let temporaryDirectory: URL

    /// Absolute path of the `env`-style launcher, mirroring
    /// `RsvgConvertRasterizer.executablePath`.
    private let executablePath: String

    public init(executablePath: String = "/usr/bin/env", temporaryDirectory: URL? = nil) {
        self.executablePath = executablePath
        self.temporaryDirectory = temporaryDirectory
            ?? URL(fileURLWithPath: FileManager.default.temporaryDirectory.path)
    }

    public func dimensions(pdfData: Data) throws -> (width: Double, height: Double) {
        try withTemporaryPDF(pdfData) { path in
            let output = String(decoding: try run(["pdfinfo", path]), as: UTF8.self)
            // Single-page PDFs print a "Page size:" summary; multi-page
            // ones print per-page "Page N size:" lines instead. Prefer
            // page 1's entry.
            let lines = output.split(separator: "\n").map(String.init)
            let candidates = lines.filter { $0.hasPrefix("Page 1 size:") }
                .last.map { [$0] } ?? lines.filter { $0.hasPrefix("Page size:") }
            for line in candidates {
                let numbers = line.split(whereSeparator: { !$0.isNumber && $0 != "." })
                    .compactMap { Double($0) }
                if numbers.count >= 2 {
                    return (numbers[0], numbers[1])
                }
            }
            throw RasterizationError("pdfinfo output has no 'Page size' line:\n\(output)")
        }
    }

    public func rasterize(pdfData: Data, pixelWidth: UInt32, pixelHeight: UInt32) throws -> Data {
        try withTemporaryPDF(pdfData) { path in
            // -transp keeps the page background transparent (RGBA PNG);
            // -scale-to-x/-y request the exact pixel grid. poppler rounds
            // page pixels up (ceil) for fractional page boxes, so the
            // decoded image can come back one pixel larger per axis;
            // PDFSource crops the overflow down to the requested grid.
            // pdftocairo has no stdout mode; it takes the output root and
            // appends ".png", so give it one in the temporary directory.
            let root = temporaryDirectory
                .appendingPathComponent("assetkit-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: root + ".png") }
            _ = try run([
                "pdftocairo", "-png", "-singlefile", "-transp",
                "-f", "1", "-l", "1",
                "-scale-to-x", "\(pixelWidth)",
                "-scale-to-y", "\(pixelHeight)",
                path, root,
            ])
            return try Data(contentsOf: URL(fileURLWithPath: root + ".png"))
        }
    }

    private func withTemporaryPDF<T>(
        _ pdfData: Data, _ body: (String) throws -> T
    ) throws -> T {
        let input = temporaryDirectory
            .appendingPathComponent("assetkit-\(UUID().uuidString).pdf")
        try pdfData.write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        do {
            return try body(input.path)
        } catch let error as RasterizationError {
            throw error
        } catch {
            throw RasterizationError("\(error)")
        }
    }

    private func run(_ toolArguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var arguments: [String] = []
        if (executablePath as NSString).lastPathComponent == "env" {
            arguments.append(toolArguments[0])
        }
        arguments.append(contentsOf: toolArguments.dropFirst())
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw RasterizationError(
                "Could not launch \(toolArguments[0]) via \(executablePath); "
                + "install poppler (Arch: `pacman -S poppler`, Debian/Ubuntu: "
                + "`apt install poppler-utils`, macOS: `brew install poppler`), "
                + "or supply an alternative PDFRasterizer. Underlying error: \(error)"
            )
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RasterizationError(
                "\(toolArguments[0]) exited \(process.terminationStatus): "
                + String(decoding: stderr, as: UTF8.self)
            )
        }
        return stdout
    }

    /// Internal error type; the compiler wraps these into
    /// `XCAssetCompilerError.pdfRasterizationFailed`.
    private struct RasterizationError: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }
}
