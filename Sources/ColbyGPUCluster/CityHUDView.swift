import AppKit
import SwiftUI

struct CityHUDModel: Equatable, Sendable {
    struct JobRow: Identifiable, Equatable, Sendable {
        let id: String
        let user: String
        let name: String
        /// Compact `elapsed / limit` for the row; the limit is a wall-clock
        /// bound, never progress, which `timingDetail` spells out on hover.
        let timingText: String
        let timingDetail: String
    }

    let nodeName: String
    let tierText: String
    let districtSubtitle: String?
    let statusText: String
    let statusIcon: String
    let statusKey: NodeStatus
    let unavailabilityReason: String?
    let jobRows: [JobRow]
    let command: String

    /// Per-GPU plot occupancy is a synthetic assignment: SLURM GresUsed counts
    /// don't identify hardware indices, so the plot ordinal is inferred. The
    /// caveat lives in tooltips so the rows themselves stay scannable.
    static let inferredPlotHelp = "Plot position is inferred from the scheduler's allocation count; SLURM does not report which physical GPU is in use."

    init(plot: CityPlot, sshHost: String = "") {
        let node = plot.node
        nodeName = node.name
        tierText = GPUTier(rawValue: node.profile)?.shortLabel ?? node.gpuType
        districtSubtitle = plot.gpuCount > 1
            ? "Plot \(plot.gpuIndex) of \(plot.gpuCount) · \(node.gpuType)"
            : nil
        statusText = node.freeInText
        statusKey = node.status
        statusIcon = Self.statusIcon(for: node.status)
        switch node.status {
        case .drain:
            unavailabilityReason = node.stateLabel
        case .unknown:
            unavailabilityReason = node.state.isEmpty
                ? "Scheduler did not report a state"
                : "Unrecognized scheduler state: \(node.stateLabel)"
        default:
            unavailabilityReason = nil
        }
        jobRows = node.jobs.map { job in
            JobRow(
                id: job.id,
                user: job.user,
                name: job.name,
                timingText: Self.jobTimingText(job),
                timingDetail: Self.jobTimingDetail(job)
            )
        }
        command = "ssh \(Self.shellQuote(sshHost)) 'sinfo -p gpu -N -h'"
    }

    static func jobTimingText(_ job: ClusterJob) -> String {
        let elapsed = job.elapsedSeconds.map(DurationText.compact) ?? "—"
        guard let limitSeconds = job.limitSeconds, limitSeconds > 0 else { return "\(elapsed) · no limit" }
        return "\(elapsed) / \(DurationText.compact(limitSeconds))"
    }

    /// Elapsed/limit is a wall-clock bound, not measured completion: the
    /// hover text labels the time-limit fraction explicitly.
    static func jobTimingDetail(_ job: ClusterJob) -> String {
        let elapsed = job.elapsedSeconds.map(DurationText.compact) ?? "Unknown time"
        guard let limitSeconds = job.limitSeconds, limitSeconds > 0 else { return "\(elapsed) elapsed · no time limit reported" }
        return "\(elapsed) elapsed · \(DurationText.compact(limitSeconds)) wall-clock limit"
    }

    static func statusIcon(for status: NodeStatus) -> String {
        switch status {
        case .idle: "checkmark.circle"
        case .partial: "circle.lefthalf.filled"
        case .busy: "person.wave.2"
        case .drain: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

/// Measured `nvidia-smi` telemetry for one scheduler node, rendered natively so
/// the inspector and standalone captures share one truthful presentation.
///
/// Map plot ordinals are inferred from GresUsed counts while sampled GPU
/// indices are hardware facts, so the two are never joined: every number here
/// is node-scoped and labelled as such. Missing values stay missing — nothing
/// is substituted with zero, and no bar implies job completion.
struct GPUTelemetrySummaryView: View {
    let snapshot: GPUTelemetrySnapshot
    let nodeName: String
    let now: Date

    init(snapshot: GPUTelemetrySnapshot, nodeName: String, now: Date = Date()) {
        self.snapshot = snapshot
        self.nodeName = nodeName
        self.now = now
    }

    var body: some View {
        let node = snapshot.nodes[nodeName]
        let freshness = snapshot.freshness(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Node GPU activity")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("Whole-node nvidia-smi reading for \(nodeName); individual plots are not measured.")
                Spacer(minLength: 8)
                Text(Self.compactSampleText(freshness: freshness, sampledAt: snapshot.sampledAt, now: now))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Self.tint(freshness))
                    .lineLimit(1)
                    .help(Self.sampleStatusText(freshness: freshness, sampledAt: snapshot.sampledAt, now: now))
            }

            if let node {
                InspectorRow("Utilization", Self.utilizationText(node))
                    .help(node.utilizationPercent == nil
                          ? "No sampled GPU on this node reported utilization"
                          : "Mean of the sampled GPUs that reported utilization")
                if node.isPartial {
                    InspectorRow("Reporting", Self.coverageText(node))
                }
                ForEach(Self.metricRows(node), id: \.label) { row in
                    InspectorRow(row.label, row.value)
                }
            } else {
                Text("No sample for this node")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let readError = snapshot.readError {
                Label("Source unreadable", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(Self.staleTint)
                    .help(readError)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Measured GPU telemetry for node \(nodeName)")
    }

    private static let staleTint = Color.orange

    static func tint(_ freshness: GPUTelemetryFreshness) -> Color {
        switch freshness {
        case .fresh: .green
        case .stale: staleTint
        case .unavailable: .secondary
        }
    }

    /// Current reading versus a retained older one: the wording never claims
    /// "now" for a sample the reader could not confirm as current.
    static func sampleStatusText(
        freshness: GPUTelemetryFreshness,
        sampledAt: Date?,
        now: Date
    ) -> String {
        guard let sampledAt else { return "No sample time reported — measurement unknown" }
        let age = ageText(sampledAt: sampledAt, now: now)
        switch freshness {
        case .fresh: return "Current · sampled \(age)"
        case .stale: return "Last known · sampled \(age)"
        case .unavailable: return "Not current · sampled \(age)"
        }
    }

    /// Row-sized age for the section header; the full sentence stays on hover.
    static func compactSampleText(
        freshness: GPUTelemetryFreshness,
        sampledAt: Date?,
        now: Date
    ) -> String {
        guard let sampledAt else { return "No sample" }
        let age = ageText(sampledAt: sampledAt, now: now)
        switch freshness {
        case .fresh: return age
        case .stale: return "Last known · \(age)"
        case .unavailable: return "Not current"
        }
    }

    /// Ages against the caller's timeline date, not the wall clock, so frozen
    /// and captured frames report the age their own frame represents.
    static func ageText(sampledAt: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(sampledAt)
        guard seconds >= 0 else { return "\(DurationText.compact(Int(-seconds))) ahead of this Mac's clock" }
        return "\(DurationText.compact(Int(seconds))) ago"
    }

    static func utilizationText(_ node: GPUNodeTelemetry) -> String {
        guard let utilization = node.utilizationPercent else { return "Not reported" }
        return String(format: "%.0f%%", utilization)
    }

    /// Shown only for partial coverage: with every GPU reporting there is
    /// nothing to qualify.
    static func coverageText(_ node: GPUNodeTelemetry) -> String {
        "\(node.reportingDeviceCount) of \(node.deviceCount) GPUs"
    }

    /// Only aggregates the telemetry model already vouched for as complete.
    static func metricRows(_ node: GPUNodeTelemetry) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let used = node.memoryUsedMiB, let total = node.memoryTotalMiB, total > 0 {
            rows.append(("Memory", String(format: "%.0f / %.0f GiB", used / 1_024, total / 1_024)))
        }
        if let power = node.powerDrawWatts {
            rows.append(("Power", String(format: "%.0f W", power)))
        }
        if let temperature = node.temperatureCelsius {
            rows.append(("Peak temp", String(format: "%.0f °C", temperature)))
        }
        return rows
    }
}

/// Label/value line shared by the scheduler and telemetry sections so values
/// align in one column and numbers keep tabular widths.
private struct InspectorRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
        }
    }

}

struct CityHUDView: View {
    let plot: CityPlot
    let isStale: Bool
    let lastSuccessfulAt: Date?
    let sshHost: String
    let gpuTelemetry: GPUTelemetrySnapshot
    /// SSH-only affordances (the ready-made status command, measured telemetry)
    /// are hidden for a published status feed, which cannot supply either.
    let showsSSHDetails: Bool
    let now: Date
    let onDismiss: () -> Void

    @State private var copied = false

    init(
        plot: CityPlot,
        isStale: Bool,
        lastSuccessfulAt: Date? = nil,
        sshHost: String,
        gpuTelemetry: GPUTelemetrySnapshot = .empty,
        showsSSHDetails: Bool = true,
        now: Date = Date(),
        onDismiss: @escaping () -> Void
    ) {
        self.plot = plot
        self.isStale = isStale
        self.lastSuccessfulAt = lastSuccessfulAt
        self.sshHost = sshHost
        self.gpuTelemetry = gpuTelemetry
        self.showsSSHDetails = showsSSHDetails
        self.now = now
        self.onDismiss = onDismiss
    }

    var model: CityHUDModel {
        CityHUDModel(plot: plot, sshHost: sshHost)
    }

    var body: some View {
        let model = self.model
        VStack(alignment: .leading, spacing: 12) {
            header(model: model)

            if isStale {
                staleBanner
            }

            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(model.statusText)
                        .font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: model.statusIcon)
                }
                .foregroundStyle(Self.statusColor(model.statusKey))

                schedulerSummary(model: model)
            }

            // Measured telemetry is its own section so allocation is never
            // read as GPU activity. A published feed carries none, so it is
            // omitted rather than shown empty.
            if showsSSHDetails {
                GPUTelemetrySummaryView(snapshot: gpuTelemetry, nodeName: model.nodeName, now: now)
            }

            jobsSection(model: model)

            if showsSSHDetails {
                Divider()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy status command", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help(model.command)
            }
        }
        .padding(12)
        .frame(width: 280, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.nodeName) inspector")
    }

    private func header(model: CityHUDModel) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.nodeName)
                        .font(.headline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(model.tierText)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.12), in: Capsule())
                }
                if let districtSubtitle = model.districtSubtitle {
                    Text(districtSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(CityHUDModel.inferredPlotHelp)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss inspector")
        }
    }

    /// What the scheduler claims: allocation counts and, for this plot, an
    /// inferred occupancy that is never presented as a measurement.
    @ViewBuilder
    private func schedulerSummary(model: CityHUDModel) -> some View {
        if let reason = model.unavailabilityReason {
            // `drain` is this app's umbrella for every unallocatable state
            // SLURM reports (drain, down, maintenance, reserved); the label
            // keeps the scheduler's own state text verbatim.
            Label(reason, systemImage: model.statusKey == .drain ? "exclamationmark.triangle" : "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help(model.statusKey == .drain ? "Scheduler state, shown verbatim" : reason)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                InspectorRow("Free GPUs", "\(plot.node.freeGPUCount) of \(plot.node.totalGPUCount)")
                InspectorRow("This plot", plot.mode == .vacant ? "Free" : "Allocated")
                    .help(CityHUDModel.inferredPlotHelp)
            }
        }
    }

    private func jobsSection(model: CityHUDModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Jobs")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(model.jobRows.isEmpty ? Self.noJobsText(for: model.statusKey) : "\(model.jobRows.count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if model.jobRows.count > Self.visibleJobRows {
                ScrollView {
                    jobList(model.jobRows)
                }
                .frame(height: CGFloat(Self.visibleJobRows) * Self.jobRowHeight)
            } else if !model.jobRows.isEmpty {
                jobList(model.jobRows)
            }
        }
    }

    private func jobList(_ rows: [CityHUDModel.JobRow]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { job in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(job.user) · \(job.name)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(job.timingText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(height: Self.jobRowHeight)
                .help("\(job.user) · \(job.name)\n\(job.timingDetail)")
            }
        }
    }

    private static let visibleJobRows = 3
    private static let jobRowHeight: CGFloat = 20

    private var staleBanner: some View {
        Label {
            if let lastSuccessfulAt {
                Text("Last known · updated ") + Text(lastSuccessfulAt, style: .relative)
            } else {
                Text("Last known · may be outdated")
            }
        } icon: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Self.staleColor)
        .lineLimit(1)
    }

    private static func statusColor(_ status: NodeStatus) -> Color {
        switch status {
        case .idle: .green
        case .partial: .orange
        case .busy: .orange
        case .drain: .gray
        case .unknown: .secondary
        }
    }

    private static let staleColor = Color.orange

    /// Trailing text for an empty job list; each state says why nothing is
    /// listed without a sentence.
    private static func noJobsText(for status: NodeStatus) -> String {
        switch status {
        case .drain: "None reported"
        case .unknown: "Unknown"
        case .busy, .partial: "Not reported"
        case .idle: "None"
        }
    }
}
