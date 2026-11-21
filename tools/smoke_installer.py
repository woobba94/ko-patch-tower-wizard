"""Smoke-test the Windows CMD and a local stand-in for the GitHub asset endpoint."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
CMD = "ko-patch-tower-wizard.cmd"


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def invoke(script, choices, game=None, env=None, expected=0):
    argv = ["cmd.exe", "/d", "/c", script.name]
    if game is not None:
        argv.append(str(game))
    result = subprocess.run(
        argv, cwd=script.parent, input=("\r\n".join(choices) + "\r\n").encode("ascii"),
        capture_output=True, timeout=35, env=env,
    )
    message = (result.stdout + result.stderr).decode("utf-8", errors="replace")
    if result.returncode != expected:
        raise AssertionError(f"CMD returned {result.returncode} instead of {expected}\n{message}")
    return message


def exercise_download(script, catalog, build, asset, stock, fixture, work):
    calls = []
    traffic = {"corrupt": True}
    available = work / "http"
    available.mkdir()
    shutil.copyfile(asset, available / "data.zip")
    (available / "wrong.zip").write_bytes(b"corrupt test payload")

    class Handler(SimpleHTTPRequestHandler):
        def do_GET(self):
            calls.append(self.path)
            if self.path == "/" + build["archive"]:
                self.send_response(302)
                self.send_header("Location", "/data")
                self.send_header("Content-Length", "0")
                self.end_headers()
            elif self.path == "/data":
                self.path = "/wrong.zip" if traffic["corrupt"] else "/data.zip"
                super().do_GET()
            else:
                self.send_error(404)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(Handler, directory=str(available)))
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    game_pck = fixture / "Tower Wizard.pck"
    backup = fixture / ("Tower Wizard.pck.ko-original." + build["base_sha256"][:12])
    scratch = work / "network"
    scratch.mkdir()
    test_launcher = scratch / CMD
    test_launcher.write_bytes(script.read_bytes()
        .replace(catalog["release_base"].encode(), f"http://127.0.0.1:{server.server_port}/".encode())
        .replace(b"[Environment]::GetFolderPath('LocalApplicationData')", b"$env:TWKO_VERIFY_CACHE")
        .replace(b"--max-time 45", b"--max-time 10"))
    env = dict(os.environ, TWKO_VERIFY_CACHE=str(scratch / "cache"))
    try:
        shutil.copyfile(stock, game_pck)
        output = invoke(test_launcher, ["1", "0"], fixture, env, expected=1)
        assert "SHA-256이 다릅니다" in output and sha(game_pck) == build["base_sha256"], (output, calls)
        assert not backup.exists() and len(calls) == 2
        traffic["corrupt"] = False
        output = invoke(test_launcher, ["1", "0"], fixture, env)
        assert "GitHub 릴리스에서" in output and len(calls) == 4, (output, calls)
        assert sha(game_pck) == build["patched_sha256"] and sha(backup) == build["base_sha256"]
        invoke(test_launcher, ["2", "0"], fixture, env)
        assert sha(game_pck) == build["base_sha256"] and len(calls) == 4
        return "Cold download followed redirect, rejected wrong SHA-256, installed verified bytes and restored offline"
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument("--stock-pck", type=Path, required=True)
    cli.add_argument("--game-exe", type=Path, required=True)
    cli.add_argument("--legacy-pck", type=Path, required=True)
    args = cli.parse_args()

    catalog = json.loads((ROOT / "src/builds.json").read_text(encoding="utf-8"))
    build = catalog["builds"][0]
    release = ROOT / "dist" / catalog["tag"]
    script = release / CMD
    asset = release / build["archive"]
    assert sha(asset) == build["archive_sha256"] and sha(args.stock_pck) == build["base_sha256"]
    assert sha(args.legacy_pck) in build["legacy_sha256"]
    with ZipFile(asset) as zipped:
        assert zipped.testzip() is None
        assert set(zipped.namelist()) == {"header.bin", "literal.bin", "manifest.json", "Galmuri-OFL-1.1.txt"}
        assert b"SIL OPEN FONT LICENSE" in zipped.read("Galmuri-OFL-1.1.txt")

    out = ROOT / "work"
    out.mkdir(exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="verify-", dir=out))
    # Use the actual generated CMD against a stock fixture with the verified cache populated.
    fixture = work / "Steam 테스트 & 공백"
    fixture.mkdir()
    pck = fixture / "Tower Wizard.pck"
    backup = fixture / ("Tower Wizard.pck.ko-original." + build["base_sha256"][:12])
    shutil.copyfile(args.game_exe, fixture / "Tower Wizard.exe")
    shutil.copyfile(args.stock_pck, pck)
    cache = Path(os.environ["LOCALAPPDATA"]) / "ko-patch-tower-wizard" / "cache"
    cache.mkdir(parents=True, exist_ok=True)
    cached = cache / (build["archive_sha256"] + ".zip")
    seeded = not cached.exists()
    if seeded:
        shutil.copyfile(asset, cached)
    want = [("1", "patched_sha256"), ("1", "patched_sha256"), ("2", "base_sha256"),
            ("2", "base_sha256"), ("1", "patched_sha256"), ("2", "base_sha256")]
    results = []
    try:
        for option, key in want:
            invoke(script, [option, "0"], fixture)
            assert sha(pck) == build[key] and sha(backup) == build["base_sha256"]
        results.append("Actual CMD installed, reinstalled, restored, handled already-stock and reapplied")

        shutil.copyfile(args.legacy_pck, pck)
        invoke(script, ["1", "0"], fixture)
        assert sha(pck) == build["patched_sha256"]
        invoke(script, ["2", "0"], fixture)
        assert sha(pck) == build["base_sha256"]
        results.append("Legacy local patch migrated using the verified original backup")

        with pck.open("ab") as stream:
            stream.write(b"unsupported Steam build fixture")
        unsupported = sha(pck)
        for option in ("1", "2"):
            output = invoke(script, [option, "0"], fixture, expected=1)
            assert "미지원 설치본" in output and unsupported in output and "GitHub 릴리스에서" not in output
            assert sha(pck) == unsupported and sha(backup) == build["base_sha256"]
        results.append("Unsupported PCK blocked both actions before download and preserved the PCK and backup")

        output = invoke(script, ["3", "0"])
        assert str(build["steam_build"]) in output and "감지된 설치 경로" in output
        results.append("CMD support menu found the real Steam installation via the library configuration")
    finally:
        if seeded and cached.exists() and sha(cached) == build["archive_sha256"]:
            cached.unlink()

    network_fixture = work / "Network Steam Test"
    network_fixture.mkdir()
    shutil.copyfile(args.game_exe, network_fixture / "Tower Wizard.exe")
    results.append(exercise_download(script, catalog, build, asset, args.stock_pck, network_fixture, work))
    (work / "results.txt").write_text("\n".join(results) + "\n", encoding="utf-8")
    for result in results:
        print("PASS", result)
    print("Evidence:", work / "results.txt")


if __name__ == "__main__":
    main()
