#!/usr/bin/env python3
"""Isolated persistent asset migration tests; no services or real user data."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "asset_refresh", ROOT / "platforms/nas-docker/app/refresh-assets.py")
refresh = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(refresh)


class AssetRefreshTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tautweekly-assets-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "bundle"
        self.data = self.root / "private data"
        self.source.mkdir()
        self.data.mkdir()
        self.stock = {"movies.gif": b"new gif" * 40, "watched.png": b"original png" * 30}
        for name, data in self.stock.items():
            (self.source / name).write_bytes(data)

    def run_refresh(self, force=False):
        with contextlib.redirect_stdout(io.StringIO()):
            return refresh.refresh_assets(self.source, self.data, force)

    def write(self, relative, data):
        path = self.data / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_migration_overwrites_all_stock_preserves_private_and_custom(self):
        self.write("assets/movies.gif", b"customized gif" * 30)
        self.write("assets/watched.png", b"customized png" * 30)
        protected = ("assets/custom-only.gif", "assets/nested/keep.txt",
                     "config.json", "credentials.json", "state.json", "logs/private.log",
                     "output/custom.html", "output/posters/dynamic.png",
                     "output/media/logo.png", "output/assets/unrelated.png")
        for name in protected:
            self.write(name, b"leave this untouched")
        self.assertEqual(self.run_refresh(), 2)
        for name, data in self.stock.items():
            self.assertEqual((self.data / "assets" / name).read_bytes(), data)
            self.assertEqual((self.data / "output/assets" / name).read_bytes(), data)
        for name in protected:
            self.assertEqual((self.data / name).read_bytes(), b"leave this untouched")
        self.assertEqual((self.data / "output/assets/custom-only.gif").read_bytes(),
                         b"leave this untouched")

    def test_same_bundle_restart_preserves_edits_and_marker_mtime(self):
        self.run_refresh()
        marker = self.data / refresh.MARKER
        old_mtime = marker.stat().st_mtime_ns
        self.write("assets/movies.gif", b"post-update custom")
        self.assertEqual(self.run_refresh(), 0)
        self.assertEqual((self.data / "assets/movies.gif").read_bytes(), b"post-update custom")
        self.assertEqual((self.data / "output/assets/movies.gif").read_bytes(), b"post-update custom")
        self.assertEqual(marker.stat().st_mtime_ns, old_mtime)
        (self.data / "assets/watched.png").unlink()
        self.assertEqual(self.run_refresh(), 1)
        self.assertEqual((self.data / "assets/watched.png").read_bytes(), self.stock["watched.png"])

    def test_next_bundle_refreshes_unchanged_stock_too_and_does_not_delete(self):
        self.run_refresh()
        old_marker = (self.data / refresh.MARKER).read_bytes()
        self.write("assets/movies.gif", b"custom")
        self.write("assets/retired.gif", b"do not delete")
        (self.source / "new.gif").write_bytes(b"new asset")
        self.assertEqual(self.run_refresh(), 3)
        self.assertEqual((self.data / "assets/movies.gif").read_bytes(), self.stock["movies.gif"])
        self.assertEqual((self.data / "assets/retired.gif").read_bytes(), b"do not delete")
        self.assertNotEqual((self.data / refresh.MARKER).read_bytes(), old_marker)
        # An image rollback is a bundle transition as well.
        (self.source / "new.gif").unlink()
        self.assertEqual(self.run_refresh(), 2)
        self.assertTrue((self.data / "assets/new.gif").exists())

    def test_explicit_repair_replaces_customized_stock(self):
        self.run_refresh()
        self.write("assets/movies.gif", b"custom")
        self.assertEqual(self.run_refresh(force=True), 2)
        self.assertEqual((self.data / "assets/movies.gif").read_bytes(), self.stock["movies.gif"])

    def test_failed_copy_keeps_marker_retryable(self):
        self.run_refresh()
        marker = self.data / refresh.MARKER
        previous = marker.read_bytes()
        (self.source / "new.gif").write_bytes(b"new")
        original_write = refresh.atomic_write

        def fail_preview(path, data):
            if path.parent == self.data / "output/assets":
                raise OSError("simulated preview failure")
            original_write(path, data)
        with patch.object(refresh, "atomic_write", side_effect=fail_preview):
            with self.assertRaises(OSError):
                self.run_refresh()
        self.assertEqual(marker.read_bytes(), previous)
        self.assertEqual(self.run_refresh(), 3)
        self.assertNotEqual(marker.read_bytes(), previous)

    def test_directory_in_place_of_stock_is_refused_before_any_writes(self):
        self.write("assets/movies.gif", b"old")
        (self.data / "assets/watched.png").mkdir()
        with self.assertRaises(ValueError):
            self.run_refresh()
        self.assertEqual((self.data / "assets/movies.gif").read_bytes(), b"old")
        self.assertFalse((self.data / refresh.MARKER).exists())

    def make_link(self, link, target, directory=False):
        try:
            link.symlink_to(target, target_is_directory=directory)
        except OSError as exc:
            self.skipTest(f"Host does not permit symbolic links: {exc}")

    def test_directory_links_refused_and_legacy_preview_link_removed_safely(self):
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "sentinel").write_bytes(b"safe")
        for relative in ("assets", "output"):
            link = self.data / relative
            self.make_link(link, outside, True)
            with self.assertRaises(ValueError):
                self.run_refresh()
            link.unlink()
        (self.data / "output").mkdir()
        self.make_link(self.data / "output/assets", outside, True)
        self.assertEqual(self.run_refresh(), 2)
        self.assertFalse((self.data / "output/assets").is_symlink())
        self.assertEqual(list(outside.iterdir()), [outside / "sentinel"])
        self.assertEqual((outside / "sentinel").read_bytes(), b"safe")

    def test_shipped_and_marker_links_refused_custom_links_not_followed(self):
        outside = self.root / "secret"
        outside.write_bytes(b"never read or write this")
        for relative in ("assets/movies.gif", "output/assets/movies.gif", refresh.MARKER):
            link = self.data / relative
            link.parent.mkdir(parents=True, exist_ok=True)
            self.make_link(link, outside)
            with self.assertRaises(ValueError):
                self.run_refresh()
            link.unlink()
        self.make_link(self.data / "assets/custom-link.gif", outside)
        self.run_refresh()
        self.assertTrue((self.data / "assets/custom-link.gif").is_symlink())
        self.assertFalse((self.data / "output/assets/custom-link.gif").exists())
        self.assertEqual(outside.read_bytes(), b"never read or write this")

    def test_hard_link_destination_is_replaced_without_modifying_other_file(self):
        outside = self.root / "outside.gif"
        outside.write_bytes(b"safe")
        (self.data / "assets").mkdir()
        os.link(outside, self.data / "assets/movies.gif")
        self.run_refresh()
        self.assertEqual(outside.read_bytes(), b"safe")
        self.assertEqual((self.data / "assets/movies.gif").read_bytes(), self.stock["movies.gif"])

    def test_invalid_bundle_or_overlapping_roots_are_refused(self):
        (self.source / "nested").mkdir()
        with self.assertRaises(ValueError):
            self.run_refresh()
        (self.source / "nested").rmdir()
        for data_root in (self.source, self.source.parent, self.source / "data",
                          Path(self.root.anchor)):
            with self.assertRaises(ValueError):
                refresh.refresh_assets(self.source, data_root)

    def test_real_bundle_all_files_and_maintained_runtime_wiring(self):
        source = ROOT / "platforms/nas-docker/app/assets-default"
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(refresh.refresh_assets(source, self.data), 61)
        for path in source.iterdir():
            self.assertEqual((self.data / "assets" / path.name).read_bytes(), path.read_bytes())
            self.assertEqual((self.data / "output/assets" / path.name).read_bytes(), path.read_bytes())
        canonical = (source.parent / "refresh-assets.py").read_bytes()
        for platform in ("nas-docker", "mac-docker"):
            app = ROOT / "platforms" / platform / "app"
            self.assertEqual((app / "refresh-assets.py").read_bytes(), canonical)
            entry = (app / "entrypoint.sh").read_text()
            self.assertIn("python3 /opt/tautweekly/refresh-assets.py --data-root /data", entry)
            self.assertNotIn("cp -an", entry)
            self.assertIn("--force", (app / "Repair-Assets.ps1").read_text())
        service = (source.parent / "run-service.sh").read_text()
        self.assertLess(service.index('python3 "$app_root/refresh-assets.py"'),
                        service.index('"$app_root/bin/tautweekly-manager" serve'))


if __name__ == "__main__":
    unittest.main(verbosity=2)
