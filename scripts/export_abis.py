#!/usr/bin/env python3
"""Export (or check) public ABIs using the pinned Foundry build. No third-party Python packages."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ("LaunchToken", "EventCheckin")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Fail if an ABI export is missing or stale")
    args = parser.parse_args()
    for name in CONTRACTS:
        result = subprocess.run(
            ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        data = json.dumps(json.loads(result.stdout), indent=2) + "\n"
        destination = ROOT / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not destination.exists() or destination.read_text() != data:
                print(f"Stale or missing ABI: {destination.relative_to(ROOT)}", file=sys.stderr)
                return 1
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(data)
        print(f"{'Verified' if args.check else 'Exported'} {destination.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
