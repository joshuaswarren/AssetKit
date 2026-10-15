import Foundation
import Testing
@testable import AssetKit

/// An editor-saved template (the IceCubes rocket, written by Inkscape):
/// relative path commands and three weight layers of one size class. Apple's
/// actool embeds each layer with a viewBox equal to the bounds of ALL path
/// points, control points included, and keys the layers by weight.
@Suite("Symbol template layers")
struct SymbolTemplateLayersTests {
    private let template = """
    <svg xmlns="http://www.w3.org/2000/svg" version="1.1">
      <g id="Guides">
        <line id="Baseline-S" x1="0" x2="9" y1="30" y2="30"/>
        <line id="Capline-S" x1="0" x2="9" y1="20" y2="20"/>
      </g>
      <g id="Symbols">
        <g id="Ultralight-S"><path d="m 10,20 c 5,0 10,5 10,10 l -20,0 z"/></g>
        <g id="Regular-S"><path d="m 10,20 c 5,0 10,5 10,10 l -20,0 z"/></g>
        <g id="Black-S"><path d="m 10,20 c 5,0 10,5 10,10 l -20,0 z"/></g>
      </g>
    </svg>
    """

    @Test("Layers are keyed by the weight in their id")
    func weights() throws {
        let parsed = try SymbolTemplate.parse(Data(template.utf8), asset: "rocket", filename: "rocket.svg")
        #expect(parsed.layers.map(\.weight) == [1, 4, 9])
        #expect(parsed.layers.map(\.sizeClass) == [1, 1, 1])
    }

    @Test("Relative commands accumulate from the current point and control points count")
    func relativeBounds() throws {
        let parsed = try SymbolTemplate.parse(Data(template.utf8), asset: "rocket", filename: "rocket.svg")
        let b = SymbolTemplate.bounds(of: parsed.layers[1].children)
        // Points: (10,20); controls (15,20) (20,25); end (20,30); l -20,0 -> (0,30); z returns to (10,20).
        #expect(b.minX == 0)
        #expect(b.maxX == 20)
        #expect(b.minY == 20)
        #expect(b.maxY == 30)
    }
}
