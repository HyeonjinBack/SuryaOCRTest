#!/usr/bin/env python3
"""Prepare pinned build inputs. The macOS app itself never runs Python.

Usage:
    python3 Scripts/prepare_dependencies.py
    python3 Scripts/prepare_dependencies.py --verify-only
    python3 Scripts/prepare_dependencies.py --only framework --verify-only

Only missing inputs are downloaded. Existing inputs are checked against the
lockfile; mismatches fail without replacing them. Downloads use .download files
and resume on the next invocation. No pip packages are needed.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
CHUNK_SIZE = 1024 * 1024


def sha256_stream(stream):
    digest = hashlib.sha256()
    while True:
        chunk = stream.read(CHUNK_SIZE)
        if not chunk:
            break
        digest.update(chunk)
    return digest.hexdigest()


def sha256_file(path):
    with path.open("rb") as stream:
        return sha256_stream(stream)


def project_path(relative):
    path = ROOT / relative
    if not path.resolve().is_relative_to(ROOT):
        raise RuntimeError("Lockfile path escapes the project: " + relative)
    return path


def check_file(path, spec):
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("Missing regular file: " + str(path))
    expected_size = spec.get("size")
    if expected_size is not None and path.stat().st_size != expected_size:
        raise RuntimeError("Size mismatch: " + str(path))
    if sha256_file(path) != spec["sha256"]:
        raise RuntimeError("SHA-256 mismatch: " + str(path))


def prepare_file(spec, verify_only):
    path = project_path(spec["path"])
    if path.exists():
        check_file(path, spec)
        print("Verified " + spec["path"], flush=True)
        return path
    if verify_only:
        raise RuntimeError("Missing " + spec["path"] + "; run without --verify-only to download it.")
    if not spec["url"].startswith("https://"):
        raise RuntimeError("Downloads must use HTTPS: " + spec["url"])
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".download")
    # A previous invocation may have completed the bytes before interruption.
    if partial.exists() and partial.stat().st_size == spec.get("size"):
        check_file(partial, spec)
    else:
        print("Downloading " + spec["path"], flush=True)
        subprocess.run([
            "curl", "--location", "--fail", "--show-error", "--progress-bar",
            "--proto", "=https", "--proto-redir", "=https",
            "--retry", "3", "--continue-at", "-",
            "--output", str(partial), spec["url"],
        ], check=True)
        check_file(partial, spec)
    partial.replace(path)
    print("Verified " + spec["path"], flush=True)
    return path


def archive_entries(archive, prefix):
    prefix = prefix.rstrip("/") + "/"
    for entry in archive.infolist():
        parts = PurePosixPath(entry.filename)
        if parts.is_absolute() or ".." in parts.parts:
            raise RuntimeError("Unsafe archive path: " + entry.filename)
        if entry.filename.startswith(prefix):
            relative = entry.filename[len(prefix):]
            if relative:
                yield entry, relative


def verify_framework(archive_path, framework, prefix):
    if not framework.is_dir() or framework.is_symlink():
        raise RuntimeError("Missing framework directory: " + str(framework))
    count = 0
    with zipfile.ZipFile(archive_path) as archive:
        for entry, relative in archive_entries(archive, prefix):
            path = framework / relative
            mode = entry.external_attr >> 16
            if stat.S_ISLNK(mode):
                expected = archive.read(entry).decode("utf-8")
                if not path.is_symlink() or os.readlink(path) != expected:
                    raise RuntimeError("Framework symlink mismatch: " + str(path))
                if not path.resolve().is_relative_to(framework.resolve()):
                    raise RuntimeError("Framework symlink escapes its directory: " + str(path))
            elif entry.is_dir():
                if not path.is_dir() or path.is_symlink():
                    raise RuntimeError("Framework directory mismatch: " + str(path))
            else:
                if not path.is_file() or path.is_symlink() or path.stat().st_size != entry.file_size:
                    raise RuntimeError("Framework file mismatch: " + str(path))
                with archive.open(entry) as stream:
                    expected = sha256_stream(stream)
                if sha256_file(path) != expected:
                    raise RuntimeError("Framework content mismatch: " + str(path))
            count += 1
    if count == 0:
        raise RuntimeError("The archive does not contain the expected XCFramework.")
    print("Verified XCFramework against the pinned archive (" + str(count) + " entries)", flush=True)


def prepare_framework(spec, verify_only):
    archive = prepare_file(spec["archive"], verify_only)
    destination = project_path(spec["destination"])
    prefix = spec["archive_framework_path"]
    if destination.exists():
        verify_framework(archive, destination, prefix)
        return
    if verify_only:
        raise RuntimeError("Missing " + spec["destination"] + "; run without --verify-only to extract it.")
    if sys.platform != "darwin":
        raise RuntimeError("XCFramework extraction requires macOS ditto to preserve framework symlinks.")
    # Validate member paths before extraction. The archive hash was checked above.
    with zipfile.ZipFile(archive) as zipped:
        list(archive_entries(zipped, prefix))
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="extract-llama-", dir=ROOT / ".build") as temporary:
        subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), temporary], check=True)
        staged = Path(temporary) / prefix
        verify_framework(archive, staged, prefix)
        shutil.move(str(staged), str(destination))
    print("Installed " + spec["destination"], flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--verify-only", action="store_true", help="Check existing files without network access or changes.")
    parser.add_argument("--only", choices=("all", "framework", "models", "licenses"), default="all")
    args = parser.parse_args()
    lock = json.loads((ROOT / "Dependencies.lock.json").read_text())
    if lock.get("schema_version") != 1:
        raise RuntimeError("Unsupported dependency lockfile version.")
    if args.only in ("all", "licenses"):
        for spec in lock["licenses"]:
            prepare_file(spec, args.verify_only)
    if args.only in ("all", "framework"):
        prepare_framework(lock["llama_cpp"], args.verify_only)
    if args.only in ("all", "models"):
        for spec in lock["surya"]["files"]:
            prepare_file(spec, args.verify_only)
    print("Dependencies are ready.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        print("Dependency preparation failed: " + str(error), file=sys.stderr)
        print("Existing files were not replaced. Move or remove a mismatched file before retrying.", file=sys.stderr)
        sys.exit(1)
