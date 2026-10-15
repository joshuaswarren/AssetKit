import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parses an SF Symbol template SVG (the Ultralight/…/Black-S/M/L layer
/// sheet Apple's Symbol Maker exports) and re-serialises one layer exactly
/// the way actool embeds it in a vector-glyph rendition.
///
/// Apple's rewrite (verified byte-for-byte against Xcode 27.0 output for
/// NetNewsWire's markAllAsRead and markAboveAsRead):
/// * XML declaration, then `<svg version="1.1" viewBox="0 0 W H">` where
///   W/H are the layer's bounding box (half the stroke width expands
///   stroked subtrees) scaled by 17/100, printed with `%g`.
/// * One `<g id="s" transform="matrix(0.17 0 0 0.17 TX TY)">` wrapper; the
///   translation shifts the bbox minimum to the origin. The LAYER group's
///   own translate is dropped; deeper nested group translates survive
///   verbatim.
/// * Paths become self-closing `<path d="…"/>` with `id` moved last and
///   path numbers re-printed with `%g`, single-space separators omitted
///   before negative numbers and command letters.
public enum SymbolTemplate {
    struct Node {
        var id: String?
        /// `translate(dx, dy)` of this group, if any.
        var translation: (dx: Double, dy: Double)?
        /// Stroke expansion (half the group's stroke-width) for bounds.
        var strokeHalfWidth: Double
        /// Path data (`d`), nil for groups.
        var pathData: String?
        /// Source attributes in order, excluding `d` and `id`.
        var attributes: [(name: String, value: String)]
        var children: [Node]
    }

    struct Layer {
        /// 1 Small, 2 Medium, 3 Large — from the `-S`/`-M`/`-L` suffix.
        var sizeClass: Int
        /// Glyph-weight key token from the layer id prefix (`Regular-S` is
        /// 4, `Ultralight-S` 1, `Black-S` 9): the weight's rank in actool's
        /// list. Layers of one size class differ only by this token.
        var weight: UInt16
        var children: [Node]
        /// The layer group's own translate (dropped in the rewrite but
        /// needed to place the drawing relative to the guides).
        var translation: (dx: Double, dy: Double)
    }

    struct Parsed {
        var layers: [Layer]
        /// Baseline distance above the Symbols-group origin, in template
        /// units, per size class (the `Baseline-{S,M,L}` guide lines).
        var baselineOffset: [Int: Double]
        /// Cap height per size class: baseline line minus capline line.
        var capHeight: [Int: Double]
        var filename: String
    }

    enum SymbolError: Error, CustomStringConvertible {
        case noSymbolsGroup(asset: String)
        case noLayers(asset: String)
        case noGuides(asset: String)

        var description: String {
            switch self {
            case .noSymbolsGroup(let asset):
                return "Symbol template for '\(asset)' has no <g id=\"Symbols\"> layer group"
            case .noLayers(let asset):
                return "Symbol template for '\(asset)' has no -S/-M/-L layers under Symbols"
            case .noGuides(let asset):
                return "Symbol template for '\(asset)' has no Guides group (baseline/capline lines)"
            }
        }
    }

    /// Layer-id weight prefix to glyph-weight key token (Apple's IceCubes
    /// rocket oracle keys Ultralight 1, Regular 4, Black 9).
    static let weightTokens: [String: UInt16] = [
        "Ultralight": 1, "Thin": 2, "Light": 3, "Regular": 4, "Medium": 5,
        "Semibold": 6, "Bold": 7, "Heavy": 8, "Black": 9,
    ]

    // MARK: Parsing

    static func parse(_ data: Data, asset: String, filename: String) throws -> Parsed {
        let delegate = ParserDelegate(asset: asset)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SymbolError.noSymbolsGroup(asset: asset)
        }
        guard let symbols = delegate.symbols else {
            throw SymbolError.noSymbolsGroup(asset: asset)
        }
        let layers = symbols.children.compactMap { node -> Layer? in
            guard let id = node.id, let separator = id.lastIndex(of: "-"),
                  let weight = weightTokens[String(id[..<separator])] else { return nil }
            let sizeClass: Int
            switch id.last {
            case "S": sizeClass = 1
            case "M": sizeClass = 2
            case "L": sizeClass = 3
            default: return nil
            }
            return Layer(
                sizeClass: sizeClass,
                weight: weight,
                children: node.children,
                translation: node.translation ?? (0, 0)
            )
        }
        guard !layers.isEmpty else {
            throw SymbolError.noLayers(asset: asset)
        }
        guard !delegate.baselineY.isEmpty, !delegate.caplineY.isEmpty else {
            throw SymbolError.noGuides(asset: asset)
        }
        var baselineOffsets: [Int: Double] = [:]
        var capHeights: [Int: Double] = [:]
        for (sizeClass, baseline) in delegate.baselineY {
            baselineOffsets[sizeClass] =
                (delegate.guidesTranslation.dy + baseline) - delegate.symbolsTranslation.dy
            if let capline = delegate.caplineY[sizeClass] {
                capHeights[sizeClass] = baseline - capline
            }
        }
        return Parsed(
            layers: layers,
            baselineOffset: baselineOffsets,
            capHeight: capHeights,
            filename: filename
        )
    }

    private final class ParserDelegate: NSObject, XMLParserDelegate {
        let asset: String
        var symbols: Node?
        var symbolsTranslation = (dx: 0.0, dy: 0.0)
        var guidesTranslation = (dx: 0.0, dy: 0.0)
        var baselineY: [Int: Double] = [:]
        var caplineY: [Int: Double] = [:]

        private var stack: [Node] = []

        init(asset: String) {
            self.asset = asset
        }

        func parser(
            _ parser: XMLParser,
            didStartElement name: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attrs: [String: String]
        ) {
            let id = attrs["id"]
            let translation = attrs["transform"].flatMap(parseTranslate)
            let strokeHalf = parseStrokeHalfWidth(attrs)

            if name == "g", id == "Symbols" {
                symbolsTranslation = translation ?? (0, 0)
            }
            if name == "g", id == "Guides" {
                guidesTranslation = translation ?? (0, 0)
            }
            // Guides are <line y1=…> (SF Symbols app) or <path d="M x,y l…"> (template v3.0 exporters
            // such as SwiftDraw, used by Mastodon).
            if name == "line" || name == "path", let id,
               id.hasPrefix("Baseline-") || id.hasPrefix("Capline-"),
               let sizeClass = ["S": 1, "M": 2, "L": 3][String(id.suffix(1))],
               let y = name == "line" ? attrs["y1"].flatMap(Double.init) : attrs["d"].flatMap(guideY) {
                if id.hasPrefix("Baseline-") { baselineY[sizeClass] = y } else { caplineY[sizeClass] = y }
            }

            if name == "path" {
                // Apple's rewrite keeps editor attributes under their local name, after the plain ones
                // (IceCubes' rocket.fill: `sodipodi:nodetypes` becomes a trailing `nodetypes`).
                let attributes = attrs.filter { $0.key != "d" && $0.key != "id" }
                    .sorted { ($0.key.contains(":") ? 1 : 0, $0.key) < ($1.key.contains(":") ? 1 : 0, $1.key) }
                    .map { (name: String($0.key.split(separator: ":").last!), value: $0.value) }
                push(Node(id: id, translation: translation, strokeHalfWidth: strokeHalf, pathData: attrs["d"], attributes: attributes, children: []))
                return
            }
            if name == "g" {
                let attributes = attrs.filter { $0.key != "id" && $0.key != "transform" }
                    .sorted { ($0.key.contains(":") ? 1 : 0, $0.key) < ($1.key.contains(":") ? 1 : 0, $1.key) }
                    .map { (name: String($0.key.split(separator: ":").last!), value: $0.value) }
                push(Node(id: id, translation: translation, strokeHalfWidth: strokeHalf, pathData: nil, attributes: attributes, children: []))
                return
            }
            // Other elements (rect/line/text in Notes and Guides) only
            // serve as nesting boundaries; their subtree is never emitted.
            push(Node(id: id, translation: translation, strokeHalfWidth: strokeHalf, pathData: nil, attributes: [], children: []))
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let node = stack.popLast() else { return }
            if !stack.isEmpty {
                stack[stack.count - 1].children.append(node)
            }
            // The Symbols group nests several levels deep (svg > asset g >
            // Group > Symbols); capture it whenever it closes.
            if node.id == "Symbols" {
                symbols = node
            }
        }

        private func push(_ node: Node) {
            stack.append(node)
        }

        func parseTranslate(_ raw: String) -> (dx: Double, dy: Double)? {
            guard raw.hasPrefix("translate") else { return nil }
            let inner = raw.drop { $0 != "(" }.dropFirst()
            let parts = inner.prefix { $0 != ")" }
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { Double($0) }
            guard !parts.isEmpty else { return nil }
            return (parts[0], parts.count > 1 ? parts[1] : 0)
        }

        /// The y of a horizontal guide drawn as a path: `M18,76 l800,0` -> 76.
        func guideY(_ d: String) -> Double? {
            guard d.first == "M" else { return nil }
            let numbers = d.dropFirst().prefix { !$0.isLetter }
                .split(whereSeparator: { $0 == "," || $0 == " " })
                .compactMap { Double($0) }
            return numbers.count >= 2 ? numbers[1] : nil
        }

        private func parseStrokeHalfWidth(_ attrs: [String: String]) -> Double {
            guard let stroke = attrs["stroke"], stroke != "none" else { return 0 }
            return (attrs["stroke-width"].flatMap(Double.init) ?? 1) / 2
        }
    }

    // MARK: Geometry

    struct Bounds {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
    }

    /// Bounding box of a node list in the layer's local space (the layer's
    /// own translate already dropped), with stroked subtrees expanded by
    /// half their stroke width. Extrema come from the path coordinates —
    /// symbol templates draw curves with on-curve extrema, so the control
    /// points never exceed the glyph (verified byte-exact against both
    /// NetNewsWire templates).
    static func bounds(of nodes: [Node]) -> Bounds {
        var b = Bounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        for node in nodes {
            guard let sub = subtreeBounds(node, dx: 0, dy: 0) else { continue }
            b.minX = min(b.minX, sub.minX)
            b.minY = min(b.minY, sub.minY)
            b.maxX = max(b.maxX, sub.maxX)
            b.maxY = max(b.maxY, sub.maxY)
        }
        return b
    }

    private static func subtreeBounds(_ node: Node, dx: Double, dy: Double) -> Bounds? {
        let ndx = dx + (node.translation?.dx ?? 0)
        let ndy = dy + (node.translation?.dy ?? 0)
        var b = Bounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)
        if let d = node.pathData {
            for (x, y) in pathPoints(d) {
                b.minX = min(b.minX, x + ndx)
                b.maxX = max(b.maxX, x + ndx)
                b.minY = min(b.minY, y + ndy)
                b.maxY = max(b.maxY, y + ndy)
            }
        }
        for child in node.children {
            guard let sub = subtreeBounds(child, dx: ndx, dy: ndy) else { continue }
            b.minX = min(b.minX, sub.minX)
            b.minY = min(b.minY, sub.minY)
            b.maxX = max(b.maxX, sub.maxX)
            b.maxY = max(b.maxY, sub.maxY)
        }
        guard b.minX.isFinite else { return nil }
        if node.strokeHalfWidth > 0 {
            b.minX -= node.strokeHalfWidth
            b.maxX += node.strokeHalfWidth
            b.minY -= node.strokeHalfWidth
            b.maxY += node.strokeHalfWidth
        }
        return b
    }

    /// Every on-curve and control point of a path's `d`, in absolute user
    /// units. Relative commands (Inkscape and other editors write them)
    /// accumulate from the current point. Control points count: actool's
    /// vector viewBox of the IceCubes rocket (Ultralight, Regular, Black
    /// layers) equals the bounds of all path points to four decimals, and
    /// the on-curve extrema alone come out smaller. An arc contributes its
    /// end point and the extreme points of its ellipse that lie inside the sweep.
    private static func pathPoints(_ d: String) -> [(Double, Double)] {
        let tokens = tokenizePathData(d)
        var points: [(Double, Double)] = []
        var x = 0.0, y = 0.0, startX = 0.0, startY = 0.0
        var command: Character = "M"
        var i = 0
        while i < tokens.count {
            if case .command(let c) = tokens[i] {
                command = c
                i += 1
                if c == "Z" || c == "z" {
                    x = startX
                    y = startY
                    continue
                }
            }
            let count: Int
            switch command {
            case "M", "m", "L", "l", "T", "t": count = 2
            case "H", "h", "V", "v": count = 1
            case "C", "c": count = 6
            case "S", "s", "Q", "q": count = 4
            case "A", "a": count = 7
            default:
                i += 1
                continue
            }
            var values: [Double] = []
            while i < tokens.count, values.count < count, case .number(let v) = tokens[i] {
                values.append(v)
                i += 1
            }
            guard values.count == count else { continue }
            let relative = command.isLowercase
            let ox = relative ? x : 0
            let oy = relative ? y : 0
            switch command.uppercased() {
            case "H":
                x = ox + values[0]
            case "V":
                y = oy + values[0]
            case "A":
                let endX = ox + values[5]
                let endY = oy + values[6]
                points.append(contentsOf: arcExtrema(
                    fromX: x, fromY: y, radiusX: values[0], radiusY: values[1], rotation: values[2],
                    largeArc: values[3] != 0, sweep: values[4] != 0, toX: endX, toY: endY))
                x = endX
                y = endY
            default:
                for k in stride(from: 0, to: count - 2, by: 2) {
                    points.append((ox + values[k], oy + values[k + 1]))
                }
                x = ox + values[count - 2]
                y = oy + values[count - 1]
            }
            points.append((x, y))
            if command == "M" || command == "m" {
                startX = x
                startY = y
                command = relative ? "l" : "L"
            }
        }
        return points
    }

    /// The points of an SVG elliptical arc where x or y is extreme and that
    /// lie inside the sweep (SVG 1.1 F.6.5 end-point to center conversion).
    /// Degenerate arcs (equal end points, a zero radius) add nothing; their
    /// end point is the caller's.
    static func arcExtrema(
        fromX x1: Double, fromY y1: Double, radiusX: Double, radiusY: Double, rotation: Double,
        largeArc: Bool, sweep: Bool, toX x2: Double, toY y2: Double
    ) -> [(Double, Double)] {
        var rx = abs(radiusX), ry = abs(radiusY)
        guard rx > 0, ry > 0, x1 != x2 || y1 != y2 else { return [] }
        let phi = rotation * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (x1 - x2) / 2, dy = (y1 - y2) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy
        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coefficient = (largeArc == sweep ? -1.0 : 1.0) * (max(0, numerator / denominator)).squareRoot()
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (x1 + x2) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (y1 + y2) / 2
        let start = atan2((y1p - cyp) / ry, (x1p - cxp) / rx)
        var delta = atan2((-y1p - cyp) / ry, (-x1p - cxp) / rx) - start
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        // x(t) = cx + rx cos(phi) cos t - ry sin(phi) sin t, y(t) = cy + rx sin(phi) cos t + ry cos(phi) sin t.
        // dx/dt = 0 at t = atan2(-ry sin(phi), rx cos(phi)) + k pi; dy/dt = 0 at atan2(ry cos(phi), rx sin(phi)) + k pi.
        let base = [atan2(-ry * sinPhi, rx * cosPhi), atan2(ry * cosPhi, rx * sinPhi)]
        var out: [(Double, Double)] = []
        for t0 in base {
            for k in 0..<2 {
                let t = t0 + Double(k) * .pi
                // Offset of t from the arc start in the sweep direction, in [0, 2 pi).
                var offset = sweep ? t - start : start - t
                offset = offset.truncatingRemainder(dividingBy: 2 * .pi)
                if offset < 0 { offset += 2 * .pi }
                guard offset <= abs(delta) else { continue }
                out.append((cx + rx * cosPhi * cos(t) - ry * sinPhi * sin(t),
                            cy + rx * sinPhi * cos(t) + ry * cosPhi * sin(t)))
            }
        }
        return out
    }

    private enum PathToken {
        case command(Character)
        case number(Double)
    }

    private static func tokenizePathData(_ d: String) -> [PathToken] {
        var tokens: [PathToken] = []
        var number = ""
        for ch in d {
            if ch.isLetter {
                if !number.isEmpty { tokens.append(.number(Double(number) ?? 0)); number = "" }
                tokens.append(.command(ch))
            } else if ch.isNumber || ch == "." || ch == "-" || ch == "+" || ch == "e" || ch == "E" {
                if (ch == "-" || ch == "+"), !number.isEmpty, !number.hasSuffix("e"), !number.hasSuffix("E") {
                    tokens.append(.number(Double(number) ?? 0))
                    number = String(ch)
                } else {
                    number.append(ch)
                }
            } else {
                if !number.isEmpty { tokens.append(.number(Double(number) ?? 0)); number = "" }
            }
        }
        if !number.isEmpty { tokens.append(.number(Double(number) ?? 0)) }
        return tokens
    }

    // MARK: Apple serializer

    /// Rewrites one layer the way actool embeds it. `scale` is 17/100.
    static func rewrittenSVG(layer: Layer, bounds: Bounds, scale: Double) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        out += "<svg version=\"1.1\" viewBox=\"0 0 \(number(bounds.width * scale)) \(number(bounds.height * scale))\">"
        out += "<g id=\"s\" transform=\"matrix(\(number(scale)) 0 0 \(number(scale)) "
        out += number(-bounds.minX * scale)
        out += " "
        out += number(-bounds.minY * scale)
        out += ")\">"
        out += serialize(layer.children)
        out += "</g></svg>\n"
        return Data(out.utf8)
    }

    private static func serialize(_ nodes: [Node]) -> String {
        var out = ""
        for node in nodes {
            if let d = node.pathData {
                out += "<path d=\"\(rewritePathData(d))\""
                for (name, value) in node.attributes {
                    out += " \(name)=\"\(escaped(value))\""
                }
                if let id = node.id {
                    out += " id=\"\(escaped(id))\""
                }
                out += "/>"
            } else if node.id != nil || !node.children.isEmpty {
                // Emit only real groups (id-bearing); parsing boundaries
                // carry neither.
                guard node.id != nil else { continue }
                out += "<g"
                if let id = node.id {
                    out += " id=\"\(escaped(id))\""
                }
                for (name, value) in node.attributes {
                    out += " \(name)=\"\(escaped(value))\""
                }
                if let t = node.translation {
                    out += " transform=\"translate(\(raw(t.dx)), \(raw(t.dy)))\""
                }
                out += ">"
                out += serialize(node.children)
                out += "</g>"
            }
        }
        return out
    }

    /// Re-print path data with `%g` numbers and Apple's minimal separator
    /// rule: a space before a number only when it does not start with '-'
    /// and does not directly follow a command letter.
    static func rewritePathData(_ d: String) -> String {
        var out = ""
        var previousWasNumber = false
        for token in tokenizePathData(d) {
            switch token {
            case .command(let c):
                out.append(c)
                previousWasNumber = false
            case .number(let v):
                let text = number(v)
                if previousWasNumber && !text.hasPrefix("-") {
                    out += " "
                }
                out += text
                previousWasNumber = true
            }
        }
        return out
    }

    /// `%g` with 6 significant digits, Apple's serializer format. Implemented
    /// by hand: swift-corelibs-foundation's `String(format: "%g")` drops a
    /// digit on Linux (77.05077 prints "77.050" instead of "77.0508").
    static func number(_ v: Double) -> String {
        if v == 0 { return "0" }            // also normalizes -0
        let negative = v < 0
        let value = abs(v)
        let exponent = Int(floor(log10(value)))
        // %g uses scientific notation when exponent < -4 or >= precision.
        if exponent < -4 || exponent >= 6 {
            let mantissa = value / pow(10, Double(exponent))
            var m = String(format: "%.5f", mantissa)
            if m.contains(".") { m = trimmedZeros(m) }
            let e = exponent < 0 ? "-\(abs(exponent))" : "\(exponent)"
            return "\(negative ? "-" : "")\(m)e\(e)"
        }
        let decimals = max(0, 5 - exponent)
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") { s = trimmedZeros(s) }
        return "\(negative ? "-" : "")\(s)"
    }

    private static func trimmedZeros(_ s: String) -> String {
        var out = s
        while out.hasSuffix("0") { out.removeLast() }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    private static func raw(_ v: Double) -> String {
        String(format: "%g", v)
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
