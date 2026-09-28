#!/usr/bin/env python3
"""Generate nix/bun-deps.nix from assets/bun.lock.

Bun records an SRI integrity hash for every package, which is exactly what
fetchurl wants, so the Nix build needs no separate lockfile and no network
access. Run this whenever assets/bun.lock changes:

    python3 scripts/bun2nix.py
"""

import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
LOCK = ROOT / "assets" / "bun.lock"
OUT = ROOT / "nix" / "bun-deps.nix"
REGISTRY = "https://registry.npmjs.org"


def load(path):
    raw = path.read_text()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return json.loads(re.sub(r",(\s*[}\]])", r"\1", raw))


def segments(key):
    """node_modules path for a lockfile key, honouring scopes and nesting."""
    parts = key.split("/")
    names, index = [], 0

    while index < len(parts):
        if parts[index].startswith("@") and index + 1 < len(parts):
            names.append(f"{parts[index]}/{parts[index + 1]}")
            index += 2
        else:
            names.append(parts[index])
            index += 1

    return "/node_modules/".join(names)


def tarball(spec):
    name, _, version = spec.rpartition("@")

    if not name:
        raise ValueError(f"cannot split {spec!r}")

    return f"{REGISTRY}/{name}/-/{name.split('/')[-1]}-{version}.tgz", name, version


def binaries(metadata, path):
    declared = metadata.get("bin") if isinstance(metadata, dict) else None

    if isinstance(declared, str):
        return {path.split("/")[-1]: declared}

    return declared if isinstance(declared, dict) else {}


def main():
    lock = load(LOCK)
    entries = []

    for key, value in sorted(lock.get("packages", {}).items()):
        spec, _registry, metadata, integrity = value[0], value[1], value[2], value[3]

        if not integrity.startswith("sha512-"):
            sys.exit(f"{key}: unsupported integrity {integrity!r}")

        url, _name, _version = tarball(spec)
        path = segments(key)
        entries.append((path, url, integrity, binaries(metadata, path)))

    lines = [
        "# Generated from assets/bun.lock by scripts/bun2nix.py — do not edit.",
        "[",
    ]

    for path, url, integrity, bins in entries:
        rendered = " ".join(f'{{ name = "{name}"; path = "{target}"; }}' for name, target in sorted(bins.items()))
        lines.append(
            f'  {{ path = "{path}"; url = "{url}"; hash = "{integrity}";'
            + (f" bins = [ {rendered} ];" if bins else " bins = [ ];")
            + " }"
        )

    lines.append("]")
    OUT.write_text("\n".join(lines) + "\n")
    print(f"wrote {OUT.relative_to(ROOT)} with {len(entries)} packages")


if __name__ == "__main__":
    main()
