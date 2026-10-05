import CoreGraphics

@MainActor
struct CityRenderPlan {
    let visibleRect: CGRect
    let visiblePlots: [CityPlot]
    let band: ZoomBand
    let lifeScale: CityRenderer.LifeScale

    init(
        scape: CityScape,
        staticPaths: CitySceneStaticPaths,
        camera: CityCamera,
        size: CGSize,
        band: ZoomBand
    ) {
        let visibleRect = CGRect(
            x: -camera.translation.width / camera.scale,
            y: -camera.translation.height / camera.scale,
            width: size.width / camera.scale,
            height: size.height / camera.scale
        )

        self.visibleRect = visibleRect
        self.visiblePlots = scape.sortedPlots.filter {
            staticPaths.renderBoundsByPlotID[$0.id, default: .null].intersects(visibleRect)
        }
        self.band = band
        self.lifeScale = CityRenderer.lifeScale(in: band)
    }
}
