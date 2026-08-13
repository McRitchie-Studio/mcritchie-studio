"""Load and validate versioned job configuration documents."""

from __future__ import annotations

import json
from importlib import resources
from pathlib import Path
from typing import Any, cast

from jsonschema import Draft202012Validator

from island_background_animator.errors import ConfigurationError

SCHEMA_VERSION = 1
JOB_SCHEMA_NAME = "job-v1.schema.json"
STATIC_APPROVAL_SCHEMA_NAME = "static-approval-v1.schema.json"


def load_schema(name: str) -> dict[str, Any]:
    """Load a schema bundled with the installed package."""
    schema_resource = resources.files("island_background_animator.schemas").joinpath(name)
    return cast(dict[str, Any], json.loads(schema_resource.read_text(encoding="utf-8")))


def validate_document(document: dict[str, Any], schema_name: str) -> None:
    """Validate a JSON-compatible mapping and raise one stable error."""
    validator = Draft202012Validator(load_schema(schema_name))
    errors = sorted(validator.iter_errors(document), key=lambda error: list(error.absolute_path))
    if not errors:
        return

    first = errors[0]
    location = ".".join(str(part) for part in first.absolute_path) or "<root>"
    raise ConfigurationError(f"{location}: {first.message}")


def load_job_config(path: Path) -> dict[str, Any]:
    """Read a job configuration and validate it against its declared version."""
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigurationError(f"configuration not found: {path}") from error
    except json.JSONDecodeError as error:
        raise ConfigurationError(f"invalid JSON in {path}: {error.msg}") from error

    if not isinstance(document, dict):
        raise ConfigurationError("<root>: configuration must be a JSON object")
    if document.get("schema_version") != SCHEMA_VERSION:
        raise ConfigurationError(
            f"schema_version: expected {SCHEMA_VERSION}, got {document.get('schema_version')!r}"
        )

    validate_document(document, JOB_SCHEMA_NAME)
    return document
