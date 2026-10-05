@testable import ColbyGPUCluster

extension ClusterNode {
    init(
        name: String,
        gpuType: String,
        profile: String,
        vramGB: Double,
        gpuCount: Int,
        state: String,
        status: NodeStatus,
        stateLabel: String,
        jobs: [ClusterJob]
    ) {
        self.init(
            name: name,
            gres: [
                GPUResource(
                    gpuType: gpuType,
                    profile: profile,
                    vramGB: vramGB,
                    count: gpuCount,
                    used: status == .idle ? 0 : gpuCount
                )
            ],
            state: state,
            status: status,
            stateLabel: stateLabel,
            jobs: jobs
        )
    }
}
