---
name: colby-gpu-cluster
description: Use when an agent needs to check which GPUs are free on the Colby College HPC Slurm cluster, read the colby-gpu-status/1 JSON contract, or build, test, render and install the Colby GPU Cluster native SwiftUI macOS menu-bar app.
---

# Colby GPU Cluster

Native macOS menu-bar app (Swift 6, SwiftUI, macOS 14+, no third-party dependencies) that shows the Colby HPC Slurm GPU partition as an isometric city of nodes, running jobs and the pending queue. Source: https://github.com/bobzhou-source/colby-gpu-cluster

## Agent instructions

1. To answer "is a GPU free right now?", read the public status page https://hpc.colby.edu/public/gpu.html (no SSH, no account) instead of polling the login node.
2. Only use the SSH source if the user can already `ssh` to a login node, and keep the poll interval at or above 60 seconds. Ask the HPC admin before adding new polling.
3. Any custom status feed must emit the `colby-gpu-status/1` JSON schema: `nodes` (state, gpu_type, gpus_total, gpus_used, CPU and memory allocation, reason), `jobs` (id, state, partition, nodes, gpus, elapsed_s, time_limit_s, reason) and `reservations`. Unknown fields are ignored, so add fields without breaking older builds.
4. Build and verify from source:

```sh
git clone https://github.com/bobzhou-source/colby-gpu-cluster.git && cd colby-gpu-cluster
swift build
swift test                              # 340+ unit tests
swift run ColbyGPUCluster --preview     # panel in a normal window
python3 install_app.py                  # release .app into ~/Applications (never launches it)
```

5. For visual checks without a GUI session, render the city offline: `.build/debug/ColbyGPUCluster --render-city /tmp/city.png --city-scenario drained --city-size 460x420 --city-scale 2`.
6. Release builds are ad-hoc signed and not notarized; tell the user to right-click, Open, or run `xattr -dr com.apple.quarantine "/Applications/Colby GPU Cluster.app"`.

## Reference

| Item | Value |
|---|---|
| Default data source | https://hpc.colby.edu/public/gpu.html (30 s poll floor) |
| SSH data source | `sinfo` / `squeue` over SSH (60 s poll floor) |
| Feed schema | `colby-gpu-status/1` |
| Build | `swift build`, `swift test`, `python3 install_app.py` |

## Related

- ml-experiment Slurm control plane (retained GPU leases, vLLM, llama.cpp): https://robertzhou.dev/work/ml-experiment-slurm/
- Portfolio: https://robertzhou.dev

Author: Robert Zhou (https://robertzhou.dev) · ORCID 0009-0009-2155-7215 · Colby College
