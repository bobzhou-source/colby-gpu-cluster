import ServiceManagement
import SwiftUI

enum LaunchAtLoginServiceStatus {
    case enabled
    case requiresApproval
    case disabled
}

enum LaunchAtLoginToggleState: Equatable {
    case enabled
    case approvalPending
    case disabled

    init(serviceStatus: LaunchAtLoginServiceStatus) {
        switch serviceStatus {
        case .enabled:
            self = .enabled
        case .requiresApproval:
            self = .approvalPending
        case .disabled:
            self = .disabled
        }
    }

    var isOn: Bool {
        self != .disabled
    }

    static var current: Self {
        switch SMAppService.mainApp.status {
        case .enabled:
            .enabled
        case .requiresApproval:
            .approvalPending
        default:
            .disabled
        }
    }
}


struct AppSettingsView: View {
    @AppStorage("sshHost") private var sshHost = ""
    @AppStorage("statusPageURL") private var statusPageURL = ClusterSourceDefaults.statusPageURL
    @AppStorage("dataSourceKind") private var dataSourceKind = ClusterSourceKind.statusPage.rawValue
    @AppStorage("autoRefresh") private var autoRefresh = true
    @AppStorage("refreshInterval") private var refreshInterval = 60
    @AppStorage("appTheme") private var appTheme = AppTheme.graphite.rawValue
    @AppStorage("cityCycleDemo") private var cityCycleDemo = false
    @AppStorage(GPUTelemetrySettings.pathKey) private var gpuTelemetryPath = ""
    @AppStorage(GPUTelemetrySettings.hostKey) private var gpuTelemetryHost = GPUTelemetrySettings.defaultHost
    @State private var launchAtLoginState = LaunchAtLoginToggleState.current
    @State private var launchAtLoginError: String?
    @State private var store = ClusterStore.shared
    @State private var telemetryReloadTask: Task<Void, Never>?

    private var source: ClusterSource {
        ClusterSourceResolution.source(kind: dataSourceKind, url: statusPageURL, host: sshHost)
    }

    private var refreshMinimum: Int {
        RefreshLoopPolicy.minimumInterval(forSource: source)
    }

    private var activeSourceDescription: String {
        guard source.isConfigured else { return "Not configured" }
        return source.usesSSH ? "SSH · \(source.displayName)" : "Status page · \(source.displayName)"
    }

    private var effectiveRefreshInterval: Int {
        RefreshLoopPolicy.effectiveInterval(refreshInterval, minimum: refreshMinimum)
    }

    private var refreshIntervalBinding: Binding<Int> {
        Binding(
            get: { effectiveRefreshInterval },
            set: { refreshInterval = $0 }
        )
    }

    var body: some View {
        TabView {
            Form {
                Section("Data source") {
                    Picker("Source", selection: $dataSourceKind) {
                        ForEach(ClusterSourceKind.allCases, id: \.rawValue) { kind in
                            Text(kind.title).tag(kind.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(
                        "Status page URL",
                        text: $statusPageURL,
                        prompt: Text(ClusterSourceDefaults.statusPageURL)
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("Recommended. Colby HPC's public GPU page, or any colby-gpu-status/1 JSON feed; needs no SSH login and no cluster account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField(
                        "SSH host",
                        text: $sshHost,
                        prompt: Text("login-node.example.edu")
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("Runs `sinfo` and `squeue` over SSH on every poll. Ask the HPC admin before polling the login node.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("Active") {
                        Text(activeSourceDescription)
                            .font(.caption)
                            .foregroundStyle(source.isConfigured ? Color.secondary : Color.orange)
                    }
                }

                Section("Refresh") {
                    Toggle("Refresh automatically", isOn: $autoRefresh)
                    Stepper(
                        "Every \(effectiveRefreshInterval) seconds",
                        value: refreshIntervalBinding,
                        in: refreshMinimum...RefreshLoopPolicy.maximumInterval,
                        step: 30
                    )
                        .disabled(!autoRefresh)
                    Text("Failures back off up to 15 minutes. Status pages can be polled at 30 s; SSH polls at 60 s or slower.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Startup") {
                    Toggle(
                        "Start at login",
                        isOn: Binding(
                            get: { launchAtLoginState.isOn },
                            set: { setLaunchAtLogin($0) }
                        )
                    )
                    if let launchAtLoginError {
                        Text(launchAtLoginError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Connection", systemImage: "network") }

            Form {
                Section("Visualization") {
                    Picker("Theme", selection: $appTheme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    Toggle(isOn: $cityCycleDemo) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Preview day/night cycle")
                            Text("Cycles the city through 24h every 90 seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
                Section("Measured GPU telemetry") {
                    TextField(
                        "Telemetry file",
                        text: $gpuTelemetryPath,
                        prompt: Text("~/path/to/gpu-telemetry.json")
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("Optional. Pick a local JSON file to read; leaving this empty disables measured telemetry. This app only ever reads it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Feed's cluster", text: $gpuTelemetryHost)
                        .textFieldStyle(.roundedBorder)
                    Text("Readings apply only while the connection's host matches this one, so one cluster's measurements are never shown for another. On a status-page source, set it to the host the feed describes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("No collection starts here: nothing polls the GPUs on this app's behalf. Until another tool writes a newer sample, the last reading stays visible and is labelled last known, never refreshed in place.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Current source") {
                    telemetryStatus
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Telemetry", systemImage: "waveform.path.ecg") }
            .task { await store.refreshGPUTelemetry(host: telemetryHost) }
        }
        // Attached to the whole window: the connection fields live on another tab, and
        // an unselected tab's modifiers do not run.
        .onChange(of: gpuTelemetryPath) { _, _ in reloadTelemetry() }
        .onChange(of: gpuTelemetryHost) { _, _ in reloadTelemetry(afterTyping: false) }
        .onChange(of: sshHost) { _, _ in reloadTelemetry(afterTyping: false) }
        .onChange(of: statusPageURL) { _, _ in reloadTelemetry(afterTyping: false) }
        .onChange(of: dataSourceKind) { _, _ in reloadTelemetry(afterTyping: false) }
        .scenePadding()
        .frame(width: 470, height: 392)
    }

    /// Source visibility: the file actually read, when its sample was taken,
    /// and why a reading is missing. Aged against a ticking timeline so an
    /// idle Settings window never keeps calling an old sample current.
    private var telemetryStatus: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            let snapshot = store.gpuTelemetry
            let freshness = snapshot.freshness(at: timeline.date)
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent("File") {
                    Text(snapshot.sourcePath ?? GPUTelemetryReader.resolvedPath(gpuTelemetryPath))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Text(GPUTelemetrySummaryView.sampleStatusText(
                    freshness: freshness,
                    sampledAt: snapshot.sampledAt,
                    now: timeline.date
                ))
                .font(.caption.monospaced())
                .foregroundStyle(GPUTelemetrySummaryView.tint(freshness))
                Text(snapshot.nodes.isEmpty
                     ? "No node measurements in this reading"
                     : "\(snapshot.nodes.count) node\(snapshot.nodes.count == 1 ? "" : "s") measured")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let readError = snapshot.readError {
                    Text("Last read failed: \(readError)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
                if isHostMismatched {
                    Text("Telemetry is hidden: set the feed's cluster so it matches the connection's host.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Read source again") { reloadTelemetry(afterTyping: false) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The host a stored reading is attributed to, mirroring `ClusterStore`.
    private var telemetryHost: String {
        switch source {
        case let .ssh(host):
            return host.trimmingCharacters(in: .whitespacesAndNewlines)
        case .statusPage:
            return gpuTelemetryHost.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private var isHostMismatched: Bool {
        let feed = gpuTelemetryHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gpuTelemetryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard !feed.isEmpty else { return true }
        if case let .ssh(host) = source {
            return host.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(feed) != .orderedSame
        }
        return false
    }

    /// Settings changes only re-read the configured file; they never start a
    /// collection run on the cluster. Typed edits settle briefly first so one
    /// keystroke per character does not mean one file read per character.
    private func reloadTelemetry(afterTyping: Bool = true) {
        telemetryReloadTask?.cancel()
        let host = telemetryHost
        telemetryReloadTask = Task {
            if afterTyping {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
            }
            await store.refreshGPUTelemetry(host: host)
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginState = .current
            launchAtLoginError = nil
        } catch {
            launchAtLoginState = .current
            launchAtLoginError = error.localizedDescription
        }
    }
}
