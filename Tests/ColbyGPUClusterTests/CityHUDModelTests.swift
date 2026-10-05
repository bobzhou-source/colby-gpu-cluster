import Foundation
import XCTest
@testable import ColbyGPUCluster

final class CityHUDModelTests: XCTestCase {


    func testCustomSSHHostIsSafelyQuotedInCopiedStatusCommand() {
        let model = CityHUDModel(
            plot: plot(
                node: ClusterNode(
                    name: "a100-01",
                    gpuType: "A100",
                    profile: "a100",
                    vramGB: 80,
                    gpuCount: 1,
                    state: "idle",
                    status: .idle,
                    stateLabel: "Idle",
                    jobs: []
                ),
                gpuIndex: 1,
                gpuCount: 1
            ),
            sshHost: "research cluster; echo unsafe"
        )

        XCTAssertEqual(
            model.command,
            "ssh 'research cluster; echo unsafe' 'sinfo -p gpu -N -h'"
        )
    }

    private func plot(node: ClusterNode, gpuIndex: Int, gpuCount: Int) -> CityPlot {
        CityPlot(
            node: node,
            gpuIndex: gpuIndex,
            gpuCount: gpuCount,
            x: 0,
            y: 0,
            w: 8,
            d: 6,
            mode: .lit,
            buildings: [],
            hasCrane: false
        )
    }
}
