"""Build the Lua-only update artifacts for a GitHub release.

Produces two files in dist/release:

  re4r-ap-payload-<MOD_VERSION>.zip   PAYLOAD_STAMP.json at the zip root plus
                                      the whole assets/Lua tree under Lua/ -
                                      exactly the shape PayloadStore installs.
  update-manifest.json                What the launcher's update check reads:
                                      the payload's version, world data,
                                      sha256 and download URL.

Both belong on the SAME release as assets. The launcher finds the manifest on
the newest non-draft release (prerelease included - GitHub's "latest" alias
skips prereleases, so nothing here relies on it), verifies the zip against
the manifest hash, and refuses payloads whose world_version does not match
what it bundles.

Usage, after stage_payload.py has refreshed assets and the stamp:

  python tools/build_update_assets.py --release-tag v0.5.1-alpha
      [--notes "One line for the banner."]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ASSETS = REPO_ROOT / "assets"
STAMP_PATH = ASSETS / "PAYLOAD_STAMP.json"
LUA_ROOT = ASSETS / "Lua"
OUTPUT_DIR = REPO_ROOT / "dist" / "release"
DOWNLOAD_URL_BASE = "https://github.com/LiterallyMetaphorical/RE4R-AP-Wizard/releases/download"


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the payload zip + update manifest for a release.")
    parser.add_argument("--release-tag", required=True, help="Git tag of the release these assets attach to, e.g. v0.5.1-alpha.")
    parser.add_argument("--notes", default="", help="One banner-sized line describing the payload update.")
    args = parser.parse_args()

    if not STAMP_PATH.is_file():
        print(f"missing {STAMP_PATH} - run tools/stage_payload.py first", file=sys.stderr)
        return 1
    if not LUA_ROOT.is_dir():
        print(f"missing {LUA_ROOT} - run tools/stage_payload.py first", file=sys.stderr)
        return 1

    stamp = json.loads(STAMP_PATH.read_text(encoding="utf-8"))
    mod_version = stamp["payload"]["mod_version"]
    world_version = stamp["payload"]["world_version"]

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    # The name is a sign, because this file sits in the release's download
    # list looking like something to click and there is nothing a person can
    # do with it: the wizard fetches it on its own, from the URL in the
    # manifest, and never by name. Only [A-Za-z0-9._-] here, since GitHub
    # rewrites spaces and other punctuation in an asset's filename.
    # update-manifest.json CANNOT be renamed the same way: UpdateCheckService
    # looks for that exact name on the release.
    zip_name = f"DO-NOT-DOWNLOAD-wizard-auto-update-{mod_version}.zip"
    zip_path = OUTPUT_DIR / zip_name

    lua_files = sorted(path for path in LUA_ROOT.rglob("*") if path.is_file())
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.write(STAMP_PATH, "PAYLOAD_STAMP.json")
        for path in lua_files:
            archive.write(path, (Path("Lua") / path.relative_to(LUA_ROOT)).as_posix())

    zip_hash = sha256_of(zip_path)
    manifest = {
        "schema_version": 1,
        "payload": {
            "mod_version": mod_version,
            "world_version": world_version,
            "sha256": zip_hash,
            "url": f"{DOWNLOAD_URL_BASE}/{args.release_tag}/{zip_name}",
            "notes": args.notes,
        },
    }
    manifest_path = OUTPUT_DIR / "update-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(f"payload zip:  {zip_path} ({zip_path.stat().st_size:,} bytes, {len(lua_files)} Lua files)")
    print(f"sha256:       {zip_hash}")
    print(f"manifest:     {manifest_path}")
    print(f"mod_version:  {mod_version}  world_version: {world_version}")
    print("attach BOTH files to the release; the manifest must be on the newest release to be found.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
