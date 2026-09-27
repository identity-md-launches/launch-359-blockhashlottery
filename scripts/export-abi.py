#!/usr/bin/env python3
"""Export the two deployable ABIs, or check that the committed exports match."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for name in ("LaunchToken", "BlockhashLottery"):
        result = subprocess.run(
            ["forge", "inspect", f"src/{name}.sol:{name}", "abi", "--json"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        abi = json.loads(result.stdout)
        destination = root / "docs" / "abi" / f"{name}.json"
        if args.check:
            if not destination.exists() or json.loads(destination.read_text()) != abi:
                raise SystemExit(f"ABI export is stale: {destination.relative_to(root)}")
            print(f"Verified {destination.relative_to(root)}")
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(json.dumps(abi, indent=2) + "\n")
            print(f"Exported {destination.relative_to(root)}")


if __name__ == "__main__":
    main()
