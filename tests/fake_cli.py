"""Synthetic collector CLI. No subprocess, network or real kubeconfig access."""

import json
import os
from pathlib import Path
import sys


def main() -> int:
    args = sys.argv[1:]
    with Path(os.environ["FAKE_CLI_LOG"]).open("a") as handle:
        handle.write(json.dumps(args) + "\n")
    fixture = json.loads(Path(os.environ["FAKE_CLI_FIXTURE"]).read_text())
    if args == ["get", "--raw", "/version"]:
        return 1 if fixture.get("unreachable") else 0
    if args == ["version", "--client", "-o", "json"]:
        print('{"clientVersion":{"gitVersion":"synthetic"}}')
        return 0
    if args[:2] == ["auth", "can-i"] and args[2] in {"get", "list"}:
        print("no" if fixture.get("error") else "yes")
        return 0
    if args[:1] != ["get"] or len(args) < 2:
        return 90
    if fixture.get("error"):
        print(fixture["error"], file=sys.stderr)
        return 1
    if args[1] == "pods":
        print(fixture.get("scc_usage", "restricted-synthetic\nrestricted-synthetic"))
        return 0
    print(
        json.dumps(
            fixture.get("resources", {}).get(
                args[1], {"items": [], "spec": {}, "status": {}, "metadata": {}}
            )
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
