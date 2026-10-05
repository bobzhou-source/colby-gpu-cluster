import CoreGraphics
import SwiftUI

enum CityLiveLayer: Int, Comparable {
    case world = 0
    case aerial = 1
    case overlayUI = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CityLiveOcclusionMode: Equatable {
    case none
    case skip
    case punch(exclusionGroup: String? = nil)
}

struct CityWorldAnchor: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let z: CGFloat
}

struct CityLiveItemDescriptor: Equatable {
    let id: String
    let layer: CityLiveLayer
    let mode: CityLiveOcclusionMode
    let anchor: CityWorldAnchor
    let sortKey: CGFloat
    let probeBounds: CGRect?
}

struct CityLiveItem {
    let descriptor: CityLiveItemDescriptor
    let draw: @MainActor (inout GraphicsContext) -> Void
}

/// Collects every live-overlay sprite, then draws them in world-depth order:
/// layer, then sort key, then enqueue order. Intra-group paint order within one
/// layer/depth tie therefore remains stable.
struct CityLiveQueue {
    private(set) var items: [CityLiveItem] = []

    mutating func enqueue(
        _ descriptor: CityLiveItemDescriptor,
        draw: @escaping @MainActor (inout GraphicsContext) -> Void
    ) {
        items.append(CityLiveItem(descriptor: descriptor, draw: draw))
    }

    func sortedItems() -> [CityLiveItem] {
        items.enumerated().sorted {
            let lhs = $0.element.descriptor
            let rhs = $1.element.descriptor
            if lhs.layer != rhs.layer { return lhs.layer < rhs.layer }
            if lhs.sortKey != rhs.sortKey { return lhs.sortKey < rhs.sortKey }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    @MainActor
    func draw(context: inout GraphicsContext, field: CityOcclusionField) {
        for item in sortedItems() {
            let descriptor = item.descriptor
            switch descriptor.mode {
            case .none:
                item.draw(&context)
            case .skip:
                guard !field.isHidden(
                    worldX: descriptor.anchor.x,
                    worldY: descriptor.anchor.y,
                    z: descriptor.anchor.z
                ) else { continue }
                item.draw(&context)
            case let .punch(exclusionGroup):
                guard let probe = descriptor.probeBounds,
                      let mask = field.punchMask(
                        worldX: descriptor.anchor.x,
                        worldY: descriptor.anchor.y,
                        spriteBounds: probe,
                        excluding: exclusionGroup
                      ) else {
                    item.draw(&context)
                    continue
                }
                context.drawLayer { layer in
                    item.draw(&layer)
                    layer.blendMode = .destinationOut
                    layer.fill(mask, with: .color(.black))
                }
            }
        }
    }
}
