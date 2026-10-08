import AppKit
import SwiftUI

enum RefreshLoopPolicy: Equatable {
    static let minimumInterval = 60
    static let maximumInterval = 600
    static let maximumBackoff: TimeInterval = 15 * 60

    case refreshOnce
    case refreshAndSchedule

    init(configuration: RefreshConfiguration) {
        self = configuration.source.isConfigured && configuration.enabled ? .refreshAndSchedule : .refreshOnce
    }

    /// A published status page can be polled more often than an SSH session.
    static func minimumInterval(forSource source: ClusterSource) -> Int {
        switch source {
        case .ssh: minimumInterval
        case .statusPage: 30
        }
    }

    static func effectiveInterval(_ storedInterval: Int, minimum: Int = minimumInterval) -> Int {
        max(minimum, storedInterval)
    }

    static func automaticDelay(
        interval storedInterval: Int,
        consecutiveFailures: Int
    ) -> TimeInterval {
        var delay = TimeInterval(effectiveInterval(storedInterval))
        for _ in 0..<max(0, consecutiveFailures) {
            guard delay < maximumBackoff else { return maximumBackoff }
            delay = min(delay * 2, maximumBackoff)
        }
        return delay
    }
}

enum AppShellTimestampLabel {
    static let failurePrefix = "Failed "
    static let successPrefix = "Last updated "
}


@MainActor
struct MenuBarStatusPresentation {
    let text: String
    let symbolName: String
    let accessibilityLabel: String

    init(store: ClusterStore) {
        let summary = store.hasLoaded && !store.snapshot.nodes.isEmpty
            ? store.snapshot.menuBarSummary
            : nil
        text = summary?.text ?? "—"
        if let error = store.errorMessage {
            symbolName = "exclamationmark.triangle"
            accessibilityLabel = summary == nil
                ? "GPU availability unavailable: \(error)"
                : "GPU availability may be outdated: \(error)"
        } else {
            symbolName = "building.2.fill"
            accessibilityLabel = summary?.text ?? "Checking GPU availability"
        }
    }
}

struct MenuBarStatusLabel: View {
    let store: ClusterStore
    @AppStorage("sshHost") private var sshHost = ""
    @AppStorage("statusPageURL") private var statusPageURL = ClusterSourceDefaults.statusPageURL
    @AppStorage("dataSourceKind") private var dataSourceKind = ClusterSourceKind.statusPage.rawValue
    @AppStorage("autoRefresh") private var autoRefresh = true
    @AppStorage("refreshInterval") private var refreshInterval = 60

    private var source: ClusterSource {
        ClusterSourceResolution.source(kind: dataSourceKind, url: statusPageURL, host: sshHost)
    }

    private var configuration: RefreshConfiguration {
        RefreshConfiguration(
            source: source,
            enabled: autoRefresh,
            interval: RefreshLoopPolicy.effectiveInterval(
                refreshInterval,
                minimum: RefreshLoopPolicy.minimumInterval(forSource: source)
            )
        )
    }

    var body: some View {
        let presentation = MenuBarStatusPresentation(store: store)
        let summary = store.hasLoaded && !store.snapshot.nodes.isEmpty
            ? store.snapshot.menuBarSummary
            : nil

        HStack(spacing: 4) {
            Image(systemName: presentation.symbolName)
            Text(presentation.text)
                .monospacedDigit()
            if let summary {
                skylineRibbon(summary)
            }
        }
        .fixedSize()
        .accessibilityLabel(presentation.accessibilityLabel)
        .task(id: configuration) {
            await refreshLoop(configuration)
        }
    }

    @ViewBuilder
    private func skylineRibbon(_ summary: MenuBarSummary) -> some View {
        let towers = Array(summary.towers.prefix(14))
        Canvas { context, size in
            for (index, tower) in towers.enumerated() {
                let height = towerHeight(tower.tier)
                let rect = CGRect(
                    x: CGFloat(index) * 5 + 1,
                    y: size.height - height,
                    width: 3,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 0.75),
                    with: .color(towerColor(tower.state))
                )
            }
        }
        .frame(width: CGFloat(towers.count) * 5, height: 14)
        .accessibilityHidden(true)
    }

    private func towerHeight(_ tier: GPUTier) -> CGFloat {
        switch tier {
        case .h200: 14
        case .rtxpro6000: 12
        case .a100: 10
        case .l40s: 8
        case .l4: 6
        case .mig: 4
        }
    }

    private func towerColor(_ state: MenuBarSummary.Tower) -> Color {
        switch state {
        case .open:
            Color(red: 0.25, green: 0.78, blue: 0.48)
        case .working:
            Color(red: 0.96, green: 0.68, blue: 0.20)
        case .offline:
            .gray
        }
    }

    private func refreshLoop(_ configuration: RefreshConfiguration) async {
        await store.refresh(source: configuration.source)
        guard RefreshLoopPolicy(configuration: configuration) == .refreshAndSchedule else { return }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(RefreshLoopPolicy.automaticDelay(
                    interval: configuration.interval,
                    consecutiveFailures: store.consecutiveSnapshotFailures
                )))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await store.refresh(source: configuration.source)
        }
    }
}

struct MenuBarPanel: View {
    let store: ClusterStore
    @AppStorage("sshHost") private var sshHost = ""
    @AppStorage("statusPageURL") private var statusPageURL = ClusterSourceDefaults.statusPageURL
    @AppStorage("dataSourceKind") private var dataSourceKind = ClusterSourceKind.statusPage.rawValue
    @AppStorage("appTheme") private var appTheme = AppTheme.graphite.rawValue
    @AppStorage("refreshInterval") private var refreshInterval = 60

    private var source: ClusterSource {
        ClusterSourceResolution.source(kind: dataSourceKind, url: statusPageURL, host: sshHost)
    }

    private var palette: AppPalette { (AppTheme(rawValue: appTheme) ?? .graphite).palette }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.divider)

            if let error = store.errorMessage, !store.snapshot.nodes.isEmpty {
                errorStrip(error, lastErrorAt: store.lastErrorAt)
                Divider().overlay(palette.divider)
            }


            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !store.snapshot.pending.isEmpty {
                QueueEntranceLane(
                    jobs: store.snapshot.pending,
                    palette: palette,
                    isLastKnown: store.refreshState(
                        at: timeline.date,
                        staleAfter: Double(RefreshLoopPolicy.effectiveInterval(refreshInterval) * 2)
                    ) == .stale
                )
                Divider().overlay(palette.divider)
            }

            footer
        }
        .frame(width: 460, height: 600)
        .background(palette.background)
        .foregroundStyle(palette.primary)
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(palette.accent.opacity(0.16))
                Image(systemName: "building.2.fill")
                    .foregroundStyle(palette.accent)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Colby GPU Cluster").font(.headline)
                if store.hasLoaded, !store.snapshot.nodes.isEmpty {
                    Text(store.snapshot.queuePublished
                        ? "\(store.snapshot.freeGPUs) GPUs free · \(store.snapshot.busyCount) allocated · \(store.snapshot.pending.count) jobs queued"
                        : "\(store.snapshot.freeGPUs) GPUs free · \(store.snapshot.busyCount) allocated")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                } else if store.errorMessage != nil {
                    Text("Connection unavailable · \(source.displayName)")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                } else if store.hasLoaded {
                    Text("No GPU nodes reported · \(source.displayName)")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                } else {
                    Text("Surveying the province via \(source.displayName)")
                        .font(.caption)
                        .foregroundStyle(palette.secondary)
                }
            }
            Spacer()
            Button {
                Task {
                    await store.refresh(
                        source: source,
                        forceSlurmData: true
                    )
                }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(store.isRefreshing)
            .help("Refresh cluster state")
        }
        .padding(14)
        .background(palette.surface)
    }

    @ViewBuilder
    private var content: some View {
        if !store.hasLoaded {
            VStack(spacing: 12) {
                ProgressView()
                Text("Surveying the province via \(source.displayName)")
                    .font(.callout)
                    .foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.snapshot.nodes.isEmpty, store.errorMessage != nil {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(palette.status(.partial))
                Text("Couldn't survey the province")
                    .font(.headline)
                Text(store.errorMessage ?? "")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                retryButton(title: "Retry")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if store.snapshot.nodes.isEmpty {
            ContentUnavailableView {
                Label("No GPU districts", systemImage: "building.2")
            } description: {
                Text("No GPU nodes were reported via \(source.displayName).")
            } actions: {
                retryButton(title: "Check again")
            }
        } else {
            CitySceneView(store: store, palette: palette)
                .frame(minHeight: 360)
        }
    }

    private func retryButton(title: String) -> some View {
        Button {
            Task {
                await store.refresh(
                    source: source,
                    forceSlurmData: true
                )
            }
        } label: {
            Label(store.isRefreshing ? "Retrying…" : title, systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderedProminent)
        .disabled(store.isRefreshing)
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gear")
            }
            .buttonStyle(.plain)
            Spacer()
            if let lastSuccessfulAt = store.lastSuccessfulAt {
                Text(AppShellTimestampLabel.successPrefix) + Text(lastSuccessfulAt, style: .relative)
            }
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("Quit Colby GPU Cluster")
        }
        .font(.caption)
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(palette.surface)
    }

    private func errorStrip(_ message: String, lastErrorAt: Date?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(palette.status(.partial))
            VStack(alignment: .leading, spacing: 2) {
                Text(message).font(.caption).lineLimit(2)
                if let lastErrorAt {
                    Text(AppShellTimestampLabel.failurePrefix) + Text(lastErrorAt, style: .relative)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.status(.partial).opacity(0.12))
    }
}




private struct QueueEntranceLane: View {
    let jobs: [PendingJob]
    let palette: AppPalette
    var isLastKnown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("Entrance queue", systemImage: "signpost.right")
                if isLastKnown {
                    Label("last known", systemImage: "clock.arrow.circlepath")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(palette.status(.partial))
                }
                Spacer()
                Text("\(jobs.count) waiting")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(palette.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(jobs.prefix(5)) { job in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(carColor(for: job.user))
                                .frame(width: 6, height: 6)
                            Text(job.user)
                                .foregroundStyle(palette.primary)
                            Text(job.reason)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: 160)
                        .font(.caption2)
                        .foregroundStyle(palette.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(palette.elevated, in: Capsule())
                        .help("\(job.name) — \(job.reason) — limit \(DurationText.compact(job.limitSeconds))")
                    }

                    if jobs.count > 5 {
                        Text("+\(jobs.count - 5) more")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(palette.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(palette.elevated, in: Capsule())
                    }
                }
            }
            .mask {
                // Fade the trailing edge so a cut-off chip reads as "more".
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 24)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(jobs.count) jobs waiting at the cluster entrance")
    }
}

