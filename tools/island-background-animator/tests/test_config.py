from __future__ import annotations

import json
from pathlib import Path

import pytest

from island_background_animator.config import load_job_config
from island_background_animator.errors import ConfigurationError


def valid_config() -> dict[str, object]:
    return {
        "schema_version": 1,
        "job": {"id": "test-island"},
        "inputs": {"count": 1, "manifest": "inputs/manifest.json"},
        "static_master": {
            "candidates_directory": "static/candidates",
            "approved_path": "static/approved/master.png",
            "approval_path": "state/approvals/static-master.json",
        },
    }


def write_config(path: Path, document: dict[str, object]) -> None:
    path.write_text(json.dumps(document), encoding="utf-8")


def test_loads_valid_v1_configuration(tmp_path: Path) -> None:
    path = tmp_path / "job.json"
    document = valid_config()
    write_config(path, document)

    assert load_job_config(path) == document


def test_rejects_unknown_schema_version(tmp_path: Path) -> None:
    path = tmp_path / "job.json"
    document = valid_config()
    document["schema_version"] = 2
    write_config(path, document)

    with pytest.raises(ConfigurationError, match="expected 1, got 2"):
        load_job_config(path)


def test_rejects_unexpected_configuration_fields(tmp_path: Path) -> None:
    path = tmp_path / "job.json"
    document = valid_config()
    document["animation"] = {"enabled": True}
    write_config(path, document)

    with pytest.raises(ConfigurationError, match="Additional properties"):
        load_job_config(path)


def test_rejects_invalid_job_id(tmp_path: Path) -> None:
    path = tmp_path / "job.json"
    document = valid_config()
    document["job"] = {"id": "Not Valid"}
    write_config(path, document)

    with pytest.raises(ConfigurationError, match="does not match"):
        load_job_config(path)
