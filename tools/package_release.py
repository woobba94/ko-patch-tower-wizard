"""Package a verified local PCK delta and generate the standalone CMD."""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
RELEASE_HOST = "https://github.com/woobba94/ko-patch-tower-wizard/releases/download"
NAME = "ko-patch-tower-wizard.cmd"
MARKER = "#===TWKO-POWERSHELL==="

BOOTSTRAP = r"""@echo off
setlocal DisableDelayedExpansion
set "TWKO_CMD_PATH=%~f0"
set "TWKO_EXPLICIT_GAME=%~1"
chcp 65001 >nul
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -Command "$s=[IO.File]::ReadAllText($env:TWKO_CMD_PATH,[Text.Encoding]::UTF8); $m=[regex]::Match($s,'(?ms)^#===TWKO-POWERSHELL===\r?\n(.*)\z'); if(!$m.Success){exit 2}; & ([scriptblock]::Create($m.Groups[1].Value))"
exit /b %errorlevel%
"""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(data):
    return (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def write_bundle(output, patch, game_version, steam_build, legacy_hashes):
    manifest = json.loads((patch / "manifest.json").read_text(encoding="utf-8"))
    expected = manifest["localized_resources"]
    if not all("res://_tower_wizard_ko/" + name + ".res" in expected for name in ("Galmuri9", "Galmuri11")):
        raise ValueError("Build the local PCK delta with Galmuri font resources first")
    header = (patch / "header.bin").read_bytes()
    literal = (patch / "literal.bin").read_bytes()
    ops = json.loads((patch / "operations.json").read_text(encoding="utf-8"))
    if digest(header) != manifest["header_sha256"]:
        raise ValueError("Local patch header failed SHA-256 verification")
    if any(re.fullmatch(r"[0-9a-f]{64}", value) is None for value in legacy_hashes):
        raise ValueError("Legacy hashes must be lowercase SHA-256 values")
    parameters = {
        "schema": 2,
        "game_version": game_version,
        "steam_build": steam_build,
        "base_sha256": manifest["base_sha256"],
        "patched_sha256": manifest["patched_sha256"],
        "base_length": manifest["base_length"],
        "stock_tail_offset": manifest["copy_from"],
        "header_sha256": digest(header),
        "literal_sha256": digest(literal),
        "operations": ops,
    }
    archive = output / f"tower-wizard-ko-steam-{steam_build}.zip"
    content = {
        "manifest.json": json_bytes(parameters),
        "header.bin": header,
        "literal.bin": literal,
        "Galmuri-OFL-1.1.txt": (ROOT / "licenses/Galmuri-OFL-1.1.txt").read_bytes(),
    }
    with ZipFile(archive, "w", ZIP_DEFLATED, compresslevel=9) as package:
        for name, data in content.items():
            member = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            package.writestr(member, data, compress_type=ZIP_DEFLATED, compresslevel=9)
    return {
        "game_version": game_version,
        "steam_build": steam_build,
        "base_sha256": manifest["base_sha256"],
        "patched_sha256": manifest["patched_sha256"],
        "legacy_sha256": legacy_hashes,
        "archive": archive.name,
        "archive_sha256": digest(archive.read_bytes()),
    }


def generate_cmd(catalog, output):
    source = (ROOT / "src/launcher.ps1").read_text(encoding="utf-8-sig")
    data = json_bytes(catalog).decode("utf-8").rstrip("\n")
    embedded = "$script:Catalog = @'\n" + data + "\n'@ | ConvertFrom-Json\n\n"
    cmd = BOOTSTRAP + MARKER + "\n" + embedded + source.rstrip("\n") + "\n"
    output.write_bytes(cmd.replace("\n", "\r\n").encode("utf-8"))


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--patch-dir", type=Path, required=True)
    cli.add_argument("--steam-build", required=True, type=int)
    cli.add_argument("--game-version", required=True)
    cli.add_argument("--tag", required=True)
    cli.add_argument("--legacy-sha256", action="append", default=[])
    cli.add_argument("--output", type=Path)
    args = cli.parse_args()
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag) is None:
        raise ValueError("Use a stable release tag such as v1.0.0")
    out = args.output or ROOT / "dist" / args.tag
    out.mkdir(parents=True, exist_ok=True)
    build = write_bundle(out, args.patch_dir, args.game_version, args.steam_build, args.legacy_sha256)
    catalog = {"tag": args.tag, "release_base": f"{RELEASE_HOST}/{args.tag}/", "builds": [build]}
    (ROOT / "src/builds.json").write_bytes(json_bytes(catalog))
    generate_cmd(catalog, ROOT / NAME)
    shutil.copyfile(ROOT / NAME, out / NAME)
    for name in (NAME, build["archive"]):
        print(f"{digest((out / name).read_bytes())}  {name}")


if __name__ == "__main__":
    main()
