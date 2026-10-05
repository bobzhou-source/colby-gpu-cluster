import CoreGraphics
import Observation

struct CityBaseRenderKey: Equatable, Sendable {
    let geometrySignature: String
    /// Settled per-plot density stages (see `CityDensity.signature`); the
    /// retained base re-renders exactly when a plot crosses a stage boundary.
    let densitySignature: String
    let viewport: CGSize
    let displayScale: CGFloat
    let paletteBucket: Int
    let camera: CityCamera
    let band: ZoomBand
}

struct CityBaseFrame {
    let key: CityBaseRenderKey
    let image: CGImage
}

enum CityBaseLayerPolicy {
    static let cameraSettleDelay: Duration = .milliseconds(120)

    /// Extra rendered margin (points, each side) around the viewport. Fast
    /// drags slide the retained base under the live overlay before the next
    /// frame lands; the overscan keeps real terrain - not empty sky - under
    /// the labels for that gap.
    static let overscan: CGFloat = 192

    /// Pause between back-to-back throttled renders while requests keep
    /// streaming in (continuous drags), so base refreshes never saturate the
    /// main thread that the gesture handling runs on.
    static let throttleInterval: Duration = .milliseconds(80)

    static func screenTransform(from rendered: CityCamera, to displayed: CityCamera) -> CGAffineTransform {
        guard rendered.scale.isFinite,
              displayed.scale.isFinite,
              rendered.scale > 0,
              displayed.scale > 0 else {
            return .identity
        }

        let ratio = displayed.scale / rendered.scale
        guard ratio.isFinite else { return .identity }
        return CGAffineTransform(
            a: ratio,
            b: 0,
            c: 0,
            d: ratio,
            tx: displayed.translation.width - ratio * rendered.translation.width,
            ty: displayed.translation.height - ratio * rendered.translation.height
        )
    }

    static func canDisplay(_ frameKey: CityBaseRenderKey, for desiredKey: CityBaseRenderKey) -> Bool {
        frameKey.geometrySignature == desiredKey.geometrySignature
            && frameKey.densitySignature == desiredKey.densitySignature
            && frameKey.viewport == desiredKey.viewport
            && frameKey.displayScale == desiredKey.displayScale
            && frameKey.paletteBucket == desiredKey.paletteBucket
    }
}

@MainActor
@Observable
final class CityBaseRenderCoordinator {
    private(set) var frame: CityBaseFrame?
    private var task: Task<Void, Never>?
    private var pending: (key: CityBaseRenderKey, render: @MainActor () async -> CGImage?)?
    private var generation = 0

    /// Throttles instead of debouncing: a new request never resets a timer
    /// that is already running, so continuous camera churn (fast drags) keeps
    /// landing fresh base frames instead of postponing them forever. Each
    /// landed frame drains the newest pending request next.
    func request(
        key: CityBaseRenderKey,
        delay: Duration,
        render: @escaping @MainActor () async -> CGImage?
    ) {
        pending = (key, render)
        guard task == nil else { return }
        generation += 1
        let started = generation
        task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard let self, !Task.isCancelled else { return }
            await self.drain()
            if self.generation == started {
                self.task = nil
            }
        }
    }

    func cancel() {
        pending = nil
        task?.cancel()
        task = nil
        generation += 1
    }

    private func drain() async {
        while !Task.isCancelled, let next = pending {
            pending = nil
            guard let image = await next.render(), !Task.isCancelled else { continue }
            frame = CityBaseFrame(key: next.key, image: image)
            if pending != nil {
                try? await Task.sleep(for: CityBaseLayerPolicy.throttleInterval)
            }
        }
    }
}
