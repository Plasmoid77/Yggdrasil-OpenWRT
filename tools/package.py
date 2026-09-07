#!/usr/bin/env python3
"""Build a deterministic status distribution from tracked source.

Host-side only. Does not install anything or change public download locations.
"""
import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("source/yggdrasil-status")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT)


def collect(version):
    files = {}
    entries = git("ls-files", "--stage", "-z", "--", str(SOURCE)).decode().split("\0")
    for entry in filter(None, entries):
        metadata, name = entry.split("\t", 1)
        mode, _blob, stage = metadata.split()
        path = ROOT / name
        relative = Path(name).relative_to(SOURCE).as_posix()
        if stage != "0" or mode not in ("100644", "100755"):
            raise ValueError(f"unmerged or unsupported source entry: {name}")
        if relative in ("BUILD_INFO.json", "MANIFEST.sha256"):
            raise ValueError(f"source collides with generated metadata: {name}")
        parts = Path(name).parts
        if any(ROOT.joinpath(*parts[:i]).is_symlink() for i in range(1, len(parts) + 1)) or not path.is_file():
            raise ValueError(f"source must be a regular file: {name}")
        if "\n" in relative or "\r" in relative or "\\" in relative:
            raise ValueError(f"unsupported manifest filename: {name}")
        files[relative] = (path.read_bytes(), int(mode, 8) & 0o777)
    if "install.sh" not in files:
        raise ValueError("no tracked status source found; stage a source rename before building")
    info = {
        "version": version,
        "source_commit": git("rev-parse", "HEAD").decode().strip(),
        "source_dirty": bool(git("status", "--porcelain", "--untracked-files=no", "--", str(SOURCE))),
        "note": "Tracked working-tree files; SHA-256 manifest identifies the exact payload.",
    }
    files["BUILD_INFO.json"] = ((json.dumps(info, sort_keys=True, indent=2) + "\n").encode(), 0o644)
    manifest = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, (data, _mode) in sorted(files.items()))
    files["MANIFEST.sha256"] = (manifest.encode(), 0o644)
    return files


def archive_bytes(name, files, epoch):
    raw = io.BytesIO()
    directories = {name}
    for relative in files:
        parent = Path(name, relative).parent
        while parent != Path("."):
            directories.add(parent.as_posix())
            parent = parent.parent
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for directory in sorted(directories):
            item = tarfile.TarInfo(directory)
            item.type = tarfile.DIRTYPE
            item.mode, item.mtime = 0o755, epoch
            tar.addfile(item)
        for relative, (data, mode) in sorted(files.items()):
            item = tarfile.TarInfo(f"{name}/{relative}")
            item.size, item.mode, item.mtime = len(data), mode, epoch
            tar.addfile(item, io.BytesIO(data))
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", filename="", mtime=epoch, compresslevel=9) as stream:
        stream.write(raw.getvalue())
    return compressed.getvalue()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="new distribution label, e.g. dev-<commit>; frozen labels are refused")
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    parser.add_argument("--release", action="store_true",
                        help="require a numeric version and a clean committed checkout")
    args = parser.parse_args()
    created = []
    try:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.version):
            raise ValueError("version must be 1-80 ASCII letters/digits/dot/underscore/hyphen, starting with a letter or digit")
        name = f"yggdrasil-status-{args.version}"
        if (ROOT / "packages" / f"{name}.tar.gz").exists():
            raise ValueError("that frozen release label already exists; use a new development label")
        if args.release:
            if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?", args.version):
                raise ValueError("release version must be vMAJOR.MINOR or vMAJOR.MINOR.PATCH without leading zeros")
            if git("status", "--porcelain", "--untracked-files=no"):
                raise ValueError("release builds require a clean committed checkout, including tooling")
            if git("ls-files", "--others", "--exclude-standard", "--", str(SOURCE)):
                raise ValueError("release source contains untracked files; commit or remove them first")
        epoch = int(os.environ.get("SOURCE_DATE_EPOCH", "0"))
        if not 0 <= epoch <= 0xFFFFFFFF:
            raise ValueError("SOURCE_DATE_EPOCH must fit an unsigned 32-bit timestamp")
        output = args.output.resolve()
        if output.is_relative_to((ROOT / SOURCE).resolve()):
            raise ValueError("output must be outside the source directory")
        archive = output / f"{name}.tar.gz"
        checksum = output / f"{name}.tar.gz.sha256"
        if archive.exists() or checksum.exists():
            raise ValueError("output already exists; refusing to overwrite a distribution")
        data = archive_bytes(name, collect(args.version), epoch)
        digest = hashlib.sha256(data).hexdigest()
        output.mkdir(parents=True, exist_ok=True)
        for path, content in ((archive, data), (checksum, f"{digest}  {archive.name}\n".encode())):
            with path.open("xb") as stream:
                created.append(path)
                stream.write(content)
        print(archive)
        print(checksum)
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        for path in created:
            path.unlink(missing_ok=True)
        print(f"package: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
