from __future__ import annotations

from pathlib import Path

import pytest
from PIL import Image

from island_background_animator.errors import InputImageError
from island_background_animator.formats import validate_input_image


def make_image(path: Path, image_format: str) -> None:
    Image.new("RGB", (16, 12), (20, 80, 140)).save(path, format=image_format)


def test_rejects_jpeg_that_only_fails_during_full_decode(tmp_path: Path) -> None:
    source = tmp_path / "truncated.jpg"
    make_image(source, "JPEG")
    source.write_bytes(source.read_bytes()[:-3])

    # Pillow's structural pass accepts this truncated payload. The second load
    # in validate_input_image must still decode every pixel and reject it.
    with Image.open(source) as image:
        image.verify()

    with pytest.raises(InputImageError, match="invalid image content"):
        validate_input_image(source)


def test_rejects_valid_but_unsupported_image_format(tmp_path: Path) -> None:
    source = tmp_path / "source.bmp"
    make_image(source, "BMP")

    with pytest.raises(InputImageError, match="unsupported image format BMP"):
        validate_input_image(source)


def test_rejects_unsupported_content_despite_supported_extension(tmp_path: Path) -> None:
    source = tmp_path / "disguised.png"
    make_image(source, "GIF")

    with pytest.raises(InputImageError, match="unsupported image format GIF"):
        validate_input_image(source)
