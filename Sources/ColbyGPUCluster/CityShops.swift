import SwiftUI

extension CityRenderer {
    func drawShops(
        context: inout GraphicsContext,
        plot: CityPlot,
        date: Date,
        sample: CityPalette.Sample,
        band: ZoomBand,
        lod: CityDetailLevel
    ) {
        let open = plot.mode == .lit || plot.mode == .half
        let dressingFade = CityRenderPolicies.shopDressingOpacity(lod: lod)
        for shop in plot.shops {
            if dressingFade > 0 {
                drawShopAwning(context: &context, shop: shop, sample: sample, opacity: CityRenderPolicies.shopAwningOpacity(isOpen: open, lod: lod))
            }
            if CityRenderPolicies.shouldDrawShopDoorGlow(isOpen: open, band: band) {
                drawShopDoorGlow(context: &context, shop: shop, sample: sample)
            }
            if open, dressingFade > 0 {
                drawShopSign(context: &context, shop: shop, opacity: dressingFade)
            }
        }
        if open, dressingFade > 0 {
            drawShopStringLights(context: &context, shops: plot.shops, sample: sample, opacity: dressingFade)
        }
        let plazaOpacity = CityRenderPolicies.plazaOpacity(lod: lod)
        guard plazaOpacity > 0 else { return }
        guard let block = scape.blocks.first(where: { $0.node.id == plot.node.id }),
              block.plotIDs.first == plot.id,
              let plaza = scape.plazas.first(where: { $0.blockID == block.id }) else { return }
        drawPlaza(context: &context, plaza: plaza, date: date, sample: sample, opacity: plazaOpacity)
    }

    private func drawShopAwning(context: inout GraphicsContext, shop: ShopSpec, sample: CityPalette.Sample, opacity: Double) {
        let width: CGFloat = 1.6
        let height: CGFloat = 0.5
        let z: CGFloat = 0.82
        let colors = shopAccentColors(shop.accent)
        let start = shop.facingX
            ? (x: shop.x, y: shop.y - width / 2)
            : (x: shop.x - width / 2, y: shop.y)
        for stripe in 0..<4 {
            let f0 = CGFloat(stripe) / 4
            let f1 = CGFloat(stripe + 1) / 4
            let points: [CGPoint]
            if shop.facingX {
                let y0 = start.y + width * f0
                let y1 = start.y + width * f1
                points = [
                    IsoProjection.project(shop.x + 0.05, y0, z),
                    IsoProjection.project(shop.x + 0.05, y1, z),
                    IsoProjection.project(shop.x + 0.42, y1, z - height),
                    IsoProjection.project(shop.x + 0.42, y0, z - height),
                ]
            } else {
                let x0 = start.x + width * f0
                let x1 = start.x + width * f1
                points = [
                    IsoProjection.project(x0, shop.y + 0.05, z),
                    IsoProjection.project(x1, shop.y + 0.05, z),
                    IsoProjection.project(x1, shop.y + 0.42, z - height),
                    IsoProjection.project(x0, shop.y + 0.42, z - height),
                ]
            }
            var path = Path()
            path.move(to: points[0])
            path.addLines(Array(points.dropFirst()))
            path.closeSubpath()
            context.fill(path, with: .color((stripe.isMultiple(of: 2) ? colors.primary : colors.secondary).opacity(opacity)))
        }
    }

    private func drawShopDoorGlow(context: inout GraphicsContext, shop: ShopSpec, sample: CityPalette.Sample) {
        let point = IsoProjection.project(shop.x, shop.y, 0.28)
        let glow = Color(red: 1, green: 0.68, blue: 0.27).opacity(0.30 + 0.42 * sample.night)
        context.fill(Path(ellipseIn: CGRect(x: point.x - 2.2, y: point.y - 1.2, width: 4.4, height: 2.4)), with: .radialGradient(Gradient(colors: [glow, .clear]), center: point, startRadius: 0, endRadius: 2.2))
        let door = Path(CGRect(x: point.x - 0.6, y: point.y - 2.1, width: 1.2, height: 2.1))
        context.fill(door, with: .color(Color(red: 1, green: 0.74, blue: 0.35).opacity(0.40 + 0.38 * sample.night)))
        context.stroke(door, with: .color(voxelOutlineInk), lineWidth: 0.8)
    }

    private func drawShopSign(context: inout GraphicsContext, shop: ShopSpec, opacity: Double) {
        var signContext = context
        signContext.opacity *= opacity
        let point = IsoProjection.project(shop.x, shop.y, 1.34)
        let colors = shopAccentColors(shop.accent)
        let sign = Path(CGRect(x: point.x - 6, y: point.y - 3.4, width: 12, height: 5))
        signContext.fill(sign, with: .color(Color(red: 0.025, green: 0.05, blue: 0.075).opacity(0.93)))
        signContext.stroke(sign, with: .color(voxelOutlineInk), lineWidth: 0.8)
        signContext.draw(
            Text(shopGlyph(shop.kind)).font(.caption2.monospaced().weight(.bold)).foregroundStyle(colors.primary),
            at: CGPoint(x: point.x, y: point.y - 0.8),
            anchor: .center
        )
    }

    private func drawShopStringLights(context: inout GraphicsContext, shops: [ShopSpec], sample: CityPalette.Sample, opacity: Double) {
        var lightContext = context
        lightContext.opacity *= opacity
        let grouped = Dictionary(grouping: shops, by: \.facingX)
        for pair in grouped.values {
            let ordered = pair.sorted { $0.facingX ? $0.y < $1.y : $0.x < $1.x }
            for (first, second) in zip(ordered, ordered.dropFirst()) {
                let delta = shopDistance(first, second)
                guard delta < 5 else { continue }
                for index in 1...4 {
                    let t = CGFloat(index) / 5
                    let x = first.x + (second.x - first.x) * t
                    let y = first.y + (second.y - first.y) * t
                    let arc = CGFloat(sin(Double(t) * .pi)) * 0.28
                    let point = IsoProjection.project(x, y, 1.05 - arc)
                    let color = index.isMultiple(of: 2) ? shopAccentColors(first.accent).primary : Color(red: 1, green: 0.72, blue: 0.30)
                    let bulb = Path(ellipseIn: CGRect(x: point.x - 0.75, y: point.y - 0.75, width: 1.5, height: 1.5))
                    lightContext.fill(bulb, with: .color(color.opacity(0.65 + 0.3 * sample.night)))
                    lightContext.stroke(bulb, with: .color(voxelOutlineInk.opacity(0.9)), lineWidth: 0.55)
                }
            }
        }
    }

    private func drawPlaza(context: inout GraphicsContext, plaza: CityPlaza, date: Date, sample: CityPalette.Sample, opacity: Double) {
        var plazaContext = context
        plazaContext.opacity *= opacity
        let center = IsoProjection.project(plaza.x, plaza.y, 0.12)
        let blue = Color(red: 0.36, green: 0.62, blue: 0.95)
        for (radius, opacity) in [(5.0, 0.56), (3.5, 0.70), (2.1, 0.84)] {
            plazaContext.fill(
                Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius * 0.48, width: radius * 2, height: radius * 0.96)),
                with: .color(blue.opacity((opacity + 0.12 * sample.night)))
            )
        }
        let phase = reduceMotion ? 0 : date.timeIntervalSinceReferenceDate / 0.7
        for index in 0..<3 {
            let angle = Double(index) * 2.094 + phase * .pi * 2
            let point = CGPoint(x: center.x + CGFloat(cos(angle)) * 2.2, y: center.y + CGFloat(sin(angle)) * 0.9 - 1.8)
            plazaContext.fill(Path(ellipseIn: CGRect(x: point.x - 0.9, y: point.y - 0.9, width: 1.8, height: 1.8)), with: .color(Color(red: 0.62, green: 0.84, blue: 1).opacity(0.72)))
        }
        for (offsetX, accent) in [(-2.0, 0), (2.0, 1)] {
            let p = IsoProjection.project(plaza.x + offsetX, plaza.y + 1.4, 0.18)
            let colors = shopAccentColors(accent)
            plazaContext.fill(Path(CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 3)), with: .color(colors.secondary.opacity(0.9)))
            plazaContext.fill(Path(CGRect(x: p.x - 3.4, y: p.y - 5, width: 6.8, height: 2)), with: .color(colors.primary.opacity(0.94)))
        }
    }

    private func shopAccentColors(_ accent: Int) -> (primary: Color, secondary: Color) {
        switch accent % 5 {
        case 0: (Color(red: 0.27, green: 0.87, blue: 0.78), Color(red: 0.07, green: 0.31, blue: 0.32))
        case 1: (Color(red: 1, green: 0.67, blue: 0.26), Color(red: 0.38, green: 0.15, blue: 0.10))
        case 2: (Color(red: 0.42, green: 0.78, blue: 0.92), Color(red: 0.10, green: 0.20, blue: 0.38))
        case 3: (Color(red: 0.96, green: 0.56, blue: 0.42), Color(red: 0.34, green: 0.10, blue: 0.18))
        default: (Color(red: 1, green: 0.42, blue: 0.68), Color(red: 0.95, green: 0.95, blue: 0.97))
        }
    }

    private func shopGlyph(_ kind: ShopKind) -> String {
        switch kind {
        case .cafe: "CAF"
        case .market: "MKT"
        case .bakery: "BKY"
        case .records: "REC"
        case .arcade: "ARC"
        }
    }

    private func shopDistance(_ first: ShopSpec, _ second: ShopSpec) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private var voxelOutlineInk: Color { Color(red: 0.02, green: 0.03, blue: 0.09).opacity(0.9) }
}
