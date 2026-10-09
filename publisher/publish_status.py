#!/usr/bin/env python3
"""Publish a JSON snapshot of Colby GPU Slurm status.

The script runs ``sinfo``, ``squeue`` and ``scontrol show res`` exactly once
each, parses the captured text and writes the ``colby-gpu-status/1`` document
described in the app contract.  Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import datetime as dt
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Iterable, Optional


SCHEMA = "colby-gpu-status/1"
NULL_VALUES = {"", "(null)", "null", "none", "n/a", "unknown", "invalid"}
STATE_FLAGS = "*~#%!@^-$+"
CPU_COUNT_RE = re.compile(r"^\d+/\d+/\d+/\d+$")
DURATION_RE = re.compile(r"^(?:(\d+)-)?(\d+)(?::(\d+))?(?::(\d+))?$")

STATE_MAP = {
    "idle": "idle",
    "mix": "mixed",
    "mixed": "mixed",
    "alloc": "allocated",
    "allocated": "allocated",
    "comp": "allocated",
    "completing": "allocated",
    "drain": "drain",
    "drng": "drain",
    "drned": "drain",
    "drained": "drain",
    "down": "down",
    "resv": "reserved",
    "reserved": "reserved",
}

SINFO_FORMAT = "%N|%t|%G|%C|%m|%E|%P"
SQUEUE_FORMAT = "%i|%u|%j|%T|%M|%l|%D|%N|%R|%S|%V|%b"
FIXTURE_FILENAMES = ("sinfo.txt", "squeue.txt", "scontrol-res.txt")


class PublisherError(RuntimeError):
    """An error whose message is safe to show on the command line."""


def is_null(value: Optional[str]) -> bool:
    return value is None or value.strip().lower() in NULL_VALUES


def normalize_state(value: str) -> str:
    """Map a Slurm state word (flags stripped) onto the contract vocabulary."""
    state = value.strip().translate(str.maketrans("", "", STATE_FLAGS)).lower()
    return STATE_MAP.get(state, "unknown")


def parse_duration(value: Optional[str]) -> Optional[int]:
    """Parse a Slurm duration into seconds.

    Accepts ``D-HH:MM:SS``, ``HH:MM:SS``, ``MM:SS`` and bare minutes, plus the
    ``UNLIMITED``/``INFINITE`` sentinels (which become ``None``).
    """
    if value is None:
        return None
    text = value.strip()
    if is_null(text) or text.upper() in {"UNLIMITED", "INFINITE"}:
        return None
    match = DURATION_RE.match(text)
    if match is None:
        return None
    days_text, first, second, third = match.groups()
    days = int(days_text) if days_text else 0
    if third is not None:
        hours, minutes, seconds = int(first), int(second or 0), int(third)
    elif second is not None:
        hours, minutes, seconds = 0, int(first), int(second)
    else:
        hours, minutes, seconds = 0, int(first), 0
    return days * 86400 + hours * 3600 + minutes * 60 + seconds


def _split_top_level(value: str, open_char: str, close_char: str, separator: str = ",") -> list[str]:
    """Split on ``separator`` only when outside ``open_char``/``close_char``."""
    pieces: list[str] = []
    depth = 0
    start = 0
    for index, character in enumerate(value):
        if character == open_char:
            depth += 1
        elif character == close_char and depth:
            depth -= 1
        elif character == separator and depth == 0:
            pieces.append(value[start:index])
            start = index + 1
    pieces.append(value[start:])
    return pieces


def parse_gres(value: Optional[str]) -> tuple[Optional[str], int]:
    """Return ``(representative_type, total_count)`` for a GRES string.

    Handles ``(null)``/empty, socket/IDX suffixes such as ``gpu:h200:4(S:0-1)``
    and ``gpu:H200:2(IDX:0-1)``, untyped ``gpu:4``, the ``gres/`` prefix that
    ``squeue %b`` prints on Colby (``gres/gpu:H200:2``) and multiple entries
    such as ``gpu:a100:2,gpu:h200:4`` (counts are summed; the first *named*
    type wins).
    """
    if is_null(value):
        return None, 0

    gpu_type: Optional[str] = None
    total = 0
    for item in _split_top_level(value or "", "(", ")"):
        base = item.strip().split("(", 1)[0].strip()
        if base.lower().startswith("gres/"):
            base = base[len("gres/"):]
        fields = base.split(":")
        if not fields or fields[0].lower() != "gpu":
            continue
        if len(fields) == 2 and fields[1].isdigit():
            item_type, count_text = None, fields[1]
        elif len(fields) >= 3 and fields[-1].isdigit():
            item_type, count_text = fields[-2], fields[-1]
        else:
            continue
        if gpu_type is None and item_type:
            gpu_type = item_type
        total += int(count_text)
    return gpu_type, total


def parse_cpu_counts(value: str) -> tuple[int, int]:
    """``%C`` is ``alloc/idle/other/total`` -> ``(cpus_alloc, cpus_total)``."""
    fields = value.strip().split("/")
    if len(fields) != 4:
        return 0, 0
    try:
        return int(fields[0]), int(fields[3])
    except ValueError:
        return 0, 0


def parse_memory_mb(value: Optional[str]) -> int:
    if is_null(value):
        return 0
    match = re.match(r"\s*(\d+(?:\.\d+)?)", value or "")
    return int(float(match.group(1))) if match else 0


def parse_partitions(value: Optional[str]) -> list[str]:
    if is_null(value):
        return []
    return [part.strip().rstrip("*") for part in (value or "").split(",") if part.strip().rstrip("*")]


def _split_nodelist(value: str) -> list[str]:
    return _split_top_level(value, "[", "]")


def expand_nodelist(value: Optional[str]) -> list[str]:
    """Expand a Slurm nodelist, including compressed forms like ``n[1-2,5]``."""
    if is_null(value):
        return []
    text = (value or "").strip()
    pieces = _split_nodelist(text)
    if len(pieces) > 1:
        expanded: list[str] = []
        for piece in pieces:
            expanded.extend(expand_nodelist(piece))
        return expanded

    left = text.find("[")
    if left < 0:
        return [text]
    right = text.find("]", left)
    if right < 0:
        return [text]

    prefix, body, suffix = text[:left], text[left + 1:right], text[right + 1:]
    remainders = [suffix] if suffix == "" else expand_nodelist(suffix)
    results: list[str] = []
    for selection in body.split(","):
        first, dash, last = selection.partition("-")
        if dash and first.isdigit() and last.isdigit():
            width = max(len(first), len(last))
            for number in range(int(first), int(last) + 1):
                for remainder in remainders:
                    results.append(f"{prefix}{number:0{width}d}{remainder}")
        else:
            for remainder in remainders:
                results.append(f"{prefix}{selection}{remainder}")
    return results


def to_iso8601(value: Optional[str]) -> Optional[str]:
    """Convert a Slurm timestamp to ISO8601; naive timestamps get local tz."""
    if is_null(value):
        return None
    text = (value or "").strip()
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.astimezone()
    return parsed.isoformat(timespec="seconds")


def parse_sinfo(raw: str, gres_used_present: Optional[dict] = None) -> list[dict]:
    """Parse ``sinfo -N -h`` lines into node records.

    Two shapes are accepted: the plain ``%N|%t|%G|%C|%m|%E|%P`` capture, and an
    extended capture with an explicit GresUsed column inserted after ``%G``.

    When ``gres_used_present`` is supplied it is filled with ``name -> bool``,
    recording which nodes reported an explicit GresUsed value.
    """
    nodes: dict[str, dict] = {}
    present: dict = {} if gres_used_present is None else gres_used_present
    for line in raw.splitlines():
        if not line.strip():
            continue
        fields = line.rstrip("\n").split("|")
        if len(fields) == 7:
            name, state, gres, cpu, memory, reason, partitions = fields
            gres_used, has_gres_used = "", False
        elif len(fields) >= 8:
            name, state, gres, gres_used, cpu, memory, reason, partitions = fields[:8]
            has_gres_used = True
        else:
            continue

        name = name.strip()
        if not name:
            continue

        gpu_type, gpus_total = parse_gres(gres)
        _, gpus_used_gres = parse_gres(gres_used)
        cpus_alloc, cpus_total = parse_cpu_counts(cpu)
        record = {
            "name": name,
            "state": normalize_state(state),
            "partitions": parse_partitions(partitions),
            "gpu_type": gpu_type,
            "gpus_total": gpus_total,
            "gpus_used": gpus_used_gres,
            "cpus_total": cpus_total,
            "cpus_alloc": cpus_alloc,
            "mem_total_mb": parse_memory_mb(memory),
            "mem_alloc_mb": 0,
            "reason": None if is_null(reason) else reason.strip(),
        }

        present[name] = present.get(name, False) or has_gres_used
        existing = nodes.get(name)
        if existing is None:
            nodes[name] = record
            continue
        existing["partitions"] = list(dict.fromkeys(existing["partitions"] + record["partitions"]))
        existing["gpus_total"] = max(existing["gpus_total"], record["gpus_total"])
        existing["gpus_used"] = max(existing["gpus_used"], record["gpus_used"])
        existing["cpus_total"] = max(existing["cpus_total"], record["cpus_total"])
        existing["cpus_alloc"] = max(existing["cpus_alloc"], record["cpus_alloc"])
        existing["mem_total_mb"] = max(existing["mem_total_mb"], record["mem_total_mb"])
        if existing["gpu_type"] is None:
            existing["gpu_type"] = record["gpu_type"]
        if existing["reason"] is None:
            existing["reason"] = record["reason"]

    return list(nodes.values())


def _normalize_job_state(value: str) -> Optional[str]:
    state = value.strip().upper()
    state = {"R": "RUNNING", "PD": "PENDING"}.get(state, state)
    return state if state in {"RUNNING", "PENDING"} else None


def _clean_reason(value: Optional[str]) -> Optional[str]:
    if is_null(value):
        return None
    text = (value or "").strip()
    if text.startswith("(") and text.endswith(")"):
        text = text[1:-1].strip()
    return text or None


def parse_squeue(raw: str, partition: str) -> list[dict]:
    """Parse ``squeue -h -o ...`` lines, guarding on field count."""
    jobs: list[dict] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        fields = line.rstrip("\n").split("|")
        if len(fields) < 11:
            continue
        job_id, user, name, state, elapsed, limit, _node_count, node_list, reason, start, expected = fields[:11]
        normalized = _normalize_job_state(state)
        if normalized is None:
            continue

        gpus = 0
        if len(fields) >= 12:
            _, gpus = parse_gres(fields[11])

        job = {
            "id": job_id.strip(),
            "user": user.strip(),
            "name": name.strip(),
            "state": normalized,
            "partition": partition,
            "nodes": expand_nodelist(node_list) if normalized == "RUNNING" else [],
            "gpus": gpus,
            "elapsed_s": parse_duration(elapsed),
            "time_limit_s": parse_duration(limit),
            "reason": None if normalized == "RUNNING" else _clean_reason(reason),
        }
        if normalized == "RUNNING":
            job["start_time"] = to_iso8601(start)
        else:
            job["start_estimate"] = to_iso8601(expected)
        jobs.append(job)
    return jobs


def parse_reservations(raw: str) -> list[dict]:
    """Parse ``scontrol show res`` records (blank-line separated Key=Value)."""
    records: list[dict[str, str]] = []
    current: dict[str, str] = {}
    for match in re.finditer(r"(?:^|\s)([A-Za-z][A-Za-z0-9_]*)=(\S+)", raw):
        key, value = match.group(1), match.group(2)
        if key == "ReservationName" and current:
            records.append(current)
            current = {}
        current[key] = value
    if current:
        records.append(current)

    reservations: list[dict] = []
    for record in records:
        name = record.get("ReservationName", "").strip()
        start = to_iso8601(record.get("StartTime"))
        end = to_iso8601(record.get("EndTime"))
        if not name or start is None or end is None:
            continue
        users_value = record.get("Users", "")
        if is_null(users_value) or users_value.upper() == "ALL":
            users: list[str] = []
        else:
            users = [user for user in users_value.split(",") if user]
        reservations.append({
            "name": name,
            "nodes": expand_nodelist(record.get("Nodes")),
            "start": start,
            "end": end,
            "users": users,
        })
    return reservations


def _protected_users() -> set[str]:
    users: set[str] = set()
    try:
        users.add(getpass.getuser())
    except (OSError, KeyError):
        pass
    for variable in ("USER", "LOGNAME"):
        if os.environ.get(variable):
            users.add(os.environ[variable])
    return users


def anonymized_user(user: str, protected: Iterable[str]) -> str:
    if user in protected:
        return user
    return "user-" + hashlib.sha256(user.encode("utf-8")).hexdigest()[:8]


def anonymize_status_users(status: dict) -> None:
    protected = _protected_users()
    for job in status["jobs"]:
        job["user"] = anonymized_user(job["user"], protected)
    for reservation in status["reservations"]:
        reservation["users"] = [anonymized_user(user, protected) for user in reservation["users"]]


def apply_job_gpu_usage(nodes: list[dict], jobs: list[dict], gres_used_present: dict) -> None:
    """Fall back to per-node GPU usage summed from running jobs.

    When ``sinfo`` reported an explicit GresUsed column for a node it wins;
    otherwise the running-job GRES counts are the best available estimate.
    """
    running_by_node: dict[str, int] = {}
    for job in jobs:
        if job["state"] != "RUNNING":
            continue
        for node_name in job["nodes"]:
            running_by_node[node_name] = running_by_node.get(node_name, 0) + job["gpus"]
    for node in nodes:
        if not gres_used_present.get(node["name"], False):
            node["gpus_used"] = running_by_node.get(node["name"], 0)


def build_status(
    sinfo_raw: str,
    squeue_raw: str,
    reservations_raw: str,
    *,
    cluster: str = "Colby HPC",
    partition: str = "gpu",
    anonymize_users: bool = False,
    now: Optional[dt.datetime] = None,
) -> dict:
    gres_used_present: dict = {}
    nodes = parse_sinfo(sinfo_raw, gres_used_present)
    jobs = parse_squeue(squeue_raw, partition)
    apply_job_gpu_usage(nodes, jobs, gres_used_present)
    timestamp = now or dt.datetime.now()
    status = {
        "schema": SCHEMA,
        "cluster": cluster,
        "generated_at": timestamp.astimezone().isoformat(timespec="seconds"),
        "nodes": nodes,
        "jobs": jobs,
        "reservations": parse_reservations(reservations_raw),
    }
    if anonymize_users:
        anonymize_status_users(status)
    return status


def collect_live(partition: str) -> tuple[str, str, str]:
    """Run each collector exactly once and return their raw stdout."""
    commands = [
        ["sinfo", "-p", partition, "-N", "-h", "-o", SINFO_FORMAT],
        ["squeue", "-p", partition, "-h", "-o", SQUEUE_FORMAT],
        ["scontrol", "show", "res"],
    ]
    outputs: list[str] = []
    failures: list[str] = []
    for command in commands:
        try:
            completed = subprocess.run(command, capture_output=True, text=True, check=False)
        except OSError as error:
            outputs.append("")
            failures.append(f"{' '.join(command)}: {error}")
            continue
        outputs.append(completed.stdout)
        if completed.returncode != 0:
            detail = completed.stderr.strip() or f"exit status {completed.returncode}"
            failures.append(f"{' '.join(command)}: {detail}")
    if failures:
        raise PublisherError("command failed: " + "; ".join(failures))
    return outputs[0], outputs[1], outputs[2]


def collect_fixtures(directory: Path) -> tuple[str, str, str]:
    """Read captured command output verbatim from a fixture directory."""
    contents: list[str] = []
    for filename in FIXTURE_FILENAMES:
        path = directory / filename
        try:
            contents.append(path.read_text(encoding="utf-8"))
        except FileNotFoundError as error:
            raise PublisherError(f"missing fixture file: {path}") from error
        except OSError as error:
            raise PublisherError(f"could not read fixture file {path}: {error}") from error
    return contents[0], contents[1], contents[2]


def atomic_write_json(path: Path, payload: dict) -> None:
    """Write JSON next to the destination and atomically replace it."""
    path = path.expanduser()
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: Optional[str] = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=str(path.parent),
            prefix=f".{path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary:
            temporary_name = temporary.name
            json.dump(payload, temporary, indent=2)
            temporary.write("\n")
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Publish Colby GPU Slurm status as JSON.")
    parser.add_argument("--out", type=Path, default=Path("status.json"), help="output JSON path (default: ./status.json)")
    parser.add_argument("--cluster", default="Colby HPC", help="cluster display name (default: Colby HPC)")
    parser.add_argument("--partition", default="gpu", help="Slurm partition to query (default: gpu)")
    parser.add_argument("--anonymize-users", action="store_true", help="hash users other than the invoking user")
    parser.add_argument("--from-fixture-dir", type=Path, help="dev flag: read sinfo/squeue/scontrol captures from DIR")
    return parser.parse_args(argv)


def main(argv: Optional[list[str]] = None) -> int:
    args = parse_args(argv)
    try:
        if args.from_fixture_dir is None:
            sinfo_raw, squeue_raw, reservations_raw = collect_live(args.partition)
        else:
            sinfo_raw, squeue_raw, reservations_raw = collect_fixtures(args.from_fixture_dir)
        status = build_status(
            sinfo_raw,
            squeue_raw,
            reservations_raw,
            cluster=args.cluster,
            partition=args.partition,
            anonymize_users=args.anonymize_users,
        )
        atomic_write_json(args.out, status)
    except (PublisherError, OSError, ValueError) as error:
        print(f"publish_status.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
