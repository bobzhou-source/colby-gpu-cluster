import CoreGraphics
import SwiftUI

/// Single occlusion oracle for the city: every "am I hidden" probe and every
/// "what punches me" mask runs against the same cached occluder set, plus
/// the per-frame posed occluders of animated landmarks (the golem's
/// stirring shoulder, draped arm, and head), so intervening actors
/// depth-sort against moving masses
/// without invalidating the retained world cache.
struct CityOcclusionField: Sendable {
    let occluders: [CitySceneStaticPaths.CachedOccluder]
    let densityStages: [String: Int]

    func occluderIsActive(_ occluder: CitySceneStaticPaths.CachedOccluder) -> Bool {
        CityDensity.isRevealed(occluder.revealStage, at: densityStages[occluder.plotID] ?? 0)
    }
    func isHidden(worldX: CGFloat, worldY: CGFloat, z: CGFloat, boundsOnly: Bool = false) -> Bool {
        let point = IsoProjection.project(worldX, worldY, z)
        for occluder in occluders {
            guard occluderIsActive(occluder) else { continue }
            guard worldX < occluder.rightWallX, worldY < occluder.frontWallY,
                  occluder.bounds.contains(point) else { continue }
            if boundsOnly || occluder.silhouette.contains(point) { return true }
        }
        return false
    }

    func punchMask(
        worldX: CGFloat? = nil,
        worldY: CGFloat? = nil,
        spriteBounds: CGRect,
        backSortKey: CGFloat? = nil,
        inflate: CGFloat = 0,
        excluding exclusionGroup: String? = nil
    ) -> Path? {
        let debug = ProcessInfo.processInfo.environment["CITY_CONSTRUCT_DEBUG"] != nil
        var mask: Path?
        for occluder in occluders {
            if let exclusionGroup, occluder.plotID == exclusionGroup { continue }
            let active = occluderIsActive(occluder)
            if let backSortKey {
                let sortKey = occluder.rightWallX + occluder.frontWallY
                let intersects = occluder.bounds.intersects(spriteBounds.insetBy(dx: -1.5, dy: -1.5))
                if debug, intersects {
                    FileHandle.standardError.write("construct-debug mask backSort=\(backSortKey) occSort=\(sortKey) active=\(active) pass=\(active && sortKey > backSortKey) plot=\(occluder.plotID)\n".data(using: .utf8)!)
                }
                guard active, sortKey > backSortKey, intersects else { continue }
            } else {
                guard active,
                      let worldX,
                      let worldY,
                      worldX < occluder.rightWallX,
                      worldY < occluder.frontWallY,
                      occluder.bounds.intersects(spriteBounds.insetBy(dx: -inflate, dy: -inflate)) else {
                    continue
                }
            }
            if mask == nil { mask = Path() }
            mask?.addPath(occluder.silhouette)
        }
        return mask
    }
}
