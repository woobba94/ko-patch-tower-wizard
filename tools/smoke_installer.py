"""Verify the packaged CMD on original, legacy, updated, and incompatible PCKs."""
import argparse
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from zipfile import ZipFile

from package_release import NAME, ROOT


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def invoke(script, actions, game=None, env=None, expected=0):
    argv = ["cmd.exe", "/d", "/c", script.name]
    if game is not None:
        argv.append(str(game))
    result = subprocess.run(
        argv, cwd=script.parent, input=("\r\n".join(actions) + "\r\n").encode("ascii"),
        capture_output=True, timeout=60, env=env,
    )
    output = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    assert result.returncode == expected, output
    return output


def cached_launcher(script, catalog, asset, work):
    test = work / NAME
    test.write_bytes(script.read_bytes().replace(
        b"[Environment]::GetFolderPath('LocalApplicationData')", b"$env:TWKO_VERIFY_CACHE"))
    cache = work / "cache/ko-patch-tower-wizard/cache"
    cache.mkdir(parents=True)
    shutil.copyfile(asset, cache / (catalog["package"]["archive_sha256"] + ".zip"))
    return test, dict(os.environ, TWKO_VERIFY_CACHE=str(work / "cache"))


def exercise_download(script, catalog, asset, stock, game, work):
    calls = []
    served = {"name": "/wrong.zip"}
    available = work / "http"
    available.mkdir()
    shutil.copyfile(asset, available / "right.zip")
    (available / "wrong.zip").write_bytes(b"corrupt test payload")

    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self):
            calls.append(self.path)
            if self.path == "/" + asset.name:
                self.send_response(302)
                self.send_header("Location", "/payload")
                self.send_header("Content-Length", "0")
                self.end_headers()
            elif self.path == "/payload":
                self.path = served["name"]
                super().do_GET()
            else:
                self.send_error(404)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(available)))
    worker = Thread(target=server.serve_forever, daemon=True)
    worker.start()
    network = work / "network"
    network.mkdir()
    cmd = network / NAME
    cmd.write_bytes(script.read_bytes()
        .replace(catalog["release_base"].encode(), f"http://127.0.0.1:{server.server_port}/".encode())
        .replace(b"[Environment]::GetFolderPath('LocalApplicationData')", b"$env:TWKO_VERIFY_CACHE"))
    env = dict(os.environ, TWKO_VERIFY_CACHE=str(network / "cache"))
    pck = game / "Tower Wizard.pck"
    shutil.copyfile(stock, pck)
    try:
        output = invoke(cmd, ["1", "0"], game, env, expected=1)
        assert "SHA-256이 다릅니다" in output and sha(pck) == sha(stock), output
        assert len(calls) == 2
        served["name"] = "/right.zip"
        output = invoke(cmd, ["1", "0"], game, env)
        assert "GitHub 릴리스에서" in output and "한국어 패치를 적용했습니다" in output and len(calls) == 4, output
        invoke(cmd, ["2", "0"], game, env)
        assert sha(pck) == sha(stock) and len(calls) == 4
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


def updated_translation(resource, native, lookup, hash_key):
    """Make one changed message and one new key with the same Godot resource format."""
    hashes, buckets = native["hash"][:], native["bucket"][:]
    strings = bytearray.fromhex(native["strings"])
    header = struct.pack("<iii", 4, 32, len(hashes))
    position = resource.index(header)
    old_body_end = position + 36 + len(hashes) * 4 + len(buckets) * 4 + len(strings) + (-len(strings)) % 4
    assert resource[old_body_end:] == b"\x07\0\0\0\x01\0\0\0RSRC"

    changed = lookup(native, "label.wall_explanation")
    assert changed is not None
    modified = b"Updated wall instructions.\0"
    buckets[changed + 1:changed + 4] = [len(strings), len(modified), len(modified)]
    strings.extend(modified)
    key = next(key for i in range(len(hashes)) if hashes[hash_key(key := f"label.fixture_added_{i}") % len(hashes)] == -1)
    added = b"New message in this build.\0"
    hashes[hash_key(key) % len(hashes)] = len(buckets)
    signed_hash = (hash_key(key, 1) + 2**31) % 2**32 - 2**31
    buckets.extend((1, 1, signed_hash, len(strings), len(added), len(added)))
    strings.extend(added)
    new_body = header + struct.pack(f"<{len(hashes)}i", *hashes)
    new_body += struct.pack(f"<iii{len(buckets)}i", 5, 32, len(buckets), *buckets)
    new_body += struct.pack("<iii", 6, 31, len(strings)) + strings + bytes((-len(strings)) % 4)
    return resource[:position] + new_body + resource[old_body_end:], key


def reproduce_unknown(work, workspace, game, stock):
    sys.path.insert(0, str(workspace / "scripts"))
    from build_patch import local_key
    from pck import Pack
    from prepare_catalog import hash_key, lookup
    from project_settings import project_string, read_settings, write_settings

    key = local_key(workspace / "work/tools/keydot.exe", game)
    original = Pack(stock.read_bytes(), key)
    native = json.loads((workspace / "work/translation-tables.json").read_text(encoding="utf-8"))
    config = read_settings(original.read("res://project.binary"))
    original_config = dict(config)
    config["application/config/version"] = project_string("1.0.5-fixture")
    new_table, new_key = updated_translation(original.read("res://translation.en.translation"),
        native["translation"], lookup, hash_key)
    changes = {
        "res://translation.en.translation": new_table,
        "res://project.binary": write_settings(config),
        "res://compatibility-fixture.txt": b"unrelated new Steam game resource\n",
        "res://Options.gd": original.read("res://Options.gd") + b"\n# unrelated Steam update comment\n",
    }
    def with_changes(resources):
        header, extra = original.patch(resources)
        return header + original.data[original.base:] + extra

    updated = work / "mock-update.pck"
    updated.write_bytes(with_changes(changes))
    incompatible = work / "mock-incompatible.pck"
    incompatible.write_bytes(with_changes({"res://Options.gd": original.read("res://Options.gd").replace(
        b'var saved_locale: String = ""', b"var saved_locale: String = String()")}))
    return Pack, key, updated, incompatible, changes, config, original_config, new_key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--game-dir", type=Path, required=True)
    args = parser.parse_args()
    workspace, real = args.workspace.resolve(), args.game_dir.resolve()
    catalog = json.loads((ROOT / "src/builds.json").read_text(encoding="utf-8"))
    release = ROOT / "dist" / catalog["tag"]
    script = release / NAME
    asset = release / catalog["package"]["archive"]
    stock = workspace / "work/backup/Tower Wizard.pck"
    active = real / "Tower Wizard.pck"
    live_hash = sha(active)
    assert sha(asset) == catalog["package"]["archive_sha256"] and sha(stock) == catalog["legacy"]["base_sha256"]
    with ZipFile(asset) as zipped:
        assert zipped.testzip() is None
        assert set(zipped.namelist()) == {"recipe.json", "Galmuri9.res", "Galmuri11.res", "extra.ko.translation",
            "keydot.exe", "Galmuri-OFL-1.1.txt", "KeyDot-MIT.txt"}
        assert b"SIL OPEN FONT LICENSE" in zipped.read("Galmuri-OFL-1.1.txt")
        assert b"Copyright (c) 2025 Titoot" in zipped.read("KeyDot-MIT.txt")

    work = Path(tempfile.mkdtemp(prefix="portable-verify-", dir=ROOT / "work"))
    test, env = cached_launcher(script, catalog, asset, work)
    steamapps = work / "SteamLibrary/steamapps"
    fixture = steamapps / "common/Steam Test & 한글"
    fixture.mkdir(parents=True)
    manifest = steamapps / "appmanifest_3372980.acf"
    manifest.write_text('"AppState"\n{\n"appid" "3372980"\n"buildid" "99999999"\n}\n', encoding="utf-8")
    pck = fixture / "Tower Wizard.pck"
    for runtime in real.glob("*.dll"):
        shutil.copyfile(runtime, fixture / runtime.name)
    shutil.copyfile(real / "Tower Wizard.exe", fixture / "Tower Wizard.exe")
    (fixture / "steam_appid.txt").write_text("3372980\n", encoding="ascii")

    Pack, key, updated, incompatible, changes, config, original_config, new_key = reproduce_unknown(
        work, workspace, real, stock)
    results = []
    shutil.copyfile(stock, pck)
    output = invoke(test, ["1", "0"], fixture, env)
    assert "한국어 패치를 적용했습니다" in output and "영어로 표시합니다" not in output
    patched = sha(pck)
    shutil.copyfile(pck, work / "verified-current.pck")
    invoke(test, ["1", "0"], fixture, env)
    assert sha(pck) == patched
    invoke(test, ["2", "0"], fixture, env)
    assert sha(pck) == sha(stock)
    results.append("Current stock install, deterministic reinstall and hash-exact restore")

    if live_hash in catalog["legacy"]["patched_sha256"]:
        shutil.copyfile(active, pck)
        invoke(test, ["2", "0"], fixture, env)
        assert sha(pck) == sha(stock)
        shutil.copyfile(active, pck)
        invoke(test, ["1", "0"], fixture, env)
        assert sha(pck) == patched
        results.append("The user's original error PCK can be restored or migrated directly")

    # Steam replaces the patched PCK. The old receipt must never restore the old Steam build over it.
    shutil.copyfile(updated, pck)
    invoke(test, ["2", "0"], fixture, env)
    assert sha(pck) == sha(updated)
    output = invoke(test, ["1", "0"], fixture, env)
    assert "Steam 빌드 99999999" in output and "2개 항목은 영어로 표시합니다" in output
    updated_patched = sha(pck)
    shutil.copyfile(pck, work / "verified-update.pck")
    (work / "new-key.txt").write_text(new_key, encoding="ascii")
    pack = Pack(pck.read_bytes(), key)
    pack.verify()
    assert pack.read("res://compatibility-fixture.txt") == changes["res://compatibility-fixture.txt"]
    assert pack.read("res://translation.en.translation") == changes["res://translation.en.translation"]
    assert pack.read("res://Options.gd").endswith(b"# unrelated Steam update comment\n")
    from project_settings import read_settings
    actual = read_settings(pack.read("res://project.binary"))
    assert actual["application/config/version"] == config["application/config/version"]
    assert {k for k in original_config if actual[k] != original_config[k]} == {
        "application/config/version", "internationalization/locale/translations"}
    invoke(test, ["1", "0"], fixture, env)
    assert sha(pck) == updated_patched
    invoke(test, ["2", "0"], fixture, env)
    assert sha(pck) == sha(updated)
    results.append("Unknown Steam build installs and restores independently, preserving new files, settings and script edits")
    results.append("New and changed optimized messages are retained as English")

    shutil.copyfile(incompatible, pck)
    fingerprint = sha(pck)
    output = invoke(test, ["1", "0"], fixture, env, expected=1)
    assert "호환성을 확인하지 못했습니다" in output and "Options.gd" in output and sha(pck) == fingerprint
    assert not (fixture / ("Tower Wizard.pck.ko-original." + fingerprint[:12])).exists()
    assert not list(fixture.glob(".twko-*"))
    results.append("Incompatible script anchor leaves the game file untouched")

    output = invoke(script, ["3", "0"])
    assert "감지된 설치 경로" in output and str(catalog["legacy"]["steam_build"]) in output
    results.append("Support menu detects the real Steam library")
    exercise_download(script, catalog, asset, stock, fixture, work)
    results.append("Cold download checks SHA-256 and follows a redirect, then restores offline")
    assert sha(active) == live_hash

    (work / "results.txt").write_text("\n".join(results) + "\n", encoding="utf-8")
    for result in results:
        print("PASS", result)
    print("Evidence:", work / "results.txt")


if __name__ == "__main__":
    main()
