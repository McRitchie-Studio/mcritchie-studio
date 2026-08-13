"""Content-based validation for supported source images."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, UnidentifiedImageError

from island_background_animator.errors import InputImageError

SUPPORTED_FORMATS = {
    "JPEG": ".jpg",
    "PNG": ".png",
    "WEBP": ".webp",
}


@dataclass(frozen=True)
class ValidatedImage:
    """Facts read from image bytes, never inferred from a filename."""

    source: Path
    format: str
    extension: str
    width: int
    height: int
    mode: str
    sha256: str


def validate_input_image(path: Path) -> ValidatedImage:
    """Identify and fully decode one PNG, JPEG, or WebP input."""
    if not path.is_file():
        raise InputImageError(f"input image not found: {path}")

    try:
        with Image.open(path) as image:
            detected_format = image.format
            width, height = image.size
            mode = image.mode
            image.verify()

        # verify() checks structure but invalidates the decoder. Reopen and load
        # every pixel so truncated payloads cannot pass as usable source images.
        with Image.open(path) as image:
            image.load()
    except (OSError, SyntaxError, UnidentifiedImageError) as error:
        raise InputImageError(f"invalid image content: {path}") from error

    if detected_format not in SUPPORTED_FORMATS:
        actual = detected_format or "unknown"
        raise InputImageError(
            f"unsupported image format {actual}: {path}; expected PNG, JPEG, or WebP"
        )

    return ValidatedImage(
        source=path,
        format=detected_format,
        extension=SUPPORTED_FORMATS[detected_format],
        width=width,
        height=height,
        mode=mode,
        sha256=_sha256(path),
    )


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()
