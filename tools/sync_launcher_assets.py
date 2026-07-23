#!/usr/bin/env python3
"""Sync the launcher's bundled RE4R assets from the ArchipelagoRE4R mod repo.

The launcher ships TWO derived copies of the mod's generated data, and both drift
silently whenever the mod regenerates (``data_parser.py`` / a maps rebuild):

  1. ``assets/Data/RE4R.apworld``          -- the AP generation world (it bundles the
                                              location/stage maps + the world .py files)
  2. ``assets/Lua/data/ArchipelagoRE4R/``  -- the in-game runtime data the mod reads

Unlike the ``.lua`` byte-mirror -- which agents edit by hand and therefore notice --
these are build artifacts nobody opens, so drift is invisible until a seed is
generated (or a game patched) on stale data. Run this after ANY mod-side data or
apworld change; it is the guard that keeps the two mirrors honest.

Modes:
  (default)   refresh both from the mod repo, then verify.
  --check     verify only; exit 1 if either is out of sync (for CI / pre-commit).

Mod repo location: ``$RE4R_MOD_REPO`` if set, else the sibling ``../ArchipelagoRE4R``.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

LAUNCHER_ROOT = Path(__file__).resolve().parent.parent
BUNDLED_APWORLD = LAUNCHER_ROOT / "assets" / "Data" / "RE4R.apworld"
LUA_DATA_MIRROR = LAUNCHER_ROOT / "assets" / "Lua" / "data" / "ArchipelagoRE4R"
MOD_DATA_SUBPATH = Path("reframework") / "data" / "ArchipelagoRE4R"


def find_mod_repo() -> Path:
    env = os.environ.get("RE4R_MOD_REPO")
    candidate = Path(env) if env else LAUNCHER_ROOT.parent / "ArchipelagoRE4R"
    candidate = candidate.resolve()
    if not (candidate / "build_apworld.py").is_file():
        sys.exit(f"error: mod repo not found at {candidate} (set $RE4R_MOD_REPO)")
    return candidate


def _zip_member_hashes(path: Path) -> dict[str, str]:
    with zipfile.ZipFile(path) as archive:
        return {
            name: hashlib.sha256(archive.read(name)).hexdigest()
            for name in archive.namelist()
            if not name.endswith("/")
        }


def _build_apworld(mod: Path, output: Path) -> None:
    # build_apworld.py names the internal folder from the output filename STEM, so the
    # shippable file MUST be built as "RE4R.apworld" (-> internal "RE4R/" that AP loads).
    assert output.stem == "RE4R", f"apworld output stem must be 'RE4R', got {output.stem!r}"
    subprocess.run(
        [sys.executable, str(mod / "build_apworld.py"), "--output", str(output)],
        cwd=mod,
        check=True,
        stdout=subprocess.DEVNULL,
    )


def _apworld_status(mod: Path) -> tuple[bool, str]:
    with tempfile.TemporaryDirectory() as tmp:
        fresh = Path(tmp) / "RE4R.apworld"
        _build_apworld(mod, fresh)
        if not BUNDLED_APWORLD.is_file():
            return False, "bundled apworld is MISSING"
        fresh_h, bundled_h = _zip_member_hashes(fresh), _zip_member_hashes(BUNDLED_APWORLD)
        if fresh_h == bundled_h:
            return True, "apworld: in sync"
        changed = sorted(set(fresh_h) ^ set(bundled_h)) + sorted(
            n for n in (fresh_h.keys() & bundled_h.keys()) if fresh_h[n] != bundled_h[n]
        )
        return False, "apworld: STALE (" + ", ".join(changed[:8]) + ")"


def _mirror_diffs(mod: Path) -> list[str]:
    src = mod / MOD_DATA_SUBPATH
    if not src.is_dir():
        return [f"mod data dir missing: {src}"]
    src_files = {p.relative_to(src) for p in src.rglob("*") if p.is_file()}
    dst_files = (
        {p.relative_to(LUA_DATA_MIRROR) for p in LUA_DATA_MIRROR.rglob("*") if p.is_file()}
        if LUA_DATA_MIRROR.exists()
        else set()
    )
    diffs = []
    for rel in sorted(src_files - dst_files):
        diffs.append(f"missing in launcher: {rel.as_posix()}")
    for rel in sorted(dst_files - src_files):
        diffs.append(f"extra in launcher: {rel.as_posix()}")
    for rel in sorted(src_files & dst_files):
        if (src / rel).read_bytes() != (LUA_DATA_MIRROR / rel).read_bytes():
            diffs.append(f"differs: {rel.as_posix()}")
    return diffs


def _refresh(mod: Path) -> None:
    _build_apworld(mod, BUNDLED_APWORLD)
    print(f"refreshed apworld     -> {BUNDLED_APWORLD.relative_to(LAUNCHER_ROOT).as_posix()}")
    src = mod / MOD_DATA_SUBPATH
    # copytree overwrite (no rmtree): refreshes content in place; a file removed
    # mod-side is left for _mirror_diffs to flag as "extra" rather than silently nuking.
    shutil.copytree(src, LUA_DATA_MIRROR, dirs_exist_ok=True)
    print(f"refreshed data mirror -> {LUA_DATA_MIRROR.relative_to(LAUNCHER_ROOT).as_posix()}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="verify only; exit 1 on drift")
    args = parser.parse_args()

    mod = find_mod_repo()
    print(f"mod repo: {mod}")
    if not args.check:
        _refresh(mod)

    apworld_ok, apworld_msg = _apworld_status(mod)
    mirror = _mirror_diffs(mod)
    print(apworld_msg)
    print("data mirror: " + ("in sync" if not mirror else "OUT OF SYNC"))
    for entry in mirror:
        print("  - " + entry)

    drifted = (not apworld_ok) or bool(mirror)
    if drifted:
        if args.check:
            print("\nDRIFT DETECTED -- run without --check to refresh", file=sys.stderr)
        else:
            print("\nERROR: still out of sync after refresh (investigate)", file=sys.stderr)
        return 1
    print("\nOK: launcher assets in sync with the mod repo")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
