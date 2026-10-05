#!/usr/bin/env python3
"""Build and install the self-contained SwiftUI app in ~/Applications."""

from __future__ import annotations

import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

APP_NAME = "Colby GPU Cluster"
BUNDLE_ID = "edu.colby.gpu-cluster.community"
PACKAGE_DIR = Path(__file__).resolve().parent


def build_icns(png_path: Path, out_dir: Path) -> Path | None:
    """Build an AppIcon.icns from a PNG source, returning None when absent."""
    if not png_path.is_file():
        return None

    iconset_dir = out_dir / "AppIcon.iconset"
    iconset_dir.mkdir(parents=True, exist_ok=True)
    for base_size in (16, 32, 128, 256, 512):
        for suffix, size in (("", base_size), ("@2x", base_size * 2)):
            destination = iconset_dir / f"icon_{base_size}x{base_size}{suffix}.png"
            subprocess.run(
                ["sips", "-z", str(size), str(size), str(png_path), "--out", str(destination)],
                check=True,
                capture_output=True,
            )

    icns_path = out_dir / "AppIcon.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset_dir), "-o", str(icns_path)],
        check=True,
        capture_output=True,
    )
    return icns_path


def short_version(package_dir: Path = PACKAGE_DIR) -> str:
    """Return a git-derived marketing version, with a stable fallback."""
    try:
        result = subprocess.run(
            ["git", "rev-list", "--count", "HEAD"],
            cwd=package_dir,
            check=True,
            capture_output=True,
            text=True,
        )
        return f"1.0.{int(result.stdout.strip())}"
    except (OSError, subprocess.SubprocessError, ValueError):
        return "1.0.0"


def build_release(package_dir: Path = PACKAGE_DIR) -> Path:
    subprocess.run(
        ["swift", "build", "-c", "release", "--package-path", str(package_dir)],
        check=True,
    )
    result = subprocess.run(
        [
            "swift",
            "build",
            "-c",
            "release",
            "--package-path",
            str(package_dir),
            "--show-bin-path",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    binary = Path(result.stdout.strip()) / "ColbyGPUCluster"
    if not binary.is_file():
        raise FileNotFoundError(f"Swift build did not produce {binary}")
    return binary


def install_app(
    *,
    output_dir: Path | None = None,
    binary: Path | None = None,
    bundle_id: str = BUNDLE_ID,
) -> Path:
    output_dir = output_dir or Path.home() / "Applications"
    output_dir.mkdir(parents=True, exist_ok=True)
    binary = binary or build_release()
    app_path = output_dir / f"{APP_NAME}.app"

    with tempfile.TemporaryDirectory(prefix="colby-gpu-cluster-") as temp_dir:
        staged_app = Path(temp_dir) / app_path.name
        macos_dir = staged_app / "Contents" / "MacOS"
        resources_dir = staged_app / "Contents" / "Resources"
        macos_dir.mkdir(parents=True)
        resources_dir.mkdir(parents=True)

        executable = macos_dir / APP_NAME
        shutil.copy2(binary, executable)
        executable.chmod(0o755)
        (staged_app / "Contents" / "PkgInfo").write_text("APPL????", encoding="ascii")

        version = datetime.now(timezone.utc).strftime("%Y%m%d%H%M")
        icon_path = build_icns(PACKAGE_DIR / "AppIcon.png", Path(temp_dir))
        if icon_path is not None:
            shutil.copy2(icon_path, resources_dir / icon_path.name)
        info = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": APP_NAME,
            "CFBundleExecutable": APP_NAME,
            "CFBundleIdentifier": bundle_id,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": APP_NAME,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": short_version(),
            "CFBundleVersion": version,
            "LSApplicationCategoryType": "public.app-category.developer-tools",
            "LSUIElement": True,
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
            "NSSupportsAutomaticGraphicsSwitching": True,
        }
        if icon_path is not None:
            info["CFBundleIconFile"] = "AppIcon"
        with (staged_app / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle, sort_keys=True)

        subprocess.run(
            ["/usr/bin/codesign", "--force", "--deep", "--sign", "-", str(staged_app)],
            check=True,
        )
        if app_path.exists():
            shutil.rmtree(app_path)
        shutil.move(staged_app, app_path)

    return app_path


def main() -> int:
    parser = argparse.ArgumentParser(description=f"Build and install {APP_NAME}")
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--bundle-id", default=BUNDLE_ID)
    parser.add_argument("--binary", type=Path, help="package an existing release binary")
    args = parser.parse_args()

    app_path = install_app(
        output_dir=args.output_dir,
        binary=args.binary,
        bundle_id=args.bundle_id,
    )
    print(app_path)
    return os.EX_OK


if __name__ == "__main__":
    raise SystemExit(main())
