"""Package a published Linux launcher as a .tar.gz that actually runs.

Why a tarball and not a zip: the Windows zip tooling cannot store a Unix
executable bit, so a zipped Linux build arrives with `re4r-ap-launcher`
non-executable and the tester has to know to chmod it. tar preserves mode, so
this sets 0755 on the launcher and the two Avalonia .so files and 0644 on
everything else.

Usage (from the repo root, after publishing):

  dotnet publish src/RE4R.AP.Launcher.Linux/RE4R.AP.Launcher.Linux.csproj ^
    -c Release -r linux-x64 --self-contained true -p:PublishSingleFile=true ^
    -o publish/<name>-linux
  python tools/package_linux_release.py publish/<name>-linux publish/<name>-linux.tar.gz
"""
from __future__ import annotations

import sys
import tarfile
from pathlib import Path

EXECUTABLE_NAMES = {"re4r-ap-launcher"}
EXECUTABLE_SUFFIXES = {".so"}
# Build artifacts that must never reach a player.
EXCLUDED_SUFFIXES = {".pdb"}


def is_executable(path: Path) -> bool:
    return path.name in EXECUTABLE_NAMES or path.suffix in EXECUTABLE_SUFFIXES


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2

    source = Path(sys.argv[1]).resolve()
    target = Path(sys.argv[2]).resolve()

    if not source.is_dir():
        print(f"error: {source} is not a directory")
        return 1

    launcher = source / "re4r-ap-launcher"
    if not launcher.is_file():
        print(f"error: {launcher} not found - publish the Linux project first")
        return 1

    payload = source / "assets" / "BioRand" / "biorand-re4r.exe"
    if not payload.is_file():
        print("error: assets/BioRand/biorand-re4r.exe missing from the publish output.")
        print("The Windows payload ships with the Linux build too - it runs under Proton.")
        return 1

    root = target.name
    for suffix in (".tar.gz", ".tgz"):
        if root.endswith(suffix):
            root = root[: -len(suffix)]
            break

    files = sorted(p for p in source.rglob("*") if p.is_file())
    kept = [p for p in files if p.suffix not in EXCLUDED_SUFFIXES]
    skipped = len(files) - len(kept)

    target.parent.mkdir(parents=True, exist_ok=True)
    executables = 0
    with tarfile.open(target, "w:gz") as archive:
        for path in kept:
            relative = path.relative_to(source).as_posix()
            info = archive.gettarinfo(str(path), arcname=f"{root}/{relative}")
            # Normalise ownership so the archive does not carry a Windows SID.
            info.uid, info.gid = 0, 0
            info.uname, info.gname = "root", "root"
            if is_executable(path):
                info.mode = 0o755
                executables += 1
            else:
                info.mode = 0o644
            with open(path, "rb") as handle:
                archive.addfile(info, handle)

    size_mb = target.stat().st_size / (1024 * 1024)
    print(f"wrote {target} ({size_mb:.1f} MB)")
    print(f"  {len(kept)} files, {executables} marked executable, {skipped} build artifact(s) skipped")
    print(f"  top-level folder: {root}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
