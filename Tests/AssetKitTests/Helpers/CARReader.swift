import Foundation

/// A minimal Assets.car (BOM store) reader for tests: the facts the macOS
/// oracle tests compare (header, KEYFORMAT, APPEARANCEKEYS, FACETKEYS,
/// rendition keys and BITMAPKEYS).
struct CARReader {
    let data: Data
    private var blocks: [(offset: Int, length: Int)] = []
    private var variables: [String: Int] = [:]

    init(_ data: Data) throws {
        self.data = data
        guard data.count > 32, String(decoding: data.prefix(8), as: UTF8.self) == "BOMStore" else {
            throw ReadError.notABOMStore
        }
        let indexOffset = Int(be32(data, 16)), varsOffset = Int(be32(data, 24))
        let count = Int(be32(data, indexOffset))
        for i in 0..<count {
            blocks.append((Int(be32(data, indexOffset + 4 + 8 * i)), Int(be32(data, indexOffset + 8 + 8 * i))))
        }
        var p = varsOffset + 4
        for _ in 0..<Int(be32(data, varsOffset)) {
            let block = Int(be32(data, p)), length = Int(data[data.startIndex + p + 4])
            variables[String(decoding: slice(p + 5, length), as: UTF8.self)] = block
            p += 5 + length
        }
    }

    enum ReadError: Error { case notABOMStore, missing(String) }

    // MARK: Facts

    var keySemantics: UInt32 { get throws { le32(try variable("CARHEADER"), 432) } }

    var platform: String {
        get throws { cString(try variable("EXTENDED_METADATA"), from: 516, length: 256) }
    }

    var keyFormat: [UInt32] {
        get throws {
            let block = try variable("KEYFORMAT")
            return (0..<Int(le32(block, 8))).map { le32(block, 12 + 4 * $0) }
        }
    }

    var appearances: [String: UInt16] {
        get throws {
            var out: [String: UInt16] = [:]
            for (key, value) in try tree("APPEARANCEKEYS") {
                out[String(decoding: key, as: UTF8.self)] = le16(value, 0)
            }
            return out
        }
    }

    /// Facet name -> its (attribute, value) pairs.
    var facets: [String: [UInt16: UInt16]] {
        get throws {
            var out: [String: [UInt16: UInt16]] = [:]
            for (key, value) in try tree("FACETKEYS") {
                var pairs: [UInt16: UInt16] = [:]
                for i in 0..<Int(le16(value, 4)) {
                    pairs[le16(value, 6 + 4 * i)] = le16(value, 8 + 4 * i)
                }
                out[String(decoding: key, as: UTF8.self)] = pairs
            }
            return out
        }
    }

    /// Rendition keys as "<asset>|Attr=value,…": the identifier is replaced
    /// by the asset name, zero values are left out (genoracle.py format).
    var renditionKeys: [String] {
        get throws {
            let format = try keyFormat
            var names: [UInt16: String] = [:]
            for (name, pairs) in try facets { names[pairs[17] ?? 0] = name }
            return try tree("RENDITIONS").map { key, _ in
                let values = (0..<format.count).map { le16(key, 2 * $0) }
                let name = names[values[format.firstIndex(of: 17) ?? 0]] ?? ""
                let attributes = zip(format, values)
                    .filter { $0.1 != 0 && $0.0 != 17 }
                    .map { "\(Self.attributeNames[$0.0] ?? "\($0.0)")=\($0.1)" }
                return name + "|" + attributes.joined(separator: ",")
            }.sorted()
        }
    }

    /// Facet name -> BITMAPKEYS descriptor words.
    var bitmapKeys: [String: [UInt32]] {
        get throws {
            var names: [UInt32: String] = [:]
            for (name, pairs) in try facets { names[UInt32(pairs[17] ?? 0)] = name }
            let header = try variable("BITMAPKEYS")
            var node = block(Int(be32(header, 8)))
            var out: [String: [UInt32]] = [:]
            while true {
                let count = Int(be16(node, 2)), forward = be32(node, 4)
                for i in 0..<count {
                    let value = block(Int(be32(node, 12 + 8 * i))), key = be32(node, 16 + 8 * i)
                    out[names[key] ?? "\(key)"] = (0..<value.count / 4).map { le32(value, 4 * $0) }
                }
                if forward == 0 { break }
                node = block(Int(forward))
            }
            return out
        }
    }

    static let attributeNames: [UInt32: String] = [
        1: "Element", 2: "Part", 3: "Size", 7: "Appearance", 8: "Dimension1", 9: "Dimension2",
        11: "Layer", 12: "Scale", 13: "Localization", 15: "Idiom", 16: "Subtype", 17: "Identifier",
        24: "DisplayGamut", 25: "DeploymentTarget", 26: "GlyphWeight", 27: "GlyphSize",
    ]

    // MARK: BOM

    private func variable(_ name: String) throws -> Data {
        guard let id = variables[name] else { throw ReadError.missing(name) }
        return block(id)
    }

    private func block(_ id: Int) -> Data { slice(blocks[id].offset, blocks[id].length) }

    private func tree(_ name: String) throws -> [(Data, Data)] {
        guard variables[name] != nil else { return [] }
        var node = block(Int(be32(try variable(name), 8)))
        while be16(node, 0) == 0 { node = block(Int(be32(node, 12))) } // leftmost leaf
        var out: [(Data, Data)] = []
        while true {
            let count = Int(be16(node, 2)), forward = be32(node, 4)
            for i in 0..<count {
                out.append((block(Int(be32(node, 16 + 8 * i))), block(Int(be32(node, 12 + 8 * i)))))
            }
            if forward == 0 { break }
            node = block(Int(forward))
        }
        return out
    }

    private func slice(_ offset: Int, _ length: Int) -> Data {
        Data(data[(data.startIndex + offset)..<(data.startIndex + offset + length)])
    }

}

private func be16(_ d: Data, _ o: Int) -> UInt16 {
    UInt16(d[d.startIndex + o]) << 8 | UInt16(d[d.startIndex + o + 1])
}
private func be32(_ d: Data, _ o: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(d[d.startIndex + o + $1]) }
}
private func le16(_ d: Data, _ o: Int) -> UInt16 {
    UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
}
private func le32(_ d: Data, _ o: Int) -> UInt32 {
    (0..<4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32(d[d.startIndex + o + $1]) }
}
private func cString(_ d: Data, from o: Int, length: Int) -> String {
    let bytes = d[(d.startIndex + o)..<(d.startIndex + o + length)]
    return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
}
