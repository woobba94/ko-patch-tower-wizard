"""Build the reusable Windows installer from the local Korean patch workspace."""
import argparse
import difflib
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile, ZipInfo

ROOT = Path(__file__).resolve().parents[1]
RELEASE_HOST = "https://github.com/woobba94/ko-patch-tower-wizard/releases/download"
NAME = "ko-patch-tower-wizard.cmd"
MARKER = "#===TWKO-POWERSHELL==="
PREFIX = "res://_tower_wizard_ko/"
KEYDOT_SHA256 = "048cd2db98af3d09612284bdebd7b4f899dfef085edce9f24d3d2b921248f326"

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


def json_bytes(data, indent=2):
    return (json.dumps(data, ensure_ascii=False, indent=indent) + "\n").encode("utf-8")


def script_recipe(path, stock, translated):
    def lines(content):
        return re.findall(r"[^\n]*\n|[^\n]+$", content.decode("utf-8-sig").replace("\r\n", "\n"))

    original, updated = lines(stock), lines(translated)
    chunks = difflib.SequenceMatcher(a=original, b=updated, autojunk=False).get_grouped_opcodes(n=3)
    edits = []
    for chunk in chunks:
        start, stop = chunk[0][1], chunk[-1][2]
        stencil = original[start:stop]
        hits = sum(original[i:i + len(stencil)] == stencil for i in range(len(original) - len(stencil) + 1))
        if not stencil or hits != 1:
            raise ValueError(f"Cannot uniquely identify script edit near line {start + 1} of {path}")
        edits.append({
            "line_count": len(stencil),
            "original_sha256": digest("".join(stencil).encode("utf-8")),
            "replacement": "".join(updated[chunk[0][3]:chunk[-1][4]]),
        })
    return {"path": path, "edits": edits}


def translation_recipe(name, native, rows, hash_key):
    hashes, buckets = native["hash"], native["bucket"]
    blob = bytes.fromhex(native["strings"])
    rows = {row["slot"]: row for row in rows}
    messages = []
    for index, start in enumerate(hashes):
        if start < 0:
            continue
        seed = buckets[start + 1]
        for slot in range(start + 2, start + 2 + buckets[start] * 4, 4):
            key_hash, offset, size, original_size = buckets[slot:slot + 4]
            row = rows.pop(slot)
            key = row["key"]
            if (key_hash != row["hash"] or (key and (hash_key(key) % len(hashes) != index or
                    hash_key(key, seed) != key_hash & 0xFFFFFFFF))):
                raise ValueError(f"Catalog key/slot mismatch in {name}: {slot}")
            messages.append({
                "key": key, "bucket": index, "seed": seed, "hash": key_hash, "raw_size": original_size,
                "source_sha256": digest(blob[offset:offset + size]), "korean": row["ko"],
            })
    if rows:
        raise ValueError(f"Unmatched messages in {name}: {list(rows)}")
    return {"path": "res://" + name + ".en.translation", "hash_count": len(hashes), "messages": messages}


def write_bundle(output, workspace, game, patch, previous):
    sys.path.insert(0, str(workspace / "scripts"))
    from build_patch import load_catalog, local_key
    from pck import Pack
    from prepare_catalog import hash_key

    manifest = json.loads((patch / "manifest.json").read_text(encoding="utf-8"))
    stock = (workspace / "work/backup/Tower Wizard.pck").read_bytes()
    header = (patch / "header.bin").read_bytes()
    extra = (patch / "append.bin").read_bytes()
    target = header + stock[manifest["copy_from"]:] + extra
    if digest(stock) != previous["base_sha256"] or digest(target) != manifest["patched_sha256"]:
        raise ValueError("The local original or translated PCK failed SHA-256 verification")
    keydot = workspace / "work/tools/keydot.exe"
    if digest(keydot.read_bytes()) != KEYDOT_SHA256:
        raise ValueError("KeyDot does not match the upstream v1.0.3 release")
    key = local_key(keydot, game)
    original = Pack(stock, key)
    localized = Pack(target, key)
    native = json.loads((workspace / "work/translation-tables.json").read_text(encoding="utf-8"))
    catalog = load_catalog(workspace / "data/korean.csv")
    recipe = {
        "schema": 3,
        "scripts": [script_recipe(path, original.read(path), localized.read(path))
                    for path in manifest["localized_resources"] if path.endswith(".gd")],
        "translations": [translation_recipe(name, native[name], catalog[name], hash_key)
                         for name in ("translation", "remap_keys")],
    }
    archive = output / "tower-wizard-ko-data.zip"
    content = {
        "recipe.json": json_bytes(recipe, indent=None),
        "keydot.exe": keydot.read_bytes(),
        "KeyDot-MIT.txt": (ROOT / "licenses/KeyDot-MIT.txt").read_bytes(),
        "Galmuri-OFL-1.1.txt": (ROOT / "licenses/Galmuri-OFL-1.1.txt").read_bytes(),
        **{name: localized.read(PREFIX + name) for name in ("Galmuri9.res", "Galmuri11.res", "extra.ko.translation")},
    }
    with ZipFile(archive, "w", ZIP_DEFLATED, compresslevel=9) as bundle:
        for name, data in content.items():
            member = ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            bundle.writestr(member, data, compress_type=ZIP_DEFLATED, compresslevel=9)
    return {"archive": archive.name, "archive_sha256": digest(archive.read_bytes())}


def generate_cmd(catalog, output):
    source = (ROOT / "src/launcher.ps1").read_text(encoding="utf-8-sig")
    declarations = set()
    bodies = []
    for path in sorted((ROOT / "src").glob("*.cs")):
        imports, body = path.read_text(encoding="utf-8").split("\nnamespace ", 1)
        declarations.update(line for line in imports.splitlines() if line.startswith("using "))
        bodies.append("namespace " + body.strip())
    csharp = "\n".join(sorted(declarations)) + "\n\n" + "\n\n".join(bodies)
    data = json_bytes(catalog).decode("utf-8").rstrip("\n")
    embedded = "$script:Catalog = @'\n" + data + "\n'@ | ConvertFrom-Json\n\n"
    embedded += "$script:InstallerSource = @'\n" + csharp + "\n'@\n\n"
    cmd = BOOTSTRAP + MARKER + "\n" + embedded + source.rstrip("\n") + "\n"
    output.write_bytes(cmd.replace("\n", "\r\n").encode("utf-8"))


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--workspace", type=Path, required=True)
    cli.add_argument("--game-dir", type=Path, required=True)
    cli.add_argument("--patch-dir", type=Path, required=True, help="Generated, verified local Galmuri patch")
    cli.add_argument("--tag", required=True)
    cli.add_argument("--output", type=Path)
    args = cli.parse_args()
    if re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", args.tag) is None:
        raise ValueError("Use a stable release tag such as v1.1.0")
    out = args.output or ROOT / "dist" / args.tag
    out.mkdir(parents=True, exist_ok=True)
    previous = json.loads((ROOT / "src/legacy.json").read_text(encoding="utf-8"))
    package = write_bundle(out, args.workspace.resolve(), args.game_dir.resolve(), args.patch_dir, previous)
    catalog = {
        "tag": args.tag, "release_base": f"{RELEASE_HOST}/{args.tag}/", "package": package,
        "legacy": {
            "steam_build": previous["steam_build"], "base_sha256": previous["base_sha256"],
            "patched_sha256": [previous["patched_sha256"], *previous["legacy_sha256"]],
        },
    }
    (ROOT / "src/builds.json").write_bytes(json_bytes(catalog))
    generate_cmd(catalog, ROOT / NAME)
    shutil.copyfile(ROOT / NAME, out / NAME)
    for name in (NAME, package["archive"]):
        print(f"{digest((out / name).read_bytes())}  {name}")


if __name__ == "__main__":
    main()
