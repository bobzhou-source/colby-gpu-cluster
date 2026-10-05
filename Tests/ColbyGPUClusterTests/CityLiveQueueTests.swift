import CoreGraphics
import SwiftUI
import Testing
@testable import ColbyGPUCluster

@Suite("CityLiveQueue")
@MainActor
struct CityLiveQueueTests {
    @Test("Items sort by layer, world depth, then stable enqueue order")
    func stableDepthOrdering() {
        var queue = CityLiveQueue()
        let entries: [(String, CityLiveLayer, CGFloat)] = [
            ("ui", .overlayUI, 0),
            ("world-far", .world, 8),
            ("aerial", .aerial, -20),
            ("world-near-first", .world, 2),
            ("world-near-second", .world, 2),
        ]

        for (id, layer, sortKey) in entries {
            queue.enqueue(
                CityLiveItemDescriptor(
                    id: id,
                    layer: layer,
                    mode: .none,
                    anchor: CityWorldAnchor(x: sortKey, y: 0, z: 0),
                    sortKey: sortKey,
                    probeBounds: nil
                ),
                draw: { _ in }
            )
        }

        #expect(queue.sortedItems().map(\.descriptor.id) == [
            "world-near-first",
            "world-near-second",
            "world-far",
            "aerial",
            "ui",
        ])
    }

    @Test("Descriptors retain world anchors and occlusion policy")
    func descriptorContract() {
        let descriptor = CityLiveItemDescriptor(
            id: "kaiju",
            layer: .world,
            mode: .punch(exclusionGroup: "titan"),
            anchor: CityWorldAnchor(x: 4, y: 7, z: 2),
            sortKey: 11,
            probeBounds: CGRect(x: 1, y: 2, width: 3, height: 4)
        )

        #expect(descriptor.mode == .punch(exclusionGroup: "titan"))
        #expect(descriptor.anchor == CityWorldAnchor(x: 4, y: 7, z: 2))
        #expect(descriptor.probeBounds == CGRect(x: 1, y: 2, width: 3, height: 4))
    }
    @Test("Far traffic descriptors use offset world anchors and terrain occlusion")
    func farTrafficDescriptor() {
        let car = CityWhimsy.FarCar(
            x: 10,
            y: 20,
            dirX: 0,
            dirY: 1,
            forward: true,
            brightness: 0.8
        )
        let descriptor = CityRenderer.farTrafficDescriptor(for: car, index: 2)

        #expect(descriptor.id == "far-traffic-2")
        #expect(descriptor.layer == .world)
        #expect(descriptor.mode == .skip)
        #expect(descriptor.anchor == CityWorldAnchor(x: 9.55, y: 20, z: 0.15))
        #expect(descriptor.sortKey == IsoProjection.sortKey(x: 9.55, y: 20))
    }

}
