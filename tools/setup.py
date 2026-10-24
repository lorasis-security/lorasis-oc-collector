"""Install checksum-verified development binaries, never cluster clients."""

import hashlib
import io
import json
import os
import platform
from pathlib import Path
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
MAX_BYTES = 32 * 1024 * 1024


def main() -> None:
    lock = json.loads((ROOT / "tools/tools.lock.json").read_text())
    origins = {
        "shellcheck": "https://github.com/koalaman/shellcheck/releases/download/",
        "jq": "https://github.com/jqlang/jq/releases/download/",
    }
    if set(lock["tools"]) != set(origins):
        raise SystemExit("Unexpected tool names in the lockfile.")
    if f"{platform.system()}-{platform.machine()}" != lock["platform"]:
        raise SystemExit("Setup supports Linux x86_64; see README for tool overrides.")
    cache = ROOT / ".tools"
    if cache.is_symlink():
        raise SystemExit("Refusing a symlinked tool cache.")
    cache.mkdir(exist_ok=True)
    for name, spec in lock["tools"].items():
        if not spec["url"].startswith(origins[name]):
            raise SystemExit(f"{name}: unexpected release origin")
        archive = cache / f"{name}.download"
        if archive.is_symlink():
            raise SystemExit("Refusing a symlinked tool download.")
        if archive.exists():
            if archive.stat().st_size > MAX_BYTES:
                raise SystemExit(f"{name}: cached download exceeds size limit")
            data = archive.read_bytes()
        else:
            with urllib.request.urlopen(spec["url"], timeout=60) as response:
                data = response.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES or hashlib.sha256(data).hexdigest() != spec["sha256"]:
            raise SystemExit(f"{name}: download checksum or size refused")
        if not archive.exists():
            # Exclusive creation preserves any concurrently created local file.
            with archive.open("xb") as handle:
                handle.write(data)
        if "member" in spec:
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:xz") as package:
                member = package.getmember(spec["member"])
                if not member.isfile() or member.size > MAX_BYTES:
                    raise SystemExit(f"{name}: archive member refused")
                handle = package.extractfile(member)
                assert handle is not None
                with handle:
                    data = handle.read(MAX_BYTES + 1)
        target = cache / name
        if target.is_symlink() or (
            target.exists()
            and (target.stat().st_size != len(data) or target.read_bytes() != data)
        ):
            raise SystemExit(f"{name}: refusing to overwrite a different local tool")
        if not target.exists():
            with tempfile.NamedTemporaryFile(dir=cache, delete=False) as handle:
                temporary = Path(handle.name)
                handle.write(data)
            try:
                temporary.chmod(0o755)
                # An exclusive link avoids replacing another writer's target.
                os.link(temporary, target)
            finally:
                temporary.unlink()
        print(f"{name} {spec['version']}: verified")


if __name__ == "__main__":
    main()
