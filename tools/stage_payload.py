"""Assemble assets/ from the source repos.

The payload is git-ignored, so nothing in `git status` ever says it is stale.
It drifted a week behind once because staging was a set of remembered manual
copies. This is that set of copies, written down and checked.

    python tools/stage_payload.py            # build everything and stage it
    python tools/stage_payload.py --verify   # check the staged payload only
    python tools/stage_payload.py --skip-exe # stage without the 2 min exe build

Writes assets/PAYLOAD_STAMP.json: the source commit of every part, plus hashes.
That file is the anti-drift mechanism. The long-form provenance .txt files stay
human narrative, and the lines to add to them are printed at the end.
"""
from __future__ import annotations

import argparse
import filecmp
import hashlib
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

LAUNCHER = Path(__file__).resolve().parent.parent
ASSETS = LAUNCHER / "assets"
APWORLD_REPO = LAUNCHER.parent / "ArchipelagoRE4R"
FORK_REPO = LAUNCHER.parent / "biorand-re4r-ap"
DOTNET = r"C:\Program Files\dotnet\dotnet.exe"

# (source, staged) relative to their repos. autorun/ is flattened into Lua/.
LUA_PAIRS = [
    (APWORLD_REPO / "reframework" / "autorun", ASSETS / "Lua"),
    (APWORLD_REPO / "reframework" / "data", ASSETS / "Lua" / "data"),
]

problems: list[str] = []


def fail(msg: str) -> None:
    problems.append(msg)
    print(f"  FAIL  {msg}")


def ok(msg: str) -> None:
    print(f"  ok    {msg}")


def run(cmd: list[str], cwd: Path) -> str:
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8")
    if r.returncode != 0:
        raise SystemExit(f"command failed in {cwd}:\n  {' '.join(cmd)}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def git(repo: Path, *args: str) -> str:
    return run(["git", *args], repo).strip()


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def preflight() -> dict:
    print("preflight")
    info = {}
    for name, repo, branch in (
        ("apworld", APWORLD_REPO, "fix/playtest-round-2"),
        ("fork", FORK_REPO, "ap-manifest-input"),
    ):
        if not repo.exists():
            raise SystemExit(f"{name} repo not found at {repo}")
        actual = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
        dirty = [l for l in git(repo, "status", "--porcelain").splitlines()
                 if l and not l.startswith("??")]
        info[name] = {
            "repo": repo.name,
            "branch": actual,
            "commit": git(repo, "rev-parse", "HEAD"),
            "short": git(repo, "rev-parse", "--short", "HEAD"),
        }
        if actual != branch:
            fail(f"{name} is on {actual}, expected {branch}")
        else:
            ok(f"{name} on {actual} at {info[name]['short']}")
        if dirty:
            # Tracked edits would be baked into the payload without being in any
            # commit, which is exactly the state nobody can reconstruct later.
            fail(f"{name} has {len(dirty)} uncommitted tracked change(s); commit or stash first")
    return info


def build_exe() -> None:
    print("building the BioRand fork exe (this takes a couple of minutes)")
    out = FORK_REPO / "src" / "biorand-re4r" / "bin" / "stage-publish"
    if out.exists():
        shutil.rmtree(out)
    run([DOTNET, "publish", "src/biorand-re4r/biorand-re4r.csproj",
         "-c", "Release", "-r", "win-x64", "--self-contained", "true",
         "-o", str(out)], FORK_REPO)
    dest = ASSETS / "BioRand"
    dest.mkdir(parents=True, exist_ok=True)
    staged = 0
    for src in sorted(out.iterdir()):
        if src.is_file():
            shutil.copy2(src, dest / src.name)
            staged += 1
    ok(f"staged {staged} file(s) into assets/BioRand")


def build_apworld() -> None:
    print("building the apworld")
    run([sys.executable, "build_apworld.py"], APWORLD_REPO)
    shutil.copy2(APWORLD_REPO / "RE4R.apworld", ASSETS / "Data" / "RE4R.apworld")
    shutil.copy2(APWORLD_REPO / "data" / "re4r_ap_static.json",
                 ASSETS / "Data" / "re4r_ap_static.json")
    ok("staged RE4R.apworld and re4r_ap_static.json")


def stage_lua() -> None:
    print("staging the Lua mod")
    copied = 0
    for source_root, dest_root in LUA_PAIRS:
        for src in sorted(source_root.rglob("*")):
            if not src.is_file():
                continue
            dest = dest_root / src.relative_to(source_root)
            dest.parent.mkdir(parents=True, exist_ok=True)
            # Binary copy: config.lua carries UTF-8 glyph constants that any
            # re-encoding step mangles.
            shutil.copy2(src, dest)
            copied += 1
    ok(f"copied {copied} Lua/data file(s)")


def verify(info: dict | None) -> dict:
    print("verifying the staged payload")
    results = {}

    # Every source file present and byte-identical, and nothing stale left over.
    for source_root, dest_root in LUA_PAIRS:
        sources = {p.relative_to(source_root) for p in source_root.rglob("*") if p.is_file()}
        staged = {p.relative_to(dest_root) for p in dest_root.rglob("*") if p.is_file()}
        if dest_root.name == "Lua":
            staged = {p for p in staged if p.parts[0] != "data"}
        missing = sources - staged
        extra = staged - sources
        differing = [p for p in sorted(sources & staged)
                     if not filecmp.cmp(source_root / p, dest_root / p, shallow=False)]
        label = dest_root.relative_to(ASSETS)
        if missing:
            fail(f"{label}: {len(missing)} source file(s) not staged: {sorted(str(m) for m in missing)[:4]}")
        if extra:
            fail(f"{label}: {len(extra)} stale file(s) staged: {sorted(str(e) for e in extra)[:4]}")
        if differing:
            fail(f"{label}: {len(differing)} file(s) differ from source: {[str(d) for d in differing[:4]]}")
        if not (missing or extra or differing):
            ok(f"{label}: {len(sources)} file(s) match source exactly")

    exe = ASSETS / "BioRand" / "biorand-re4r.exe"
    if not exe.exists():
        fail("assets/BioRand/biorand-re4r.exe is missing")
    else:
        results["exe_sha256"] = sha256(exe)
        results["exe_bytes"] = exe.stat().st_size
        ok(f"biorand-re4r.exe {exe.stat().st_size / 1_048_576:.0f} MB, sha256 {results['exe_sha256'][:16]}...")

    apworld = ASSETS / "Data" / "RE4R.apworld"
    if not apworld.exists():
        fail("assets/Data/RE4R.apworld is missing")
    else:
        results["apworld_sha256"] = sha256(apworld)
        src_apworld = APWORLD_REPO / "RE4R.apworld"
        if src_apworld.exists() and sha256(src_apworld) != results["apworld_sha256"]:
            fail("staged RE4R.apworld differs from the one in the apworld repo")
        else:
            ok("RE4R.apworld matches the source build")

    static = ASSETS / "Data" / "re4r_ap_static.json"
    if static.exists():
        payload = json.loads(static.read_text(encoding="utf-8"))
        results["world_version"] = payload.get("world_version", "?")
        results["locations"] = payload.get("counts", {}).get("locations_total")
        ok(f"world_version {results['world_version']}, {results['locations']} locations")
        if not payload.get("item_groups"):
            fail("re4r_ap_static.json carries no item_groups; the YAML picker will be empty")

    config = ASSETS / "Lua" / "ArchipelagoRE4R" / "config.lua"
    if config.exists():
        for line in config.read_text(encoding="utf-8").splitlines():
            if "MOD_VERSION" in line and "=" in line:
                results["mod_version"] = line.split('"')[1] if '"' in line else "?"
                ok(f"MOD_VERSION {results['mod_version']}")
                break
    return results


def write_stamp(info: dict, results: dict) -> None:
    stamp = {
        "staged_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "sources": info,
        "payload": results,
    }
    path = ASSETS / "PAYLOAD_STAMP.json"
    path.write_text(json.dumps(stamp, indent=2) + "\n", encoding="utf-8")
    print(f"\nwrote {path.relative_to(LAUNCHER)}")
    print("\nlines for the provenance .txt files:")
    print(f"  BioRand fork:  {info['fork']['repo']} {info['fork']['branch']} @ {info['fork']['short']}")
    print(f"  exe SHA-256:   {results.get('exe_sha256', '?')}")
    print(f"  apworld:       {info['apworld']['repo']} {info['apworld']['branch']} @ {info['apworld']['short']}")
    print(f"  world_version: {results.get('world_version', '?')}, MOD_VERSION {results.get('mod_version', '?')}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify", action="store_true", help="check the staged payload, build nothing")
    parser.add_argument("--skip-exe", action="store_true", help="stage without rebuilding the exe")
    args = parser.parse_args()

    info = preflight()
    if problems:
        print("\npreflight failed; nothing was staged.")
        return 1

    if not args.verify:
        if not args.skip_exe:
            build_exe()
        else:
            print("skipping the exe build (--skip-exe)")
        build_apworld()
        stage_lua()

    results = verify(info)
    write_stamp(info, results)

    print()
    if problems:
        print(f"{len(problems)} problem(s). The payload is NOT good to ship.")
        return 1
    print("payload staged and verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
