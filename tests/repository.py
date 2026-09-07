#!/usr/bin/env python3
"""Host-only documentation and distribution checks; never installs on a router."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "source/yggdrasil-status"


def without_fences(text):
    lines, marker = [], None
    for line in text.splitlines():
        fence = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence:
            current = fence.group(1)[0]
            if marker is None:
                marker = current
            elif marker == current:
                marker = None
            continue
        if marker is None:
            lines.append(line)
    return "\n".join(lines)


def anchors(text):
    found, counts = set(), {}
    for line in without_fences(text).splitlines():
        heading = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if not heading:
            continue
        label = re.sub(r"<[^>]+>", "", heading.group(1))
        label = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", label)
        slug = re.sub(r"[^\w\- ]", "", label.lower()).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        found.add(slug if not count else f"{slug}-{count}")
    return found


def link_errors(document, root):
    errors = []
    body = without_fences(document.read_text(encoding="utf-8"))
    for match in re.finditer(r"\[[^\]\n]+\]\(([^)\n]+)\)", body):
        url = match.group(1).strip().split(' "', 1)[0].strip("<>")
        parsed = urlsplit(url)
        if parsed.scheme or parsed.netloc:
            continue
        path = unquote(parsed.path)
        target = (root / path.lstrip("/")) if path.startswith("/") else (document.parent / path)
        if not path:
            target = document
        target = target.resolve()
        if not target.is_relative_to(root.resolve()):
            errors.append(f"link escapes repository: {url}")
        elif not target.exists():
            errors.append(f"missing target: {url}")
        elif parsed.fragment and target.suffix == ".md":
            if unquote(parsed.fragment) not in anchors(target.read_text(encoding="utf-8")):
                errors.append(f"missing heading: {url}")
    return errors


class DocumentationTests(unittest.TestCase):
    def test_tracked_local_links_and_fragments(self):
        files = subprocess.check_output(["git", "ls-files", "-z", "--", "*.md"], cwd=ROOT).decode().split("\0")
        errors = []
        for name in filter(None, files):
            for error in link_errors(ROOT / name, ROOT):
                errors.append(f"{name}: {error}")
        self.assertEqual([], errors)

    def test_checker_rejects_missing_file_and_heading(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            doc = root / "README.md"
            doc.write_text("# Present\n[bad](missing.md)\n[bad](#absent)\n")
            self.assertEqual(2, len(link_errors(doc, root)))
            doc.write_text("# Present\n[ok](#present)\n```text\n[example](missing.md)\n```\n")
            self.assertEqual([], link_errors(doc, root))

    def test_claude_imports_shared_instructions(self):
        self.assertEqual("@AGENTS.md\n", (ROOT / "CLAUDE.md").read_text())
        self.assertTrue((ROOT / "AGENTS.md").is_file())


class PackagingTests(unittest.TestCase):
    def build(self, version, output):
        return subprocess.run(
            [sys.executable, str(ROOT / "tools/package.py"), version, "--output", str(output)],
            cwd=ROOT, text=True, capture_output=True,
            env={**os.environ, "SOURCE_DATE_EPOCH": "0"},
        )

    def test_reproducible_archive_matches_tracked_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            out1, out2 = Path(tmp) / "one", Path(tmp) / "two"
            for out in (out1, out2):
                result = self.build("test-build", out)
                self.assertEqual(0, result.returncode, result.stderr)
            archive = out1 / "yggdrasil-status-test-build.tar.gz"
            self.assertEqual(archive.read_bytes(), (out2 / archive.name).read_bytes())
            checksum = archive.with_name(archive.name + ".sha256").read_text().split()[0]
            self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), checksum)
            files = subprocess.check_output(["git", "ls-files", "-z", "--", str(SOURCE.relative_to(ROOT))], cwd=ROOT).decode().split("\0")
            prefix = "yggdrasil-status-test-build/"
            with tarfile.open(archive) as tar:
                for name in filter(None, files):
                    relative = Path(name).relative_to(SOURCE.relative_to(ROOT)).as_posix()
                    member = tar.getmember(prefix + relative)
                    self.assertEqual((ROOT / name).read_bytes(), tar.extractfile(member).read())
                    self.assertEqual(0, member.uid)
                    self.assertEqual(0, member.gid)
                    self.assertEqual(0, member.mtime)
                self.assertEqual(0o755, tar.getmember(prefix + "install.sh").mode)
                self.assertEqual(0o755, tar.getmember(prefix + "root/usr/libexec/rpcd/luci.yggdrasil-status").mode)
                self.assertEqual(0o644, tar.getmember(prefix + "www/luci-static/resources/view/status/yggdrasil.js").mode)
                info = json.load(tar.extractfile(prefix + "BUILD_INFO.json"))
                self.assertEqual("test-build", info["version"])
                self.assertRegex(info["source_commit"], r"^[0-9a-f]{40}$")
                for line in tar.extractfile(prefix + "MANIFEST.sha256").read().decode().splitlines():
                    digest, relative = line.split("  ", 1)
                    self.assertEqual(digest, hashlib.sha256(tar.extractfile(prefix + relative).read()).hexdigest())
                expected = {prefix + Path(n).relative_to(SOURCE.relative_to(ROOT)).as_posix() for n in filter(None, files)}
                expected |= {prefix + "BUILD_INFO.json", prefix + "MANIFEST.sha256"}
                self.assertEqual(expected, {m.name for m in tar.getmembers() if m.isfile()})

    def test_rejects_bad_version_and_reserved_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            for version in ("../escape", "has space", "", "v5.1"):
                out = Path(tmp) / "out"
                result = self.build(version, out)
                self.assertNotEqual(0, result.returncode)
                self.assertFalse(out.exists(), result.stderr)

    def test_refuses_to_overwrite_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "out"
            self.assertEqual(0, self.build("test-build", out).returncode)
            original = {p.name: p.read_bytes() for p in out.iterdir()}
            result = self.build("test-build", out)
            self.assertNotEqual(0, result.returncode)
            self.assertEqual(original, {p.name: p.read_bytes() for p in out.iterdir()})

    def fixture_repo(self, parent):
        root = parent / "repo"
        source = root / "source/yggdrasil-status"
        (source / "root").mkdir(parents=True)
        (root / "tools").mkdir()
        shutil.copy2(ROOT / "tools/package.py", root / "tools/package.py")
        (source / "install.sh").write_text("#!/bin/sh\nexit 0\n")
        (source / "root/config.txt").write_text("tracked fixture\n")
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "commit", "-qm", "fixture"], cwd=root, check=True)
        return root, source

    def test_rejects_symlinked_source_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            root, source = self.fixture_repo(parent)
            external = parent / "external"
            external.mkdir()
            (external / "config.txt").write_text("SYNTHETIC PRIVATE CONTENT\n")
            shutil.rmtree(source / "root")
            (source / "root").symlink_to(external, target_is_directory=True)
            result = subprocess.run([sys.executable, str(root / "tools/package.py"), "test",
                                     "--output", str(parent / "out")], capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode, "symlinked directory was distributed")
            self.assertFalse((parent / "out").exists())

    def test_rejects_source_metadata_collision(self):
        with tempfile.TemporaryDirectory() as tmp:
            parent = Path(tmp)
            root, source = self.fixture_repo(parent)
            (source / "BUILD_INFO.json").write_text("tracked content must not be overwritten\n")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            result = subprocess.run([sys.executable, str(root / "tools/package.py"), "test",
                                     "--output", str(parent / "out")], capture_output=True, text=True)
            self.assertNotEqual(0, result.returncode, "tracked metadata was silently replaced")
            self.assertFalse((parent / "out").exists())

    def test_untracked_source_files_are_not_distributed(self):
        extra = SOURCE / "untracked-sensitive-fixture.txt"
        self.assertFalse(extra.exists())
        try:
            extra.write_text("SYNTHETIC-DO-NOT-DISTRIBUTE\n")
            with tempfile.TemporaryDirectory() as tmp:
                result = self.build("test-build", Path(tmp) / "out")
                self.assertEqual(0, result.returncode, result.stderr)
                with tarfile.open(Path(tmp) / "out/yggdrasil-status-test-build.tar.gz") as tar:
                    self.assertFalse(any(extra.name in m.name for m in tar.getmembers()))
        finally:
            extra.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
