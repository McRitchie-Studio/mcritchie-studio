"""Atomic job-directory initialization."""

from __future__ import annotations

import json
import os
import re
import shutil
import uuid
from pathlib import Path
from typing import Any

from island_background_animator.config import (
    JOB_SCHEMA_NAME,
    SCHEMA_VERSION,
    STATIC_APPROVAL_SCHEMA_NAME,
    validate_document,
)
from island_background_animator.errors import JobInitializationError
from island_background_animator.formats import ValidatedImage, validate_input_image

JOB_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

JOB_DIRECTORIES = (
    "inputs/raw",
    "static/candidates",
    "static/approved",
    "state/approvals",
    "work/renders",
    "work/exports",
    "reports",
    "deliverables",
)


def initialize_job(job_directory: Path, job_id: str, inputs: list[Path]) -> Path:
    """Create a complete initial job atomically and return its resolved path."""
    if not JOB_ID_PATTERN.fullmatch(job_id):
        raise JobInitializationError(
            "job id must contain lowercase letters, digits, and single hyphens only"
        )
    if not inputs:
        raise JobInitializationError("at least one input image is required")

    target = job_directory.expanduser().resolve()
    if os.path.lexists(target):
        raise JobInitializationError(f"job directory already exists: {target}")

    validated_inputs = [validate_input_image(path.expanduser().resolve()) for path in inputs]
    target.parent.mkdir(parents=True, exist_ok=True)
    staging = target.parent / f".{target.name}.tmp-{uuid.uuid4().hex}"

    try:
        for relative_directory in JOB_DIRECTORIES:
            (staging / relative_directory).mkdir(parents=True, exist_ok=False)

        manifest = _copy_inputs(staging, validated_inputs)
        approval = _static_approval_placeholder()
        config = _job_config(job_id, len(validated_inputs))

        validate_document(config, JOB_SCHEMA_NAME)
        validate_document(approval, STATIC_APPROVAL_SCHEMA_NAME)

        _write_json(staging / "inputs/manifest.json", manifest)
        _write_json(staging / "state/approvals/static-master.json", approval)
        _write_json(staging / "state/job-state.json", _job_state())
        _write_json(staging / "job.json", config)

        os.replace(staging, target)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise

    return target


def _copy_inputs(staging: Path, images: list[ValidatedImage]) -> dict[str, Any]:
    records: list[dict[str, Any]] = []
    for index, image in enumerate(images, start=1):
        filename = f"{index:03d}-{image.sha256[:12]}{image.extension}"
        stored_path = Path("inputs/raw") / filename
        shutil.copyfile(image.source, staging / stored_path)
        records.append(
            {
                "order": index,
                "original_name": image.source.name,
                "stored_path": stored_path.as_posix(),
                "sha256": image.sha256,
                "format": image.format,
                "width": image.width,
                "height": image.height,
                "mode": image.mode,
            }
        )

    return {"schema_version": SCHEMA_VERSION, "inputs": records}


def _job_config(job_id: str, input_count: int) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "job": {"id": job_id},
        "inputs": {
            "count": input_count,
            "manifest": "inputs/manifest.json",
        },
        "static_master": {
            "candidates_directory": "static/candidates",
            "approved_path": "static/approved/master.png",
            "approval_path": "state/approvals/static-master.json",
        },
    }


def _static_approval_placeholder() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "state": "pending",
        "candidate_path": None,
        "sha256": None,
        "approved_by": None,
        "approved_at": None,
    }


def _job_state() -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "state": "initialized",
        "static_master": "pending",
    }


def _write_json(path: Path, document: dict[str, Any]) -> None:
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
