import Foundation

/// FACETKEYS maps human-readable asset names to a list of attribute pairs that
/// CoreUI uses to seed a rendition lookup.
///
/// Value layout (verified against actool output, Xcode 26 / CoreUI 970):
/// - `cursorHotSpotX u16`, `cursorHotSpotY u16`
/// - `numberOfAttributes u16`
/// - array of `(attributeName u16, attributeValue u16)`
enum FacetKeys {
    static func value(for name: String, kind: Kind) -> Data {
        var w = ByteWriter()
        w.writeLE(UInt16(0))            // cursorHotSpotX
        w.writeLE(UInt16(0))            // cursorHotSpotY
        let crc = nameHash(name)
        let identifier = UInt16(crc & 0xFFFF)
        let pairs = kind.pairs(identifier: identifier)
        w.writeLE(UInt16(pairs.count))
        for (attrName, attrValue) in pairs {
            w.writeLE(attrName)
            w.writeLE(attrValue)
        }
        return w.data
    }

    enum Kind {
        case appIcon
        case image
        case color
        /// `.symbolset` assets. Apple keys the facet at the generic-image
        /// part and adds the symbol deployment-target pair (Apple symbol
        /// oracle: (1,85),(2,181),(17,hash),(25,5)).
        case symbol
        /// Icon Composer group ("AppIcon/Group", part 246).
        case iconGroup
        /// Icon Composer named gradient (part 247).
        case namedGradient

        func pairs(identifier: UInt16) -> [(UInt16, UInt16)] {
            switch self {
            case .appIcon:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.appIcon.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .symbol:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.image.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                    (UInt16(AttributeID.deploymentTarget.rawValue), 5),
                ]
            case .image:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.image.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .color:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.color.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .iconGroup:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.iconGroup.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            case .namedGradient:
                return [
                    (UInt16(AttributeID.element.rawValue), RenditionKey.Element.bitmap.rawValue),
                    (UInt16(AttributeID.part.rawValue), RenditionKey.Part.namedGradient.rawValue),
                    (UInt16(AttributeID.identifier.rawValue), identifier),
                ]
            }
        }
    }

    /// CRC32 (IEEE) of the asset name, truncated to 16 bits for the identifier slot.
    static func nameHash(_ name: String) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in name.utf8 {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xEDB88320
                } else {
                    crc >>= 1
                }
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
