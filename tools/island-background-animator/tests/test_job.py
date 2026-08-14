from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest
from PIL import Image

from island_background_animator.config import load_job_config
from island_background_animator.errors import InputImageError, JobInitializationError
from island_background_animator.job import JOB_DIRECTORIES, initialize_job


def make_image(path: Path, image_format: str, color: tuple[int, int, int]) -> None:
    Image.new("RGB", (8, 6), color).save(path, format=image_format)


@pytest.mark.parametrize(
    ("image_format", "misleading_suffix", "expected_suffix"),
    [
        ("PNG", ".not-png", ".png"),
        ("JPEG", ".not-jpeg", ".jpg"),
        ("WEBP", ".not-webp", ".webp"),
    ],
)
def test_initializes_job_using_detected_content_format(
    tmp_path: Path,
    image_format: str,
    misleading_suffix: str,
    expected_suffix: str,
) -> None:
    source = tmp_path / f"source{misleading_suffix}"
    make_image(source, image_format, (20, 80, 140))
    expected_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    job_directory = tmp_path / "jobs" / "test-island"

    created = initialize_job(job_directory, "test-island", [source])

    assert created == job_directory.resolve()
    for relative_directory in JOB_DIRECTORIES:
        assert (created / relative_directory).is_dir()

    config = load_job_config(created / "job.json")
    assert config["inputs"]["count"] == 1
    assert config["static_master"]["approval_path"] == "state/approvals/static-master.json"

    manifest = json.loads((created / "inputs/manifest.json").read_text(encoding="utf-8"))
    stored_path = Path(manifest["inputs"][0]["stored_path"])
    assert stored_path.suffix == expected_suffix
    assert manifest["inputs"][0]["format"] == image_format
    assert manifest["inputs"][0]["sha256"] == expected_hash
    assert (created / stored_path).read_bytes() == source.read_bytes()

    approval = json.loads(
        (created / "state/approvals/static-master.json").read_text(encoding="utf-8")
    )
    assert approval == {
        "approved_at": None,
        "approved_by": None,
        "candidate_id": None,
        "candidate_path": None,
        "schema_version": 2,
        "sha256": None,
        "state": "pending",
    }
    candidates = json.loads((created / "state/static-candidates.json").read_text(encoding="utf-8"))
    assert candidates == {"candidates": [], "schema_version": 1}


def test_rejects_extension_spoofed_non_image(tmp_path: Path) -> None:
    source = tmp_path / "fake.png"
    source.write_text("not an image", encoding="utf-8")

    with pytest.raises(InputImageError, match="invalid image content"):
        initialize_job(tmp_path / "job", "test-island", [source])

    assert not (tmp_path / "job").exists()


def test_refuses_to_overwrite_existing_job(tmp_path: Path) -> None:
    source = tmp_path / "source.png"
    make_image(source, "PNG", (10, 20, 30))
    job_directory = tmp_path / "job"
    job_directory.mkdir()
    marker = job_directory / "keep.txt"
    marker.write_text("preserve me", encoding="utf-8")

    with pytest.raises(JobInitializationError, match="already exists"):
        initialize_job(job_directory, "test-island", [source])

    assert marker.read_text(encoding="utf-8") == "preserve me"


def test_rejects_invalid_job_id_before_creating_directory(tmp_path: Path) -> None:
    source = tmp_path / "source.png"
    make_image(source, "PNG", (10, 20, 30))
    job_directory = tmp_path / "job"

    with pytest.raises(JobInitializationError, match="job id"):
        initialize_job(job_directory, "Invalid Job", [source])

    assert not job_directory.exists()
