import Foundation

enum ColorRenderer {
    static func renditions(for set: LoadedColorSet) throws -> [Rendition] {
        var out: [Rendition] = []
        for entry in set.contents.colors {
            let appearance = entry.appearances?.first { $0.darkLuminosity }
            if let systemName = entry.color.reference {
                // ponytail: gray fallback is black (light) / white (dark), which is exact for
                // labelColor; CoreUI resolves the name itself, so the fallback rarely shows.
                let white: Double = appearance == nil ? 0 : 1
                out.append(Rendition(
                    name: set.name, idiom: entry.idiom, scale: nil, appearance: appearance, gamut: .sRGB,
                    body: .color(ColorBody(red: white, green: white, blue: white, alpha: 1,
                                           colorSpaceID: 1, systemName: systemName))
                ))
                continue
            }
            guard let components = entry.color.components else {
                throw XCAssetCompilerError.invalidColorComponent("missing components in \(set.name)")
            }
            let (r, g, b, a) = try components.asDoubles()
            let gamut: Gamut = {
                if let declared = entry.displayGamut { return declared }
                switch entry.color.colorSpace {
                case "display-p3": return .displayP3
                default: return .sRGB
                }
            }()
            out.append(Rendition(
                name: set.name,
                idiom: entry.idiom,
                scale: nil,
                appearance: appearance,
                gamut: gamut,
                body: .color(ColorBody(
                    red: r, green: g, blue: b, alpha: a,
                    colorSpaceID: gamut.colorSpaceID
                ))
            ))
        }
        return out
    }
}
