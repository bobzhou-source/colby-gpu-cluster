# publisher

`publish_status.py` is a dependency-free Python 3 publisher that turns live Slurm
state into a single JSON document for the Colby GPU Cluster macOS app (and any
other consumer of the `colby-gpu-status/1` contract). It uses the standard
library only — no `pip install`, no third-party imports.

## What it does

On each invocation it runs **exactly three commands, once each**:

| Command | Purpose |
|---|---|
| `sinfo -p <partition> -N -h -o '%N\|%t\|%G\|%C\|%m\|%E\|%P'` | per-node state, GRES, CPUs, memory, reason |
| `squeue -p <partition> -h -o '%i\|%u\|%j\|%T\|%M\|%l\|%D\|%N\|%R\|%S\|%V\|%b'` | running/pending jobs and their GRES |
| `scontrol show res` | reservations |

Raw stdout is parsed and written as one JSON object:

```json
{
  "schema": "colby-gpu-status/1",
  "cluster": "Colby HPC",
  "generated_at": "2026-10-05T14:30:00-04:00",
  "nodes": [{"name": "n15", "state": "mixed", "partitions": ["gpu"], "gpu_type": "h200",
             "gpus_total": 4, "gpus_used": 2, "cpus_total": 64, "cpus_alloc": 32,
             "mem_total_mb": 515000, "mem_alloc_mb": 0, "reason": null}],
  "jobs": [{"id": "1001", "user": "alice", "name": "train-h200", "state": "RUNNING",
            "partition": "gpu", "nodes": ["n15", "n16"], "gpus": 4, "elapsed_s": 93784,
            "time_limit_s": 604800, "start_time": "2026-10-04T12:26:56-04:00", "reason": null}],
  "reservations": [{"name": "workshop", "nodes": ["n21", "n22"],
                    "start": "2026-10-15T14:00:00-04:00",
                    "end": "2026-10-15T18:00:00-04:00", "users": ["alice", "bwong"]}]
}
```

Parsing notes:

* Node states are normalized to `idle`, `mixed`, `allocated`, `drain`, `down`,
  `reserved` or `unknown`; Slurm flag characters (`*~#%!@^-$+`) are stripped.
* GRES is summed across multiple entries (`gpu:a100:2,gpu:h200:4` → 6) and
  tolerates socket/IDX suffixes such as `gpu:h200:4(S:0-1)` and
  `gpu:H200:2(IDX:0-1)`; `(null)` and empty values become `0`.
* Compressed nodelists (`n[1-2,5]`) are expanded.
* Slurm durations (`D-HH:MM:SS`, `HH:MM:SS`, `MM:SS`, `MM`, `UNLIMITED`) are
  converted to seconds; `UNLIMITED` becomes `null`.
* All timestamps are emitted as ISO8601 with a timezone offset (naive Slurm
  timestamps are interpreted as local time).
* When `sinfo` reports an explicit GresUsed value it wins; otherwise a node's
  `gpus_used` is the sum of its running jobs' GPUs.

## Usage

```bash
# default: writes ./status.json, partition "gpu", cluster "Colby HPC"
python3 publish_status.py

# explicit destination and cluster label
python3 publish_status.py --out /var/www/html/colby-gpu-status/status.json --cluster "Colby HPC"

# different partition
python3 publish_status.py --partition debug
```

Options: `--out PATH`, `--cluster NAME`, `--partition NAME`,
`--anonymize-users`, `--from-fixture-dir DIR`.

The output is written atomically: a temporary file is created in the destination
directory and then `os.replace()`d onto `--out`, so consumers never observe a
partially written document. Exit status is `0` on success and nonzero (with a
message on stderr) if a command fails, a fixture file is missing, or the output
cannot be written.

### `--anonymize-users`

Every username other than the invoking user (`$USER` / `getpass.getuser()`) is
replaced with a deterministic `user-<8 hex chars of sha256>` label in both
`jobs[].user` and `reservations[].users`. The publisher's own user is preserved so
the app can still highlight the current user's jobs. Use this when the JSON is
served to a wider audience and other users' names should not be exposed.

### `--from-fixture-dir DIR` (dev flag)

Reads captured command output verbatim from `DIR` instead of contacting a
cluster, so the publisher and the app can be exercised with no Slurm access:

```
DIR/sinfo.txt         # output of the sinfo command
DIR/squeue.txt        # output of the squeue command
DIR/scontrol-res.txt  # output of scontrol show res
```

```bash
python3 publish_status.py --from-fixture-dir tests/fixtures --out /tmp/status.json
```

The fixture capture in `tests/fixtures` includes an optional GresUsed column
(fourth field of each `sinfo.txt` line) to exercise the used-GPU parsing path
offline. Both the plain and the extended line shapes are accepted.

## Tests

Standard library `unittest`; the suite never contacts a cluster or the network.

```bash
# from the repo root
python3 -m unittest discover -s publisher/tests -v

# from this directory
python3 -m unittest discover -s tests -v
# or simply
python3 -m unittest
```

## Scheduling

The app expects a fresh document roughly every minute.

### cron

```cron
* * * * * cd /path/to/publisher && /usr/bin/python3 publish_status.py --out /var/www/html/colby-gpu-status/status.json
```

### systemd

`/etc/systemd/system/colby-gpu-status.service`

```ini
[Unit]
Description=Publish Colby GPU Slurm status JSON

[Service]
Type=oneshot
WorkingDirectory=/path/to/publisher
ExecStart=/usr/bin/python3 /path/to/publisher/publish_status.py --out /var/www/html/colby-gpu-status/status.json
User=slurm-publisher
```

`/etc/systemd/system/colby-gpu-status.timer`

```ini
[Unit]
Description=Refresh Colby GPU status every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
```

Enable with `systemctl enable --now colby-gpu-status.timer`.

If the JSON is published to a world-readable location, run with
`--anonymize-users` so only the publishing account's username appears.
