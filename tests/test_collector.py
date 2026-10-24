"""Exercise the actual collector using an allowlisted PATH and synthetic input."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CollectorTests(unittest.TestCase):
    def collect(self, fixture: dict, cli: str = "oc") -> tuple[dict, list[list[str]]]:
        jq = Path(
            os.environ.get("COLLECTOR_TEST_JQ", str(ROOT / ".tools/jq"))
        ).resolve()
        self.assertTrue(jq.is_file(), "Run make setup or supply COLLECTOR_TEST_JQ")
        with tempfile.TemporaryDirectory(prefix="collector-synthetic-") as temporary:
            home = Path(temporary)
            binaries = home / "bin"
            binaries.mkdir()
            # No general-purpose PATH fallback: real cluster clients cannot run.
            for name in (
                "bash",
                "date",
                "mktemp",
                "rm",
                "head",
                "sort",
                "uniq",
                "grep",
                "sed",
            ):
                executable = shutil.which(name)
                self.assertIsNotNone(executable, f"Missing test prerequisite: {name}")
                (binaries / name).symlink_to(executable)
            (binaries / "jq").symlink_to(jq)
            fake = binaries / cli
            fake.write_text(
                f"#!{sys.executable}\n" + (ROOT / "tests/fake_cli.py").read_text()
            )
            fake.chmod(0o700)
            data = home / "fixture.json"
            data.write_text(json.dumps(fixture))
            log = home / "calls.jsonl"
            environment = {
                "HOME": str(home),
                "PATH": str(binaries),
                "LANG": "C",
                "TMPDIR": str(home),
                "KUBECONFIG": str(home / "absent-kubeconfig"),
                "FAKE_CLI_FIXTURE": str(data),
                "FAKE_CLI_LOG": str(log),
            }
            result = subprocess.run(
                [str(binaries / "bash"), str(ROOT / "collect-cluster-shape.sh")],
                cwd=home,
                env=environment,
                capture_output=True,
                text=True,
                timeout=30,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            for call in calls:
                self.assertTrue(
                    call[:1] == ["get"]
                    or call == ["version", "--client", "-o", "json"]
                    or (call[:2] == ["auth", "can-i"] and call[2] in {"get", "list"}),
                    "Collector attempted an operation outside the read-only contract",
                )
            self.assertFalse(any(p.name.startswith("tmp.") for p in home.iterdir()))
            if fixture.get("unreachable"):
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("cannot reach the cluster API server", result.stderr)
                return {}, calls
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, "")
            return json.loads(result.stdout), calls

    def test_unknown_diagnostics_never_leave_the_collector(self) -> None:
        diagnostic = (
            "account synthetic-user@example.invalid on api.example.invalid "
            "at [2001:db8::17] via https://api.example.invalid:6443 and 192.0.2.17 "
            'User "synthetic-' + "x" * 600 + '"'
        )
        document, _ = self.collect({"error": diagnostic})
        for section in (document["nodes"], document["security"]["scc_usage"]):
            self.assertEqual(
                section,
                {
                    "status": "error",
                    "data": None,
                    "message": "resource read failed; inspect the CLI locally",
                },
            )
        encoded = json.dumps(document)
        for marker in (
            "example.invalid",
            "2001:db8",
            "192.0.2",
            "synthetic-user",
            "synthetic-xxx",
        ):
            self.assertNotIn(marker, encoded)

    def test_expected_gaps_remain_fixed_and_distinct(self) -> None:
        cases = (
            ('Forbidden for User "synthetic-private"', "forbidden"),
            (
                'the server doesn\'t have a resource type "synthetic-private"',
                "api_not_found",
            ),
        )
        for diagnostic, status in cases:
            with self.subTest(status=status):
                document, _ = self.collect({"error": diagnostic})
                self.assertEqual(document["nodes"]["status"], status)
                self.assertIsNone(document["nodes"]["data"])
                self.assertNotIn("synthetic-private", json.dumps(document))
                self.assertTrue(
                    all(not check["allowed"] for check in document["rbac_preflight"])
                )

    def test_projection_errors_have_no_raw_jq_diagnostic(self) -> None:
        document, _ = self.collect(
            {
                "resources": {
                    "nodes": {"items": "private-synthetic-value"},
                    "clusterroles": {"items": "private-synthetic-role"},
                },
                "scc_usage": "",
            }
        )
        self.assertEqual(
            document["nodes"],
            {
                "status": "error",
                "data": None,
                "message": "section transformation failed",
            },
        )
        self.assertNotIn("private-synthetic", json.dumps(document))
        self.assertNotIn("jq:", json.dumps(document))
        self.assertEqual(document["security"]["scc_rbac_grants"], document["nodes"])
        self.assertEqual(
            document["security"]["scc_usage"],
            {"status": "ok", "data": {"pods_per_scc": {}}},
        )

    def test_success_minimizes_identifiers_and_supports_kubectl(self) -> None:
        resources = {
            "nodes": {
                "items": [
                    {
                        "metadata": {
                            "name": "private-synthetic-node.example.invalid",
                            "labels": {
                                "node-role.kubernetes.io/master": "",
                                "node-role.kubernetes.io/worker": "",
                            },
                        },
                        "status": {
                            "addresses": [
                                {"type": "InternalIP", "address": "192.0.2.42"}
                            ],
                            "nodeInfo": {
                                "architecture": "amd64",
                                "osImage": "SyntheticOS",
                            },
                            "capacity": {"cpu": "4", "memory": "16Gi", "pods": "100"},
                            "allocatable": {"cpu": "3", "memory": "12Gi"},
                        },
                    }
                ]
            },
            "storageclasses": {
                "items": [
                    {
                        "metadata": {"name": "synthetic-class"},
                        "provisioner": "synthetic.csi",
                        "parameters": {
                            "server": "private-synthetic-storage.example.invalid"
                        },
                    }
                ]
            },
            "scc": {
                "items": [
                    {
                        "metadata": {"name": "restricted-synthetic"},
                        "users": ["private-synthetic-user"],
                        "groups": ["private-synthetic-group"],
                    }
                ]
            },
        }
        document, calls = self.collect({"resources": resources}, cli="kubectl")
        self.assertEqual(document["meta"]["cli"], "kubectl")
        self.assertEqual(document["nodes"]["data"][0]["id"], "node-0")
        self.assertEqual(
            document["topology"]["data"]["ha_classification"], "single-node"
        )
        self.assertEqual(
            document["storage_classes"]["data"][0]["parameter_keys"], ["server"]
        )
        self.assertEqual(
            document["security"]["scc_definitions"]["data"][0]["granted_users_count"], 1
        )
        self.assertEqual(
            document["security"]["scc_usage"]["data"]["pods_per_scc"],
            {"restricted-synthetic": 2},
        )
        self.assertNotIn("private-synthetic", json.dumps(document))
        self.assertNotIn("192.0.2.42", json.dumps(document))
        self.assertIn(["get", "--raw", "/version"], calls)

    def test_unreachable_cluster_stops_before_collection(self) -> None:
        _, calls = self.collect({"unreachable": True})
        self.assertEqual(calls, [["get", "--raw", "/version"]])

    def test_schema_version_and_guidance_are_consistent(self) -> None:
        source = (ROOT / "collect-cluster-shape.sh").read_text()
        version = source.split('SCHEMA_VERSION="', 1)[1].split('"', 1)[0]
        self.assertIn(f"Schema version: {version}", (ROOT / "SCHEMA.md").read_text())
        self.assertEqual((ROOT / "CLAUDE.md").read_text().strip(), "@AGENTS.md")
        for name in (
            "README.md",
            "SCHEMA.md",
            "AGENTS.md",
            "CONTRIBUTING.md",
            "SECURITY.md",
        ):
            self.assertTrue((ROOT / name).is_file(), name)


if __name__ == "__main__":
    unittest.main()
