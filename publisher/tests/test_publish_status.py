"""Tests for the Colby GPU status publisher (standard library only)."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


TESTS_DIR = Path(__file__).resolve().parent
PUBLISHER_DIR = TESTS_DIR.parent
FIXTURES_DIR = TESTS_DIR / "fixtures"

if str(PUBLISHER_DIR) not in sys.path:
    sys.path.insert(0, str(PUBLISHER_DIR))

import publish_status as ps  # noqa: E402  (path set up above)


SCHEMA = "colby-gpu-status/1"
NODE_KEYS = {
    "name",
    "state",
    "partitions",
    "gpu_type",
    "gpus_total",
    "gpus_used",
    "cpus_total",
    "cpus_alloc",
    "mem_total_mb",
    "mem_alloc_mb",
    "reason",
}
JOB_KEYS = {
    "id",
    "user",
    "name",
    "state",
    "partition",
    "nodes",
    "gpus",
    "elapsed_s",
    "time_limit_s",
    "reason",
}
RESERVATION_KEYS = {"name", "nodes", "start", "end", "users"}
VALID_STATES = {"idle", "mixed", "allocated", "drain", "down", "reserved", "unknown"}


def read_fixture(name: str) -> str:
    return (FIXTURES_DIR / name).read_text(encoding="utf-8")


def fixture_status(**kwargs) -> dict:
    return ps.build_status(
        read_fixture("sinfo.txt"),
        read_fixture("squeue.txt"),
        read_fixture("scontrol-res.txt"),
        **kwargs,
    )


def run_cli(args: list[str], env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(PUBLISHER_DIR / "publish_status.py"), *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


class TestGresParsing(unittest.TestCase):
    def test_total_from_plain_gres(self):
        self.assertEqual(ps.parse_gres("gpu:H200:4"), ("H200", 4))

    def test_total_from_socket_suffix(self):
        self.assertEqual(ps.parse_gres("gpu:h200:4(S:0-1)"), ("h200", 4))

    def test_used_from_idx_suffix(self):
        self.assertEqual(ps.parse_gres("gpu:H200:2(IDX:0-1)"), ("H200", 2))

    def test_used_from_empty_idx_list(self):
        self.assertEqual(ps.parse_gres("gpu:A100:0(IDX:N/A)"), ("A100", 0))

    def test_untyped_gres(self):
        self.assertEqual(ps.parse_gres("gpu:4"), (None, 4))

    def test_mig_profile_type(self):
        self.assertEqual(ps.parse_gres("gpu:1g.20gb:7"), ("1g.20gb", 7))

    def test_multiple_types_are_summed(self):
        self.assertEqual(ps.parse_gres("gpu:a100:2,gpu:h200:4"), ("a100", 6))

    def test_null_and_empty(self):
        for value in (None, "", "(null)", "N/A", "cpu"):
            with self.subTest(value=value):
                self.assertEqual(ps.parse_gres(value), (None, 0))

    def test_comma_inside_suffix_is_not_a_separator(self):
        self.assertEqual(ps.parse_gres("gpu:h200:4(S:0-1,2)"), ("h200", 4))


class TestStateMapping(unittest.TestCase):
    def test_known_states(self):
        cases = {
            "idle": "idle",
            "mix": "mixed",
            "mixed": "mixed",
            "alloc": "allocated",
            "comp": "allocated",
            "drain": "drain",
            "drng": "drain",
            "drned": "drain",
            "down": "down",
            "resv": "reserved",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(ps.normalize_state(raw), expected)

    def test_flags_are_stripped(self):
        cases = {
            "idle*": "idle",
            "mix~": "mixed",
            "alloc#": "allocated",
            "drng%": "drain",
            "drned!": "drain",
            "down@": "down",
            "resv^": "reserved",
            "idle-": "idle",
            "idle$": "idle",
            "idle+": "idle",
            "*~#%!@^-$+idle": "idle",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(ps.normalize_state(raw), expected)

    def test_unknown_states_are_unknown(self):
        for raw in ("boot", "maint", "future", ""):
            with self.subTest(raw=raw):
                self.assertEqual(ps.normalize_state(raw), "unknown")


class TestDurationParsing(unittest.TestCase):
    def test_days(self):
        self.assertEqual(ps.parse_duration("1-02:03:04"), 93784)
        self.assertEqual(ps.parse_duration("7-00:00:00"), 604800)

    def test_hms(self):
        self.assertEqual(ps.parse_duration("02:03:04"), 7384)
        self.assertEqual(ps.parse_duration("2:00:00"), 7200)

    def test_ms(self):
        self.assertEqual(ps.parse_duration("03:04"), 184)
        self.assertEqual(ps.parse_duration("45:00"), 2700)

    def test_minutes_only(self):
        self.assertEqual(ps.parse_duration("45"), 2700)
        self.assertEqual(ps.parse_duration("0"), 0)

    def test_unlimited_and_null(self):
        for value in ("UNLIMITED", "unlimited", "INFINITE", "(null)", "N/A", "", None, "bogus"):
            with self.subTest(value=value):
                self.assertIsNone(ps.parse_duration(value))


class TestNodeParsing(unittest.TestCase):
    def test_seven_field_line(self):
        nodes = ps.parse_sinfo("n1|idle|gpu:h200:4|0/64/0/64|515000|(null)|gpu\n")
        self.assertEqual(len(nodes), 1)
        node = nodes[0]
        self.assertEqual(node["name"], "n1")
        self.assertEqual(node["state"], "idle")
        self.assertEqual(node["gpu_type"], "h200")
        self.assertEqual(node["gpus_total"], 4)
        self.assertEqual(node["gpus_used"], 0)
        self.assertEqual(node["cpus_alloc"], 0)
        self.assertEqual(node["cpus_total"], 64)
        self.assertEqual(node["mem_total_mb"], 515000)
        self.assertEqual(node["partitions"], ["gpu"])
        self.assertIsNone(node["reason"])
        self.assertNotIn("_gres_used_present", node)

    def test_eight_field_line_with_gres_used(self):
        nodes = ps.parse_sinfo("n2|mixed|gpu:H200:4|gpu:H200:2(IDX:0-1)|32/64/0/64|515000|(null)|gpu\n")
        self.assertEqual(nodes[0]["gpus_used"], 2)
        self.assertEqual(nodes[0]["gpus_total"], 4)

    def test_gres_used_presence_map(self):
        raw = "n1|idle|gpu:h200:4|0/64/0/64|515000|(null)|gpu\n"
        raw += "n2|mixed|gpu:h200:4|gpu:h200:2|32/64/0/64|515000|(null)|gpu\n"
        present: dict = {}
        ps.parse_sinfo(raw, present)
        self.assertEqual(present, {"n1": False, "n2": True})

    def test_reason_and_flags(self):
        nodes = ps.parse_sinfo("n3|drng*|gpu:A100:2|gpu:A100:0|0/48/0/48|257000|KernelPanic|gpu\n")
        self.assertEqual(nodes[0]["state"], "drain")
        self.assertEqual(nodes[0]["reason"], "KernelPanic")

    def test_partition_star_is_stripped(self):
        nodes = ps.parse_sinfo("n4|idle|(null)|0/16/0/16|64000|(null)|gpu*,debug\n")
        self.assertEqual(nodes[0]["partitions"], ["gpu", "debug"])
        self.assertEqual(nodes[0]["gpu_type"], None)
        self.assertEqual(nodes[0]["gpus_total"], 0)

    def test_blank_and_short_lines_ignored(self):
        self.assertEqual(ps.parse_sinfo("\n  \ngarbage|line\n"), [])

    def test_duplicate_node_lines_merge(self):
        raw = "n5|idle|gpu:h200:4|0/64/0/64|515000|(null)|gpu\nn5|mix|gpu:h200:4|gpu:h200:3|32/64/0/64|515000|(null)|debug\n"
        nodes = ps.parse_sinfo(raw)
        self.assertEqual(len(nodes), 1)
        self.assertEqual(nodes[0]["partitions"], ["gpu", "debug"])
        self.assertEqual(nodes[0]["gpus_used"], 3)


class TestNodelistExpansion(unittest.TestCase):
    def test_range(self):
        self.assertEqual(ps.expand_nodelist("n[15-16]"), ["n15", "n16"])

    def test_range_with_extra(self):
        self.assertEqual(ps.expand_nodelist("n[1-2,5]"), ["n1", "n2", "n5"])

    def test_zero_padding(self):
        self.assertEqual(ps.expand_nodelist("gpu[01-03]"), ["gpu01", "gpu02", "gpu03"])

    def test_simple_and_multiple_names(self):
        self.assertEqual(ps.expand_nodelist("n1"), ["n1"])
        self.assertEqual(ps.expand_nodelist("n1,n2"), ["n1", "n2"])

    def test_empty_and_null(self):
        self.assertEqual(ps.expand_nodelist(""), [])
        self.assertEqual(ps.expand_nodelist("(null)"), [])
        self.assertEqual(ps.expand_nodelist(None), [])


class TestSqueueParsing(unittest.TestCase):
    def test_running_and_pending(self):
        jobs = ps.parse_squeue(read_fixture("squeue.txt"), "gpu")
        by_id = {job["id"]: job for job in jobs}
        self.assertEqual(by_id["1001"]["state"], "RUNNING")
        self.assertEqual(by_id["1001"]["nodes"], ["n15", "n16"])
        self.assertEqual(by_id["1001"]["gpus"], 4)
        self.assertEqual(by_id["1001"]["elapsed_s"], 93784)
        self.assertEqual(by_id["1001"]["time_limit_s"], 604800)
        self.assertIsNotNone(by_id["1001"]["start_time"])
        self.assertNotIn("start_estimate", by_id["1001"])

        self.assertEqual(by_id["1004"]["state"], "PENDING")
        self.assertEqual(by_id["1004"]["nodes"], [])
        self.assertEqual(by_id["1004"]["reason"], "Resources")
        self.assertIsNotNone(by_id["1004"]["start_estimate"])
        self.assertNotIn("start_time", by_id["1004"])
        self.assertIsNone(by_id["1005"]["time_limit_s"])

    def test_short_and_unknown_lines_ignored(self):
        self.assertEqual(ps.parse_squeue("1001|alice\n", "gpu"), [])
        long_line = "1|a|j|COMPLETING|0:01|1:00:00|1|n1|n1|2026-10-05T00:00:00|N/A|gpu:1\n"
        self.assertEqual(ps.parse_squeue(long_line, "gpu"), [])

    def test_eleven_field_lines_get_zero_gpus(self):
        line = "1|a|j|RUNNING|0:01|1:00:00|1|n1|n1|2026-10-05T00:00:00|N/A\n"
        jobs = ps.parse_squeue(line, "gpu")
        self.assertEqual(jobs[0]["gpus"], 0)


class TestReservationParsing(unittest.TestCase):
    def test_records(self):
        reservations = ps.parse_reservations(read_fixture("scontrol-res.txt"))
        self.assertEqual(len(reservations), 2)
        first = reservations[0]
        self.assertEqual(set(first), RESERVATION_KEYS)
        self.assertEqual(first["name"], "workshop")
        self.assertEqual(first["nodes"], ["n21", "n22"])
        self.assertEqual(first["users"], ["alice", "bwong"])
        for key in ("start", "end"):
            parsed = dt.datetime.fromisoformat(first[key])
            self.assertIsNotNone(parsed.utcoffset())

    def test_blank_input(self):
        self.assertEqual(ps.parse_reservations(""), [])


class TestAtomicWrite(unittest.TestCase):
    def test_writes_and_leaves_no_temp_files(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            ps.atomic_write_json(destination, {"schema": SCHEMA})
            self.assertEqual(sorted(os.listdir(directory)), ["status.json"])
            self.assertEqual(json.loads(destination.read_text(encoding="utf-8"))["schema"], SCHEMA)

    def test_overwrites_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            destination.write_text("stale", encoding="utf-8")
            ps.atomic_write_json(destination, {"schema": SCHEMA, "nodes": []})
            payload = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(payload["nodes"], [])
            self.assertEqual(sorted(os.listdir(directory)), ["status.json"])

    def test_failure_leaves_no_temp_files(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            with self.assertRaises(TypeError):
                ps.atomic_write_json(destination, {"bad": object()})
            self.assertEqual(os.listdir(directory), [])

    def test_nested_destination_is_created(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "nested" / "deeper" / "status.json"
            ps.atomic_write_json(destination, {"schema": SCHEMA})
            self.assertTrue(destination.is_file())


class TestContract(unittest.TestCase):
    def setUp(self):
        self.status = fixture_status()

    def test_top_level_shape(self):
        self.assertEqual(
            set(self.status),
            {"schema", "cluster", "generated_at", "nodes", "jobs", "reservations"},
        )
        self.assertEqual(self.status["schema"], SCHEMA)
        self.assertEqual(self.status["cluster"], "Colby HPC")
        generated = dt.datetime.fromisoformat(self.status["generated_at"])
        self.assertIsNotNone(generated.utcoffset())

    def test_cluster_is_configurable(self):
        self.assertEqual(fixture_status(cluster="Test Cluster")["cluster"], "Test Cluster")

    def test_nodes_are_contract_valid(self):
        nodes = self.status["nodes"]
        self.assertTrue(nodes)
        for node in nodes:
            with self.subTest(node=node.get("name")):
                self.assertEqual(set(node), NODE_KEYS)
                self.assertIn(node["state"], VALID_STATES)
                self.assertIsInstance(node["partitions"], list)
                self.assertIsInstance(node["gpus_total"], int)
                self.assertIsInstance(node["gpus_used"], int)
                self.assertIsInstance(node["cpus_total"], int)
                self.assertIsInstance(node["cpus_alloc"], int)
                self.assertIsInstance(node["mem_total_mb"], int)
                self.assertIsInstance(node["mem_alloc_mb"], int)
                self.assertTrue(node["gpu_type"] is None or isinstance(node["gpu_type"], str))
                self.assertTrue(node["reason"] is None or isinstance(node["reason"], str))

    def test_fixture_has_expected_nodes(self):
        by_name = {node["name"]: node for node in self.status["nodes"]}
        self.assertGreater(by_name["n15"]["gpus_total"], 0)
        self.assertEqual(by_name["n20"]["gpu_type"], "A100")
        self.assertEqual(by_name["n20"]["gpus_used"], 2)
        self.assertEqual(by_name["n21"]["state"], "drain")
        self.assertEqual(by_name["n21"]["reason"], "KernelPanic")
        self.assertEqual(by_name["n30"]["gpu_type"], "1g.20gb")
        self.assertEqual(by_name["n30"]["gpus_total"], 7)
        self.assertTrue(any(node["gpus_total"] > 0 for node in self.status["nodes"]))

    def test_jobs_are_contract_valid(self):
        states = {job["state"] for job in self.status["jobs"]}
        self.assertIn("RUNNING", states)
        self.assertIn("PENDING", states)
        for job in self.status["jobs"]:
            with self.subTest(job=job.get("id")):
                self.assertIn(job["state"], {"RUNNING", "PENDING"})
                self.assertTrue(JOB_KEYS.issubset(job))
                self.assertEqual(job["partition"], "gpu")
                self.assertIsInstance(job["gpus"], int)
                self.assertIsInstance(job["nodes"], list)
                self.assertTrue(job["elapsed_s"] is None or isinstance(job["elapsed_s"], int))
                self.assertTrue(job["time_limit_s"] is None or isinstance(job["time_limit_s"], int))
                self.assertTrue(job["reason"] is None or isinstance(job["reason"], str))
                if job["state"] == "RUNNING":
                    self.assertEqual(job["reason"], None)

    def test_partition_option_is_applied(self):
        status = fixture_status(partition="debug")
        self.assertTrue(status["jobs"])
        self.assertTrue(all(job["partition"] == "debug" for job in status["jobs"]))

    def test_reservations_are_contract_valid(self):
        reservations = self.status["reservations"]
        self.assertEqual(len(reservations), 2)
        for reservation in reservations:
            with self.subTest(reservation=reservation.get("name")):
                self.assertEqual(set(reservation), RESERVATION_KEYS)
                self.assertIsInstance(reservation["nodes"], list)
                self.assertIsInstance(reservation["users"], list)
                for key in ("start", "end"):
                    self.assertIsNotNone(dt.datetime.fromisoformat(reservation[key]).utcoffset())

    def test_running_job_gpus_are_summed_per_node_without_gres_used(self):
        sinfo = "n9|alloc|gpu:h200:8|64/128/0/128|1030000|(null)|gpu\n"
        squeue = "1|alice|a|RUNNING|1:00|1:00:00|1|n9|n9|2026-10-05T10:00:00|N/A|gpu:h200:4\n"
        status = ps.build_status(sinfo, squeue, "", partition="gpu")
        self.assertEqual(status["nodes"][0]["gpus_used"], 4)


class TestAnonymization(unittest.TestCase):
    def expected_mask(self, name: str) -> str:
        return "user-" + hashlib.sha256(name.encode("utf-8")).hexdigest()[:8]

    def test_helper_is_deterministic(self):
        protected = {"alice"}
        self.assertEqual(ps.anonymized_user("alice", protected), "alice")
        self.assertEqual(ps.anonymized_user("bwong", protected), self.expected_mask("bwong"))
        self.assertEqual(ps.anonymized_user("bwong", protected), self.expected_mask("bwong"))
        self.assertEqual(len(self.expected_mask("bwong")), len("user-") + 8)

    def test_cli_anonymize_masks_other_users_only(self):
        env = dict(os.environ, USER="alice", LOGNAME="alice")
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            result = run_cli(
                [
                    "--from-fixture-dir",
                    str(FIXTURES_DIR),
                    "--out",
                    str(destination),
                    "--anonymize-users",
                ],
                env=env,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(destination.read_text(encoding="utf-8"))
            users = {job["user"] for job in payload["jobs"]}
            self.assertIn("alice", users)
            self.assertIn(self.expected_mask("bwong"), users)
            self.assertNotIn("bwong", users)
            reservation_users = [user for res in payload["reservations"] for user in res["users"]]
            self.assertIn(self.expected_mask("cdiaz"), reservation_users)
            self.assertNotIn("cdiaz", reservation_users)
            for node in payload["nodes"]:
                self.assertEqual(set(node), NODE_KEYS)

    def test_cli_without_flag_keeps_names(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            result = run_cli(["--from-fixture-dir", str(FIXTURES_DIR), "--out", str(destination)])
            self.assertEqual(result.returncode, 0, result.stderr)
            payload = json.loads(destination.read_text(encoding="utf-8"))
            self.assertIn("bwong", {job["user"] for job in payload["jobs"]})


class TestFixtureModeCli(unittest.TestCase):
    def test_end_to_end(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            result = run_cli(["--from-fixture-dir", str(FIXTURES_DIR), "--out", str(destination)])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            payload = json.loads(destination.read_text(encoding="utf-8"))
            self.assertEqual(payload["schema"], SCHEMA)
            self.assertTrue(payload["nodes"])
            states = {job["state"] for job in payload["jobs"]}
            self.assertEqual(states, {"RUNNING", "PENDING"})
            self.assertTrue(any(node["gpus_total"] > 0 for node in payload["nodes"]))
            self.assertEqual(sorted(os.listdir(directory)), ["status.json"])

    def test_missing_fixture_reports_clear_error(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            result = run_cli(["--from-fixture-dir", directory, "--out", str(destination)])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sinfo.txt", result.stderr)
            self.assertFalse(destination.exists())

    def test_missing_fixture_dir_reports_clear_error(self):
        with tempfile.TemporaryDirectory() as directory:
            result = run_cli(
                ["--from-fixture-dir", str(Path(directory) / "nope"), "--out", str(Path(directory) / "s.json")]
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("sinfo.txt", result.stderr)

    def test_default_cluster_name_in_main(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            result = run_cli(
                ["--from-fixture-dir", str(FIXTURES_DIR), "--out", str(destination), "--cluster", "Colby Test"]
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                json.loads(destination.read_text(encoding="utf-8"))["cluster"], "Colby Test"
            )


class TestMainInProcess(unittest.TestCase):
    def test_fixture_mode_never_runs_subprocess_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            with mock.patch.object(
                ps.subprocess, "run", side_effect=AssertionError("cluster command must not run")
            ):
                code = ps.main(
                    ["--from-fixture-dir", str(FIXTURES_DIR), "--out", str(destination)]
                )
            self.assertEqual(code, 0)
            self.assertTrue(destination.is_file())

    def test_live_collection_runs_each_command_once(self):
        calls: list[list[str]] = []

        def fake_run(command, **kwargs):
            calls.append(list(command))
            return subprocess.CompletedProcess(command, 0, stdout="", stderr="")

        with mock.patch.object(ps.subprocess, "run", side_effect=fake_run):
            ps.collect_live("gpu")

        self.assertEqual(
            calls,
            [
                ["sinfo", "-p", "gpu", "-N", "-h", "-o", ps.SINFO_FORMAT],
                ["squeue", "-p", "gpu", "-h", "-o", ps.SQUEUE_FORMAT],
                ["scontrol", "show", "res"],
            ],
        )

    def test_live_collection_surfaces_command_failure(self):
        def failing_run(command, **kwargs):
            return subprocess.CompletedProcess(command, 1, stdout="", stderr="sinfo: boom")

        with mock.patch.object(ps.subprocess, "run", side_effect=failing_run):
            with self.assertRaises(ps.PublisherError) as caught:
                ps.collect_live("gpu")
        message = str(caught.exception)
        self.assertIn("sinfo", message)
        self.assertIn("boom", message)

    def test_cli_reports_command_failure(self):
        def failing_run(command, **kwargs):
            return subprocess.CompletedProcess(command, 2, stdout="", stderr="scontrol: no access")

        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / "status.json"
            stderr: list[str] = []

            with mock.patch.object(ps.subprocess, "run", side_effect=failing_run):
                with mock.patch.object(sys, "stderr", _Stderr(stderr)):
                    code = ps.main(["--out", str(destination)])
            self.assertNotEqual(code, 0)
            self.assertTrue(any("scontrol" in message for message in stderr))
            self.assertFalse(destination.exists())


class _Stderr:
    def __init__(self, sink):
        self._sink = sink

    def write(self, message):
        self._sink.append(message)


class TestHelpers(unittest.TestCase):
    def test_memory_parsing(self):
        self.assertEqual(ps.parse_memory_mb("515000"), 515000)
        self.assertEqual(ps.parse_memory_mb("64000M"), 64000)
        self.assertEqual(ps.parse_memory_mb("(null)"), 0)
        self.assertEqual(ps.parse_memory_mb("garbage"), 0)

    def test_cpu_count_parsing(self):
        self.assertEqual(ps.parse_cpu_counts("16/64/0/64"), (16, 64))
        self.assertEqual(ps.parse_cpu_counts("0/64/0/64"), (0, 64))
        self.assertEqual(ps.parse_cpu_counts("bogus"), (0, 0))

    def test_iso_conversion(self):
        converted = ps.to_iso8601("2026-10-05T14:30:00")
        self.assertIsNotNone(dt.datetime.fromisoformat(converted).utcoffset())
        self.assertEqual(ps.to_iso8601("N/A"), None)
        self.assertEqual(ps.to_iso8601("(null)"), None)
        self.assertEqual(ps.to_iso8601(""), None)
        self.assertEqual(ps.to_iso8601("not-a-time"), None)

    def test_iso_conversion_keeps_offset(self):
        self.assertEqual(ps.to_iso8601("2026-10-05T14:30:00+02:00"), "2026-10-05T14:30:00+02:00")


if __name__ == "__main__":
    unittest.main()
