import Foundation

/// Icon Composer layered renditions (`.icon` sources): named gradients,
/// groups, and the icon image stack. Byte layouts were reverse-engineered
/// from Apple actool 27.0's compilation of the IceCubesApp `AppIcon.icon`
/// (oracle `oracle/icecubes-apple/out-direct/Assets.car`); the unit tests
/// pin every encoded byte against blocks carved from that car.
///
/// All three renditions carry their structure in TVL entries between the
/// 184-byte CSI header and the body:
///
/// - 0x3f4 (1004 decimal tag space excluded — these use the raw tag words
///   0x3ec..0x3fe): per-layer / per-child records,
/// - 0x3fc: fill (group) or blur material (stack),
/// - 0x3fd: group slots: translucency + shadow per group child,
/// - 0x3fe: zero-filled per-child slots,
/// - 0x3ec: (0.0, 1.0) float pair — colors and gradients carry (0.0, 0.0),
/// - 0x3ed: stack only: u64 length + UTI "public.layeredimage",
/// - 0x3ee: 1.
enum LayeredRenditions {
    /// Layer reference encoded as FACETKEYS-style (attribute, value) u16
    /// pairs: (1=element, 85=bitmap), (2=part, `part`), (17=identifier,
    /// `identifier`), then a zero pair.
    static func referencePairs(element: UInt16 = 85, part: UInt16, identifier: UInt16) -> [UInt8] {
        var w = ByteWriter()
        let pairs: [(UInt16, UInt16)] = [(1, element), (2, part), (17, identifier), (0, 0)]
        for (attr, value) in pairs {
            w.writeLE(attr)
            w.writeLE(value)
        }
        return Array(w.data)
    }
}

/// A named vertical two-stop gradient ("Named Gradient", CSI layout 1021).
/// The stop colors are referenced by their full facet names
/// ("AppIcon_Assets/Color-2"); the color renditions themselves are ordinary
/// `ColorBody` bitmaps at part 217.
struct NamedGradientBody: Sendable {
    /// Full facet names of the stop colors, in order (exactly two stops:
    /// Icon Composer gradients are vertical top/bottom pairs).
    var stopColorNames: [String]
}

/// One layer inside an Icon Composer group.
struct IconGroupLayer: Sendable {
    /// Full facet name of the layer image ("AppIcon_Assets/puple_cube").
    var imageFacetName: String
    /// The image facet's NameIdentifier.
    var imageIdentifier: UInt16
    /// Layer rect: points relative to the 1024 pt canvas.
    var positionX: Int32
    var positionY: Int32
    var width: UInt32
    var height: UInt32
    /// CoreUI blend word. 0 = normal, 5 = lighten.
    var blendMode: UInt32
    var opacity: Float
    /// Facet name of the resolved fill, or nil when the layer has none.
    var fillName: String?
    /// `glass: false` clears this. assetutil calls it LayerHasLightingEffects.
    var hasLighting: Bool = true
}

/// An Icon Composer group ("IconGroup", CSI layout 1020). One rendition per
/// (group, appearance); the group's glass/shadow/translucency parameters are
/// encoded where the group is referenced from the stack, not here.
struct IconGroupBody: Sendable {
    var layers: [IconGroupLayer]
    /// The CSI header's 126-char name field. actool writes the literal
    /// "IconGroup" for every group rendition (IceCubes oracle RenditionName).
    var csiName: String
}

/// One child of the icon image stack: the background gradient or a group.
struct IconStackChild: Sendable {
    /// 247 for the background gradient, 246 for a group.
    var part: UInt16
    var identifier: UInt16
    /// blur-material value: kind (gradient 1, groups 2) and strength. Groups
    /// without a blur material carry strength 0 (IceCubes oracle: the group
    /// with `blur-material-specializations` value 1 carries 1.0, the plain
    /// group 0.0).
    var blurStrength: Float
    /// Translucency value resolved for the stack's appearance; 0 when
    /// disabled or unset (the tinted stack carries 0.0 for every child).
    var translucency: Float
    /// Shadow kind word (2 = layer-color) and opacity, from `shadow`.
    var shadowStyle: UInt32
    var shadowOpacity: Float
}

/// The Icon Composer icon stack ("IconImageStack", CSI layout 1019). One
/// rendition per appearance; children are the background gradient followed
/// by the groups in reverse icon.json order (topmost group first — IceCubes
/// oracle: json groups [Group, Group 2] encode as [system-light, Group 2,
/// Group]).
struct IconImageStackBody: Sendable {
    var canvasSide: UInt32
    var children: [IconStackChild]
    /// CSI header name field: "<icon name>.iconstack" (oracle RenditionName).
    var csiName: String

    /// What BITMAPKEYS records for the icon asset: Apple's descriptor slots
    /// are [child expansion across appearances, 1, layer count]. Expansion =
    /// the gradient (one) plus every group's three appearance variants
    /// (IceCubes oracle: 1 + 2 groups x 3 = 7).
    var bitmapKeysSlots: (expansion: UInt32, layerCount: UInt32) {
        let groups = children.count - 1
        return (expansion: UInt32(1 + 3 * max(0, groups)), layerCount: UInt32(children.count))
    }
}

// MARK: - CSI writers

extension CSIWriter {
    private static func structuredHeader(
        layout: CSIHeader.Layout, name: String, width: UInt32, height: UInt32,
        tvlLength: UInt32
    ) -> Data {
        CSIHeader.encode(
            renditionFlags: 0,
            width: width,
            height: height,
            scaleFactor: 100,
            pixelFormat: CSIHeader.pixelFormatData,
            colorSpace: 0,
            layout: layout,
            name: name,
            tvlLength: tvlLength,
            bitmapCount: 1,
            renditionLength: 12
        )
    }

    static func namedGradient(name: String, body: NamedGradientBody) -> Data {
        precondition(body.stopColorNames.count == 2, "Icon Composer gradients have two stops")
        // Body (IceCubes oracle, system-light 94 bytes):
        // 'ARGG', 2, 1 (linear), stop0 position 0.0, start point (0.5, 0.0),
        // stop point (0.5, 1.0), 0.0, then per stop: u32 byte length (name +
        // NUL), NUL-terminated name, and the stop position (0.0 then 1.0)
        // before the second name. The (0.5, 0.0)-(0.5, 1.0) line is Apple's
        // constant vertical axis; the leading/trailing 0.0 words are
        // unwritten fields pinned by the fixture.
        var w = ByteWriter()
        w.writeFourCC("ARGG")
        w.writeLE(UInt32(2))
        w.writeLE(UInt32(1))
        w.writeLE(Float(0.0).bitPattern)
        w.writeLE(Float(0.5).bitPattern)
        w.writeLE(Float(0.0).bitPattern)
        w.writeLE(Float(0.5).bitPattern)
        w.writeLE(Float(1.0).bitPattern)
        w.writeLE(Float(0.0).bitPattern)
        for (index, colorName) in body.stopColorNames.enumerated() {
            let bytes = Array((colorName + "\0").utf8)
            w.writeLE(UInt32(bytes.count))
            w.write(bytes)
            if index == 0 {
                w.writeLE(Float(1.0).bitPattern)
            }
        }
        let bodyData = Array(w.data)

        let gradientEntries: [TVLEntry] = [
            .rawBytes(tag: 0x3ec, payload: zeroPair),
            .rawBytes(tag: 0x3ee, payload: one),
        ]
        let tvl = CSITVL.encode(gradientEntries)
        var header = CSIHeader.encode(
            renditionFlags: 0,
            width: 0,
            height: 0,
            scaleFactor: 0,
            pixelFormat: 0,
            colorSpace: 0,
            layout: .namedGradient,
            name: name,
            tvlLength: UInt32(tvl.count),
            bitmapCount: 1,
            renditionLength: UInt32(bodyData.count)
        )
        header.append(tvl)
        header.append(contentsOf: bodyData)
        return header
    }

    static func iconGroup(name: String, body: IconGroupBody) -> Data {
        _ = name  // the CSI name comes from the body; the facet name keys the rendition
        precondition(!body.layers.isEmpty, "Icon Composer groups have at least one layer")
        // 0x3f4: count, two zero words, then per layer 28 bytes of geometry,
        // the 16-byte facet reference, and a 4-byte pad (omitted on the last
        // layer). A one-layer group is the old packed layout, which is what
        // the IceCubes fixture pins.
        var layers = ByteWriter()
        layers.writeLE(UInt32(body.layers.count))
        layers.writeZeros(8)
        for (index, layer) in body.layers.enumerated() {
            layers.writeLE(UInt32(bitPattern: layer.positionX))
            layers.writeLE(UInt32(bitPattern: layer.positionY))
            layers.writeLE(layer.width)
            layers.writeLE(layer.height)
            layers.writeLE(layer.blendMode)
            layers.writeLE(layer.opacity.bitPattern)
            layers.writeLE(UInt32(0x10))
            layers.write(LayeredRenditions.referencePairs(part: 181, identifier: layer.imageIdentifier))
            if index + 1 < body.layers.count {
                layers.writeZeros(4)
            }
        }
        let f4 = Array(layers.data)

        // 0x3fc. One layer keeps the IceCubes bytes (count, 0, lighting, 0,
        // then a length-prefixed name or length 1 + NUL). Several layers are
        // 13-byte slots — 0, lighting, 0, 0x01 — plus a zero trailer. assetutil
        // reads one slot per layer and SIGSEGVs on the one-slot form.
        var fill = ByteWriter()
        fill.writeLE(UInt32(body.layers.count))
        if body.layers.count == 1 {
            let layer = body.layers[0]
            fill.writeLE(UInt32(0))
            fill.writeLE(UInt32(layer.hasLighting ? 1 : 0))
            fill.writeLE(UInt32(0))
            if let fillName = layer.fillName {
                let bytes = Array((fillName + "\0").utf8)
                fill.writeLE(UInt32(bytes.count))
                fill.write(bytes)
            } else {
                fill.writeLE(UInt32(1))
                fill.write([0x00])
            }
        } else {
            for layer in body.layers {
                fill.writeLE(UInt32(0))
                fill.writeLE(UInt32(layer.hasLighting ? 1 : 0))
                fill.writeLE(UInt32(0))
                fill.write([0x01])
            }
            fill.writeZeros(4)
        }
        let ffc = Array(fill.data)

        // 0x3fd / 0x3fe scale with the layer count. One layer is 28 and 20
        // bytes, which is what IceCubes pins.
        let groupSlots = concat(one, .init(repeating: 0, count: 20 * body.layers.count + 4))
        let groupFlags = concat(one, .init(repeating: 0, count: 12 * body.layers.count + 4))
        let entries: [TVLEntry] = [
            .rawBytes(tag: 0x3f4, payload: Array(f4)),
            .rawBytes(tag: 0x3fc, payload: Array(ffc)),
            .rawBytes(tag: 0x3fd, payload: groupSlots),
            .rawBytes(tag: 0x3fe, payload: groupFlags),
            .rawBytes(tag: 0x3ec, payload: slicePair),
            .rawBytes(tag: 0x3ee, payload: one),
        ]
        let tvl = CSITVL.encode(entries)
        let header = structuredHeader(layout: .iconGroup, name: body.csiName, width: 0, height: 0, tvlLength: UInt32(tvl.count))
        var data = header
        data.append(tvl)
        data.append(DWAREnvelope.encode(flags: 0, payload: []) as Data)
        return data
    }

    static func iconImageStack(name: String, body: IconImageStackBody) -> Data {
        precondition(!body.children.isEmpty, "Icon stacks have at least the background gradient")
        // 0x3f4 payload: child count, one zero word, then per child 48
        // bytes: six zero words, opacity 1.0, flags 0x10, facet reference.
        var children = ByteWriter()
        children.writeLE(UInt32(body.children.count))
        children.writeLE(UInt32(0))
        for child in body.children {
            children.writeZeros(24)
            children.writeLE(Float(1.0).bitPattern)
            children.writeLE(UInt32(0x10))
            children.write(LayeredRenditions.referencePairs(part: child.part, identifier: child.identifier))
        }
        let f4 = children.data

        // 0x3fc: blur material slots — count, three zero words, then per
        // group child (u32 1, u32 0x200, u8 0, strength float), then a
        // trailing u32 1 + u8 0. 47 bytes for two groups; the constant
        // words are pinned by the IceCubes fixture.
        var blur = ByteWriter()
        blur.writeLE(UInt32(body.children.count))
        blur.writeZeros(12)
        for child in body.children.dropFirst() {
            blur.writeLE(UInt32(1))
            blur.writeLE(UInt32(0x200))
            blur.write(byte: 0x00)
            blur.writeLE(child.blurStrength.bitPattern)
        }
        blur.writeLE(UInt32(1))
        blur.write(byte: 0x00)
        let ffc = Array(blur.data)

        // 0x3fd: per group child (u32 1, translucency float, shadow style,
        // shadow opacity float, u32 0), after count + six zero words.
        var slots = ByteWriter()
        slots.writeLE(UInt32(body.children.count))
        slots.writeZeros(24)
        for child in body.children.dropFirst() {
            slots.writeLE(UInt32(1))
            slots.writeLE(child.translucency.bitPattern)
            slots.writeLE(child.shadowStyle)
            slots.writeLE(child.shadowOpacity.bitPattern)
            slots.writeLE(UInt32(0))
        }
        let ffd = Array(slots.data)

        let stackFlags = concat(w32(UInt32(body.children.count)), .init(repeating: 0, count: 40))
        let stackEntries: [TVLEntry] = [
            .rawBytes(tag: 0x3f4, payload: Array(f4)),
            .rawBytes(tag: 0x3fc, payload: Array(ffc)),
            .rawBytes(tag: 0x3fd, payload: Array(ffd)),
            .rawBytes(tag: 0x3fe, payload: stackFlags),
            .rawBytes(tag: 0x3ec, payload: slicePair),
            .rawBytes(tag: 0x3ed, payload: lengthString("public.layeredimage")),
            .rawBytes(tag: 0x3ee, payload: one),
        ]
        let tvl = CSITVL.encode(stackEntries)
        let header = structuredHeader(
            layout: .iconImageStack, name: body.csiName,
            width: body.canvasSide, height: body.canvasSide, tvlLength: UInt32(tvl.count))
        var data = header
        data.append(tvl)
        data.append(DWAREnvelope.encode(flags: 0, payload: []) as Data)
        return data
    }

}

// MARK: - Byte helpers (file scope: the CSIWriter extension and the
// reference-pair builder share them)

private func w32(_ value: UInt32) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

private func concat(_ parts: [UInt8]...) -> [UInt8] {
    parts.reduce([], +)
}

/// The (0.0, 1.0) float pair layered renditions carry in tag 0x3ec.
private let slicePair: [UInt8] = concat(w32(0), w32(Float(1.0).bitPattern))

/// The (0.0, 0.0) pair colors and gradients carry.
private let zeroPair: [UInt8] = concat(w32(0), w32(0))

private let one: [UInt8] = w32(1)

/// u64 length + NUL-terminated UTF-8 (tag 0x3ed payload).
private func lengthString(_ s: String) -> [UInt8] {
    var bytes = concat(w32(UInt32(s.utf8.count + 1)), w32(0))
    bytes += Array((s + "\u{0000}").utf8)
    return bytes
}
