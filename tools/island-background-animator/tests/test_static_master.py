from __future__ import annotations

import hashlib
import json
from pathlib import Path

import pytest
from PIL import Image

from island_background_animator.errors import StaticMasterError
from island_background_animator.job import initialize_job
from island_background_animator.static_master import (
    approve_static_master,
    create_contact_sheet,
    register_candidate,
)


def make_png(path: Path, color: tuple[int, int, int], *, size: tuple[int, int] = (48, 32)) -> None:
    Image.new("RGB", size, color).save(path, format="PNG")


def make_job(tmp_path: Path) -> Path:
    source = tmp_path / "source.webp"
    Image.new("RGB", (24, 16), (30, 60, 90)).save(source, format="WEBP")
    job = tmp_path / "job"
    initialize_job(job, "static-review", [source])
    return job


def read_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))  # type: ignore[no-any-return]


def test_registers_content_detected_png_without_reencoding(tmp_path: Path) -> None:
    job = make_job(tmp_path)
    candidate = tmp_path / "candidate.jpg"
    make_png(candidate, (142, 130, 254))
    expected_bytes = candidate.read_bytes()

    record = register_candidate(job, candidate, "Editorial Gouache")

    stored = job / str(record["stored_path"])
    assert record["id"] == "candidate-001"
    assert record["format"] == "PNG"
    assert record["sha256"] == hashlib.sha256(expected_bytes).hexdigest()
    assert stored.read_bytes() == expected_bytes


def test_rejects_non_png_candidate_without_changing_manifest(tmp_path: Path) -> None:
    job = make_job(tmp_path)
    candidate = tmp_path / "candidate.png"
    Image.new("RGB", (48, 32), (75, 175, 80)).save(candidate, format="JPEG")

    with pytest.raises(StaticMasterError, match="must contain PNG data, got JPEG"):
        register_candidate(job, candidate, "Misleading Extension")

    manifest = read_json(job / "state/static-candidates.json")
    assert manifest["candidates"] == []
    assert list((job / "static/candidates").iterdir()) == []


def test_contact_sheet_is_repeatable_and_does_not_change_candidates(tmp_path: Path) -> None:
    job = make_job(tmp_path)
    originals: list[bytes] = []
    for index, color in enumerate(((142, 130, 254), (75, 175, 80), (24, 190, 210)), start=1):
        candidate = tmp_path / f"candidate-{index}.png"
        make_png(candidate, color)
        originals.append(candidate.read_bytes())
        register_candidate(job, candidate, f"Direction {index}")

    first = create_contact_sheet(job).read_bytes()
    second = create_contact_sheet(job).read_bytes()

    assert second == first
    with Image.open(job / "reports/static-master-contact-sheet.png") as sheet:
        assert sheet.format == "PNG"
        assert sheet.size == (1504, 400)
        sheet.load()
    manifest = read_json(job / "state/static-candidates.json")
    records = manifest["candidates"]
    assert isinstance(records, list)
    for record, original in zip(records, originals, strict=True):
        assert (job / record["stored_path"]).read_bytes() == original


def test_approval_freezes_exact_checksum_confirmed_candidate(tmp_path: Path) -> None:
    job = make_job(tmp_path)
    candidate = tmp_path / "candidate.png"
    make_png(candidate, (142, 130, 254))
    record = register_candidate(job, candidate, "Editorial Gouache")

    master = approve_static_master(
        job,
        str(record["id"]),
        "Mr. McRitchie",
        str(record["sha256"]),
        approved_at="2026-08-13T03:00:00-06:00",
    )

    stored = job / str(record["stored_path"])
    assert master.read_bytes() == stored.read_bytes() == candidate.read_bytes()
    approval = read_json(job / "state/approvals/static-master.json")
    assert approval == {
        "approved_at": "2026-08-13T09:00:00Z",
        "approved_by": "Mr. McRitchie",
        "candidate_id": "candidate-001",
        "candidate_path": record["stored_path"],
        "schema_version": 2,
        "sha256": record["sha256"],
        "state": "approved",
    }
    assert read_json(job / "state/job-state.json")["static_master"] == "approved"


def test_approval_rejects_candidate_changed_after_registration(tmp_path: Path) -> None:
    job = make_job(tmp_path)
    candidate = tmp_path / "candidate.png"
    make_png(candidate, (142, 130, 254))
    record = register_candidate(job, candidate, "Editorial Gouache")
    stored = job / str(record["stored_path"])
    make_png(stored, (255, 0, 0))

    with pytest.raises(StaticMasterError, match="changed after registration"):
        approve_static_master(
            job,
            str(record["id"]),
            "Mr. McRitchie",
            str(record["sha256"]),
        )

    assert not (job / "static/approved/master.png").exists()
    assert read_json(job / "state/approvals/static-master.json")["state"] == "pending"


def test_approval_is_one_way_and_blocks_later_candidates(tmp_path: Path) -> None:
    job = make_job(tmp_path)
    first = tmp_path / "first.png"
    second = tmp_path / "second.png"
    make_png(first, (142, 130, 254))
    make_png(second, (75, 175, 80))
    record = register_candidate(job, first, "First")
    approve_static_master(
        job,
        str(record["id"]),
        "Mr. McRitchie",
        str(record["sha256"]),
        approved_at="2026-08-13T09:00:00Z",
    )

    with pytest.raises(StaticMasterError, match="already approved and frozen"):
        register_candidate(job, second, "Second")
    with pytest.raises(StaticMasterError, match="already approved and frozen"):
        approve_static_master(
            job,
            str(record["id"]),
            "Mr. McRitchie",
            str(record["sha256"]),
        )
