#!/usr/bin/env python3
"""Validate one external evidence tar against its versioned gate contract."""

from __future__ import annotations

import argparse
from pathlib import Path
import sys

sys.dont_write_bytecode = True

from release_common import ROOT, ReleaseError, read_json
from release_external_evidence import verify_external_artifact


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--gate", required=True)
    parser.add_argument("--revision", required=True)
    parser.add_argument("--artifact", required=True, type=Path)
    arguments = parser.parse_args()
    root = arguments.root.resolve()
    try:
        verify_external_artifact(
            arguments.artifact,
            arguments.gate,
            arguments.revision,
            read_json(root / "release/gates.json"),
            read_json(root / "release/dependencies.json"),
            read_json(root / "release/support-matrix.json"),
            source_root=root,
        )
    except ReleaseError as error:
        print(f"external evidence: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
