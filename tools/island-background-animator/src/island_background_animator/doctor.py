"""Dependency and media-capability checks."""

from __future__ import annotations

import importlib.metadata
import re
import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass
from typing import Any

from PIL import Image, features


@dataclass(frozen=True)
class Check:
    """One machine-readable dependency verdict."""

    name: str
    ok: bool
    detail: str

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def run_checks() -> list[Check]:
    """Return every dependency check without stopping at the first failure."""
    checks = [
        _python_check(),
        _package_check("Pillow"),
        _package_check("jsonschema"),
        _pillow_format_check(),
        _command_check("ffmpeg"),
        _command_check("ffprobe"),
    ]
    checks.append(_ffmpeg_encoder_check() if checks[-2].ok else _missing_encoder_check())
    return checks


def _python_check() -> Check:
    version = sys.version_info
    ok = version.major == 3 and version.minor == 12
    detail = f"{version.major}.{version.minor}.{version.micro}; expected 3.12.x"
    return Check("python", ok, detail)


def _package_check(distribution: str) -> Check:
    try:
        version = importlib.metadata.version(distribution)
    except importlib.metadata.PackageNotFoundError:
        return Check(distribution.lower(), False, "not installed")
    return Check(distribution.lower(), True, version)


def _pillow_format_check() -> Check:
    Image.init()
    registered = set(Image.registered_extensions().values())
    required = {"JPEG", "PNG", "WEBP"}
    missing = sorted(required - registered)
    webp_ok = features.check("webp") is True
    ok = not missing and webp_ok
    detail = (
        "PNG, JPEG, and WebP available" if ok else f"missing: {', '.join(missing) or 'WebP codec'}"
    )
    return Check("pillow-formats", ok, detail)


def _command_check(command: str) -> Check:
    executable = shutil.which(command)
    if executable is None:
        return Check(command, False, "not found on PATH")

    result = subprocess.run(
        [executable, "-version"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    first_line = (
        (result.stdout or result.stderr).splitlines()[0] if result.returncode == 0 else "failed"
    )
    return Check(command, result.returncode == 0, first_line)


def _ffmpeg_encoder_check() -> Check:
    executable = shutil.which("ffmpeg")
    if executable is None:
        return _missing_encoder_check()

    result = subprocess.run(
        [executable, "-hide_banner", "-encoders"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    required = {"gif", "libvpx-vp9", "libx264"}
    found = {
        match.group(1)
        for line in result.stdout.splitlines()
        if (match := re.match(r"^\s*V\S*\s+(gif|libvpx-vp9|libx264)\s", line))
    }
    missing = sorted(required - found)
    ok = result.returncode == 0 and not missing
    detail = "GIF, VP9, and H.264 available" if ok else f"missing: {', '.join(missing)}"
    return Check("ffmpeg-encoders", ok, detail)


def _missing_encoder_check() -> Check:
    return Check("ffmpeg-encoders", False, "ffmpeg unavailable")
