"""Deterministic static-master candidate review and approval."""

from __future__ import annotations

import json
import os
import re
import shutil
import uuid
from datetime import UTC, datetime
from math import ceil
from pathlib import Path
from typing import Any, cast

from PIL import Image, ImageDraw, ImageFont

from island_background_animator.config import (
    SCHEMA_VERSION,
    STATIC_APPROVAL_SCHEMA_NAME,
    STATIC_APPROVAL_V2_SCHEMA_NAME,
    STATIC_CANDIDATES_SCHEMA_NAME,
    load_job_config,
    validate_document,
)
from island_background_animator.errors import StaticMasterError
from island_background_animator.formats import ValidatedImage, validate_input_image

CANDIDATES_MANIFEST = Path("state/static-candidates.json")
APPROVAL_RECORD = Path("state/approvals/static-master.json")
APPROVED_MASTER = Path("static/approved/master.png")
CONTACT_SHEET = Path("reports/static-master-contact-sheet.png")
LABEL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._-]{0,59}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")

SHEET_COLUMNS = 3
SHEET_PREVIEW_WIDTH = 480
SHEET_PREVIEW_HEIGHT = 320
SHEET_LABEL_HEIGHT = 48
SHEET_GUTTER = 16


def register_candidate(job_directory: Path, source: Path, label: str) -> dict[str, Any]:
    """Copy one fully decoded PNG into the job without changing its bytes."""
    root = _job_root(job_directory)
    _require_pending_approval(root)
    clean_label = label.strip()
    if not LABEL_PATTERN.fullmatch(clean_label):
        raise StaticMasterError(
            "candidate label must be 1-60 letters, digits, spaces, dots, underscores, or hyphens"
        )

    image = validate_input_image(source.expanduser().resolve())
    if image.format != "PNG":
        raise StaticMasterError(
            f"static-master candidate must contain PNG data, got {image.format}"
        )

    manifest = _load_candidates(root)
    candidates = cast(list[dict[str, Any]], manifest["candidates"])
    if any(candidate["sha256"] == image.sha256 for candidate in candidates):
        raise StaticMasterError(f"candidate bytes already registered: {image.sha256}")
    if candidates:
        first = candidates[0]
        if (image.width, image.height) != (first["width"], first["height"]):
            raise StaticMasterError(
                "candidate dimensions must match the first candidate: "
                f"expected {first['width']}x{first['height']}, got {image.width}x{image.height}"
            )

    candidate_id = f"candidate-{len(candidates) + 1:03d}"
    slug = re.sub(r"[^a-z0-9]+", "-", clean_label.lower()).strip("-")
    filename = f"{candidate_id}-{slug}-{image.sha256[:12]}.png"
    stored_path = Path("static/candidates") / filename
    destination = root / stored_path
    if os.path.lexists(destination):
        raise StaticMasterError(f"candidate destination already exists: {destination}")

    record: dict[str, Any] = {
        "id": candidate_id,
        "label": clean_label,
        "original_name": image.source.name,
        "stored_path": stored_path.as_posix(),
        "sha256": image.sha256,
        "format": image.format,
        "width": image.width,
        "height": image.height,
        "mode": image.mode,
    }
    updated = {"schema_version": SCHEMA_VERSION, "candidates": [*candidates, record]}
    validate_document(updated, STATIC_CANDIDATES_SCHEMA_NAME)

    temporary = destination.parent / f".{destination.name}.tmp-{uuid.uuid4().hex}"
    try:
        shutil.copyfile(image.source, temporary)
        copied = validate_input_image(temporary)
        if copied.format != "PNG" or copied.sha256 != image.sha256:
            raise StaticMasterError("candidate copy did not preserve the validated PNG bytes")
        os.replace(temporary, destination)
        _write_json_atomic(root / CANDIDATES_MANIFEST, updated)
    except Exception:
        temporary.unlink(missing_ok=True)
        destination.unlink(missing_ok=True)
        raise

    return record


def create_contact_sheet(job_directory: Path) -> Path:
    """Render a deterministic labeled review sheet from verified candidates."""
    root = _job_root(job_directory)
    candidates = _verified_candidates(root)
    if not candidates:
        raise StaticMasterError("no static-master candidates are registered")

    columns = min(SHEET_COLUMNS, len(candidates))
    rows = ceil(len(candidates) / columns)
    width = SHEET_GUTTER + columns * (SHEET_PREVIEW_WIDTH + SHEET_GUTTER)
    cell_height = SHEET_LABEL_HEIGHT + SHEET_PREVIEW_HEIGHT
    height = SHEET_GUTTER + rows * (cell_height + SHEET_GUTTER)
    sheet = Image.new("RGB", (width, height), "#0B1220")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=20)

    for index, (record, candidate_path, _) in enumerate(candidates):
        column = index % columns
        row = index // columns
        x = SHEET_GUTTER + column * (SHEET_PREVIEW_WIDTH + SHEET_GUTTER)
        y = SHEET_GUTTER + row * (cell_height + SHEET_GUTTER)
        draw.rounded_rectangle(
            (x, y, x + SHEET_PREVIEW_WIDTH, y + cell_height),
            radius=10,
            fill="#1B1838",
            outline="#8E82FE",
            width=2,
        )
        draw.text(
            (x + 14, y + 13),
            f"{record['id']}  {record['label']}",
            font=font,
            fill="#FFFFFF",
        )
        with Image.open(candidate_path) as image:
            preview = image.convert("RGB")
            preview.thumbnail(
                (SHEET_PREVIEW_WIDTH, SHEET_PREVIEW_HEIGHT),
                Image.Resampling.LANCZOS,
            )
        preview_x = x + (SHEET_PREVIEW_WIDTH - preview.width) // 2
        preview_y = y + SHEET_LABEL_HEIGHT + (SHEET_PREVIEW_HEIGHT - preview.height) // 2
        sheet.paste(preview, (preview_x, preview_y))

    destination = root / CONTACT_SHEET
    temporary = destination.parent / f".{destination.name}.tmp-{uuid.uuid4().hex}"
    try:
        sheet.save(temporary, format="PNG", optimize=False, compress_level=9)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def approve_static_master(
    job_directory: Path,
    candidate_id: str,
    approved_by: str,
    confirm_sha256: str,
    *,
    approved_at: str | None = None,
) -> Path:
    """Freeze one checksum-confirmed candidate without re-encoding it."""
    root = _job_root(job_directory)
    _require_pending_approval(root)
    approver = approved_by.strip()
    if not approver:
        raise StaticMasterError("approved-by must name the human approver")
    confirmed_hash = confirm_sha256.strip().lower()
    if not SHA256_PATTERN.fullmatch(confirmed_hash):
        raise StaticMasterError("confirm-sha256 must be exactly 64 hexadecimal characters")

    candidates = _verified_candidates(root)
    selected = next(
        (candidate for candidate in candidates if candidate[0]["id"] == candidate_id), None
    )
    if selected is None:
        raise StaticMasterError(f"unknown static-master candidate: {candidate_id}")
    record, candidate_path, image = selected
    if confirmed_hash != record["sha256"]:
        raise StaticMasterError(
            f"approval checksum does not match {candidate_id}: expected {record['sha256']}"
        )
    if image.sha256 != confirmed_hash:
        raise StaticMasterError(f"candidate changed after registration: {candidate_id}")

    destination = root / APPROVED_MASTER
    if os.path.lexists(destination):
        raise StaticMasterError(f"approved static master already exists: {destination}")
    timestamp = _approval_timestamp(approved_at)
    approval = {
        "schema_version": 2,
        "state": "approved",
        "candidate_id": candidate_id,
        "candidate_path": record["stored_path"],
        "sha256": image.sha256,
        "approved_by": approver,
        "approved_at": timestamp,
    }
    validate_document(approval, STATIC_APPROVAL_V2_SCHEMA_NAME)

    approval_path = root / APPROVAL_RECORD
    job_state_path = root / "state/job-state.json"
    original_approval = approval_path.read_bytes()
    original_job_state = job_state_path.read_bytes()
    job_state = cast(dict[str, Any], json.loads(original_job_state))
    job_state["static_master"] = "approved"
    temporary = destination.parent / f".{destination.name}.tmp-{uuid.uuid4().hex}"
    try:
        shutil.copyfile(candidate_path, temporary)
        copied = validate_input_image(temporary)
        if copied.format != "PNG" or copied.sha256 != image.sha256:
            raise StaticMasterError("approved master copy did not preserve candidate bytes")
        os.replace(temporary, destination)
        _write_json_atomic(approval_path, approval)
        _write_json_atomic(job_state_path, job_state)
    except Exception:
        temporary.unlink(missing_ok=True)
        destination.unlink(missing_ok=True)
        _write_bytes_atomic(approval_path, original_approval)
        _write_bytes_atomic(job_state_path, original_job_state)
        raise

    return destination


def _job_root(job_directory: Path) -> Path:
    root = job_directory.expanduser().resolve()
    if not root.is_dir():
        raise StaticMasterError(f"job directory not found: {root}")
    load_job_config(root / "job.json")
    return root


def _load_candidates(root: Path) -> dict[str, Any]:
    path = root / CANDIDATES_MANIFEST
    if not path.exists():
        return {"schema_version": SCHEMA_VERSION, "candidates": []}
    document = _read_json_object(path)
    validate_document(document, STATIC_CANDIDATES_SCHEMA_NAME)
    return document


def _load_approval(root: Path) -> dict[str, Any]:
    document = _read_json_object(root / APPROVAL_RECORD)
    version = document.get("schema_version")
    if version == 1:
        validate_document(document, STATIC_APPROVAL_SCHEMA_NAME)
    elif version == 2:
        validate_document(document, STATIC_APPROVAL_V2_SCHEMA_NAME)
    else:
        raise StaticMasterError(f"unsupported static approval schema version: {version!r}")
    return document


def _require_pending_approval(root: Path) -> None:
    approval = _load_approval(root)
    if approval["state"] != "pending":
        raise StaticMasterError("static master is already approved and frozen")


def _verified_candidates(
    root: Path,
) -> list[tuple[dict[str, Any], Path, ValidatedImage]]:
    manifest = _load_candidates(root)
    verified: list[tuple[dict[str, Any], Path, ValidatedImage]] = []
    candidates_root = (root / "static/candidates").resolve()
    for record in cast(list[dict[str, Any]], manifest["candidates"]):
        candidate_path = (root / record["stored_path"]).resolve()
        if candidate_path.parent != candidates_root:
            raise StaticMasterError(
                f"candidate path escapes its directory: {record['stored_path']}"
            )
        image = validate_input_image(candidate_path)
        if image.format != "PNG":
            raise StaticMasterError(f"candidate is no longer PNG data: {record['id']}")
        if image.sha256 != record["sha256"]:
            raise StaticMasterError(f"candidate changed after registration: {record['id']}")
        if (image.width, image.height, image.mode) != (
            record["width"],
            record["height"],
            record["mode"],
        ):
            raise StaticMasterError(
                f"candidate metadata changed after registration: {record['id']}"
            )
        verified.append((record, candidate_path, image))
    return verified


def _read_json_object(path: Path) -> dict[str, Any]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise StaticMasterError(f"required job state not found: {path}") from error
    except json.JSONDecodeError as error:
        raise StaticMasterError(f"invalid JSON in {path}: {error.msg}") from error
    if not isinstance(document, dict):
        raise StaticMasterError(f"job state must be a JSON object: {path}")
    return cast(dict[str, Any], document)


def _approval_timestamp(value: str | None) -> str:
    if value is None:
        return datetime.now(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise StaticMasterError(f"invalid approved-at timestamp: {value}") from error
    if parsed.tzinfo is None:
        raise StaticMasterError("approved-at timestamp must include a timezone")
    return parsed.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def _write_json_atomic(path: Path, document: dict[str, Any]) -> None:
    payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
    _write_bytes_atomic(path, payload)


def _write_bytes_atomic(path: Path, payload: bytes) -> None:
    temporary = path.parent / f".{path.name}.tmp-{uuid.uuid4().hex}"
    try:
        temporary.write_bytes(payload)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)
