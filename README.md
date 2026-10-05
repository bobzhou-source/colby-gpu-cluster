# Colby GPU Cluster

A native macOS menu-bar app that shows what the Colby HPC GPU partition is doing
right now — which nodes are free, what is running, and what is queued — as an
isometric city you can pan, zoom, and click.

It exists so Colby students and researchers stop SSH-polling the login node just
to find out whether a GPU is free. It is a single Swift package with no
third-party dependencies, no Python, and no background service.

<!-- Screenshots -->

## Screenshots

_Placeholder — screenshots of the menu bar, the province/city/street zoom bands,
and the node inspector go here._

<!-- /Screenshots -->

## Install

### From a release

1. Download the latest `.app` (or the release `.zip`) from
   [Releases](../../releases).
2. Move `Colby GPU Cluster.app` to `/Applications` (or `~/Applications`).
3. Launch it. It lives in the menu bar, not the Dock.

The app is unsigned, so the first launch may need **System Settings → Privacy &
Security → Open Anyway**.

### From source

Requires macOS 14 or newer and a Swift 6 toolchain (Xcode 16 or the matching
command-line tools).

```bash
git clone https://github.com/bobzhou-source/colby-gpu-cluster.git
cd colby-gpu-cluster
swift build
swift run ColbyGPUCluster --preview   # opens the panel in a normal window
swift test                             # 340+ unit tests
```

To build a real `.app` bundle in `~/Applications`:

```bash
python3 install_app.py
```

`install_app.py` is a small stdlib-only helper: it runs `swift build -c release`,
stages a bundle with the icon, ad-hoc signs it, and installs it. It never
launches the app and only writes to the output directory you give it
(`--output-dir`, default `~/Applications`).

## Data sources

The first run opens Settings with nothing configured. Pick one of the two
sources:

| Source | What it needs | Poll floor | Notes |
|---|---|---|---|
| **Status page URL** (recommended) | A URL serving `colby-gpu-status/1` JSON | 30 s | No SSH login, no cluster account, no key. Set this and you are done. |
| **SSH** | A login node you can already reach with `ssh` | 60 s | Runs SLURM commands over SSH. Ask the HPC admin before polling the login node. |

Both sources feed the same city view. If a URL is set, the status page is used;
otherwise the app falls back to SSH. The picker in **Settings → Connection**
chooses explicitly, and the **Active** row shows which source is really in use.

### Status page

Your HPC admin can publish the feed with the script in
[`publisher/`](publisher/README.md). It runs `sinfo`, `squeue`, and
`scontrol show res` once per invocation and atomically writes `status.json`, so
a 60-second cron or systemd timer costs the cluster three short commands a
minute. Point the app at that URL.

The copy-ready `sinfo` command in a node's inspector is SSH-only, so it is
hidden when you use a status page — there is no SSH host to run it against.
Measured telemetry is a local file you choose, so it appears for either source
whenever a reading is attached.

### SSH

The SSH source reports these two commands on every refresh, and nothing else:

```bash
sinfo -p gpu -N -h --Format='NodeHost:|,StateCompact:|,Gres:|,GresUsed:'
squeue -p gpu -h -o '%i|%u|%j|%T|%M|%l|%D|%N|%R'
```

After a *successful* snapshot it also collects lower-frequency SLURM detail
(`scontrol`, `sacctmgr`, `sacct`, `sprio`, `sdiag`) on independent caches:
nodes/resources, active jobs, and priority scheduling every 60 s; step/runtime
and scheduler diagnostics every 5 min; accounting and policy every 30 min;
controller configuration, partitions, and the resource catalog hourly. A failed
snapshot suppresses all of it, so an unreachable host costs at most one
connection attempt per backoff period. The full command list is
[`Sources/ColbyGPUCluster/SlurmDataCommands.swift`](Sources/ColbyGPUCluster/SlurmDataCommands.swift).

All of those commands travel over a single authenticated SSH connection that the
app multiplexes itself (`ControlMaster=auto`, `ControlPersist=8h`, socket under
the app's own cache directory) — one login, reused for every poll, and closed
when you quit.

### Refresh and backoff

Automatic refresh never runs more often than the source's floor (30 s for a
status page, 60 s for SSH) and the default is 60 s. Consecutive failures back
off exponentially — doubling per failure up to a 15-minute ceiling — and reset
on the next success. The refresh button always runs immediately.

### Privacy

- The app only reads. It never submits jobs, never writes to the cluster, and
  has no telemetry or analytics of its own.
- **Status page mode** makes exactly one HTTPS request per poll to the URL you
  configured. No SSH connection is made at all.
- **SSH mode** opens *one* SSH connection — the first poll authenticates, and
  every later poll reuses it over the same channel, so you get one login, reused.
  That is done with `-o ControlMaster=auto -o ControlPath=~/Library/Caches/edu.colby.gpu-cluster.community/ssh-%C -o ControlPersist=8h`,
  created 0700, because most users do not have `ControlMaster` in
  `~/.ssh/config`. Quitting the app asks the shared connection to exit
  (`ssh -O exit`), so nothing is left logged in. Your SSH keys and
  configuration are used as-is; the app does not store credentials.
- The optional **Telemetry** file is a local JSON file you choose. Leaving the
  path empty disables the feature entirely; the app has no built-in file
  location and never writes to it.

## What you are looking at

The menu bar shows `free/total` GPU units, not nodes. `total` counts every
recognized resource (including MIG slices); `free` comes from the scheduler's
allocation counts. If a refresh fails after a successful one, the last-good data
stays visible and is labelled **last known**.

The map moves between **province**, **city**, and **street** zoom bands. Drag to
pan; scroll, pinch, or use the bottom-left controls to zoom. At city or street
zoom, click a GPU plot to open its inspector and double-click to focus it.

Operational state is part of the architecture:

- **Allocated** — warm workshop glazing, lit entrances, rooftop extractors.
- **Free** — intact, quiet buildings with open loading doors.
- **Unavailable** — scaffolds, ladders, netting, and striped barriers. This
  covers drain, down, maintenance, and reserved states; the inspector keeps the
  scheduler's own state label.
- **Unknown** — desaturated, veiled buildings.

Allocation is not compute utilization: a fully allocated node can still report
0% GPU activity. The inspector separates the two, and missing readings stay
unknown rather than becoming zero.

Settings also manages theme, a 24-hour day/night preview, start-at-login, and
refresh cadence.

## Repository layout

```
Sources/ColbyGPUCluster/    the app: data sources, SLURM parsing, city renderer
Tests/ColbyGPUClusterTests/ unit tests, including the status-feed contract fixture
publisher/                  dependency-free status.json publisher for the admin
install_app.py              build + install the .app bundle
```

## Offline visual verification

Render the city from a synthetic snapshot without touching any data source:

```bash
swift build
.build/debug/ColbyGPUCluster --render-city /tmp/colby-drained.png \
  --city-scenario drained --city-size 460x420 --city-scale 2 \
  --city-zoom 16 --city-focus n1 --city-t 0.55 --city-date 1788998400
```

The `allocated`, `free`, `drained`, and `unknown` scenarios hold the featured
`n1` plot's massing and the surrounding atlas constant. Use `--city-t 0.95` for
night. Character close-ups use `--city-focus-kaiju`, `--city-focus-titan`,
`--city-focus-ufo`, or `--city-focus-balloon` instead of `--city-focus n1`.

## Data contract

Any status page must return `colby-gpu-status/1`:

```json
{
  "schema": "colby-gpu-status/1",
  "cluster": "Colby HPC",
  "generated_at": "2026-10-05T14:30:00-04:00",
  "nodes": [
    {"name": "n1", "state": "mixed", "partitions": ["gpu"], "gpu_type": "H200",
     "gpus_total": 4, "gpus_used": 2, "cpus_total": 64, "cpus_alloc": 16,
     "mem_total_mb": 750000, "mem_alloc_mb": 128000, "reason": null}
  ],
  "jobs": [
    {"id": "17251", "user": "alice", "name": "protein-fold-sweep",
     "state": "RUNNING", "partition": "gpu", "nodes": ["n1"], "gpus": 1,
     "elapsed_s": 52400, "time_limit_s": 86400,
     "start_time": "2026-10-04T23:57:00-04:00", "reason": null}
  ],
  "reservations": [
    {"name": "maint", "nodes": ["n15"], "start": "2026-10-05T13:10:00-04:00",
     "end": "2026-10-15T14:00:00-04:00", "users": ["admin"]}
  ]
}
```

Unknown fields are ignored and missing optional fields are tolerated, so the
publisher can add fields without breaking older app builds.

## License

MIT — see [LICENSE](LICENSE).
