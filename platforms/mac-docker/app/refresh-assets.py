#!/usr/bin/env python3
"""Refresh release-owned email assets once per bundled content change."""
import argparse
import hashlib
import os
from pathlib import Path
import stat
import tempfile

MARKER = ".tautweekly-asset-bundle"


def is_link(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    )


def safe_directory(path):
    # Do not resolve() through links: reject links/junctions in every ancestor.
    for component in reversed((path, *path.parents)):
        if is_link(component):
            raise ValueError(f"Asset directory must not traverse a link: {component}")
        if component.exists() and not component.is_dir():
            raise ValueError(f"Asset directory is not a directory: {component}")


def safe_file(path):
    if is_link(path) or (path.exists() and not path.is_file()):
        raise ValueError(f"Asset destination must be a regular file: {path}")


def atomic_write(path, data):
    safe_directory(path.parent)
    safe_file(path)
    temp_path = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".asset-", dir=path.parent, delete=False) as stream:
            temp_path = Path(stream.name)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        # Replaces the directory entry, never writes through a hard link.
        os.replace(temp_path, path)
    finally:
        if temp_path is not None and temp_path.exists():
            temp_path.unlink()


def refresh_assets(source, data_root, force=False):
    source = Path(os.path.abspath(source))
    data_root = Path(os.path.abspath(data_root))
    if data_root == Path(data_root.anchor) or source == data_root or source in data_root.parents or data_root in source.parents:
        raise ValueError("Asset data must be a separate, non-root directory.")
    safe_directory(source)
    safe_directory(data_root)
    assets = data_root / "assets"
    output = data_root / "output"
    preview = output / "assets"
    marker = data_root / MARKER
    for directory in (assets, output):
        safe_directory(directory)
    safe_file(marker)

    # This one legacy directory symlink is safely unlinked, never followed.
    preview_link = is_link(preview)
    if not preview_link:
        safe_directory(preview)

    bundled = {}
    for path in sorted(source.iterdir()):
        if is_link(path) or not path.is_file() or path.suffix.lower() not in (".gif", ".png"):
            raise ValueError(f"Unexpected bundled asset: {path}")
        bundled[path.name] = path.read_bytes()
    if not bundled:
        raise ValueError("The bundled asset directory is empty.")
    fingerprint = hashlib.sha256()
    for name, data in bundled.items():
        fingerprint.update(name.encode("utf-8") + b"\0" + hashlib.sha256(data).digest())
    bundle_id = "v1:" + fingerprint.hexdigest() + "\n"
    changed = force or not marker.exists() or marker.read_text(encoding="ascii") != bundle_id

    # Preflight all paths before overwriting any asset or advancing the marker.
    for name in bundled:
        safe_file(assets / name)
        if not preview_link:
            safe_file(preview / name)
    mirror_names = set(bundled)
    if assets.exists():
        for path in assets.iterdir():
            # Custom-only directories and links remain untouched and are not followed.
            if not is_link(path) and path.is_file():
                mirror_names.add(path.name)
    if not preview_link:
        for name in mirror_names:
            safe_file(preview / name)

    data_root.mkdir(parents=True, exist_ok=True)
    assets.mkdir(exist_ok=True)
    output.mkdir(exist_ok=True)
    if preview_link:
        # unlink removes only a symlink; no recursive directory deletion.
        preview.unlink()
    preview.mkdir(exist_ok=True)

    restored = 0
    for name, data in bundled.items():
        destination = assets / name
        if changed or not destination.exists():
            atomic_write(destination, data)
            restored += 1
    for name in sorted(mirror_names):
        source_file, destination = assets / name, preview / name
        data = source_file.read_bytes()
        if not destination.exists() or destination.read_bytes() != data:
            atomic_write(destination, data)
    # Failed copies leave the old/missing marker, so the next startup retries.
    if changed:
        atomic_write(marker, bundle_id.encode("ascii"))
    print(f"[INFO] Bundled assets: {restored} restored; "
          f"{'bundle migration' if changed else 'same bundle'}; preview mirror current.")
    return restored


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", default=os.environ.get("TAUTWEEKLY_DATA_DIR", "/data"))
    parser.add_argument("--force", action="store_true", help="Explicit repair: replace every shipped filename.")
    args = parser.parse_args()
    try:
        refresh_assets(Path(__file__).absolute().parent / "assets-default", args.data_root, args.force)
    except (OSError, ValueError) as exc:
        parser.exit(1, f"[ERROR] Asset refresh failed: {exc}\n")


if __name__ == "__main__":
    main()
