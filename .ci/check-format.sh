#!/bin/bash
set -euo pipefail

test -x "${SWIFTFORMAT_BIN:?set pinned formatter path}"
if [ -n "${GITHUB_BASE_REF:-}" ]; then
  base="$(git merge-base HEAD "refs/remotes/origin/$GITHUB_BASE_REF")"
else
  base="$(git rev-parse HEAD^)"
fi
export FORMAT_BASE="$base"

python3 - <<'PY'
import os
from pathlib import Path
import subprocess

changed = subprocess.check_output([
    "git", "diff", "--name-only", "--diff-filter=ACMRT", "-z",
    os.environ["FORMAT_BASE"], "HEAD", "--",
]).split(b"\0")
blocked = [
    os.fsdecode(path) for path in changed if path
    and any(part.endswith(".lproj") and part != "en.lproj"
            for part in Path(os.fsdecode(path)).parts[:-1])
]
if blocked:
    raise SystemExit("Non-English translations belong in Weblate: " + ", ".join(blocked))
files = [
    os.fsdecode(path) for path in changed if path
    and path.endswith(b".swift")
    and not path.startswith(b"fastlane/")
    and Path(os.fsdecode(path)).is_file()
]
print(f"Checking {len(files)} changed Swift file(s) with pinned SwiftFormat", flush=True)
if files:
    subprocess.run([
        os.environ["SWIFTFORMAT_BIN"], *files, "--lint", "--config",
        ".ci/swiftformat-0.61.conf",
    ], check=True)
PY
