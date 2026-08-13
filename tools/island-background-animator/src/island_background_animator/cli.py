"""Command-line entry point."""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Sequence
from pathlib import Path

from island_background_animator.config import load_job_config
from island_background_animator.doctor import run_checks
from island_background_animator.errors import AnimatorError
from island_background_animator.job import initialize_job


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="island-background",
        description="Initialize and validate deterministic island background jobs.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("help", help="show this help message")

    doctor_parser = subparsers.add_parser(
        "doctor", help="check Python, image, and FFmpeg dependencies"
    )
    doctor_parser.add_argument("--json", action="store_true", dest="as_json")

    init_parser = subparsers.add_parser("init", help="initialize a new job directory")
    init_parser.add_argument("job_directory", type=Path)
    init_parser.add_argument("--job-id", required=True)
    init_parser.add_argument(
        "--input",
        action="append",
        required=True,
        type=Path,
        dest="inputs",
        help="source PNG, JPEG, or WebP; repeat for multiple photographs",
    )

    validate_parser = subparsers.add_parser(
        "validate-config", help="validate an existing job.json against its declared schema"
    )
    validate_parser.add_argument("configuration", type=Path)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        if args.command == "help":
            parser.print_help()
            return 0
        if args.command == "doctor":
            return _doctor(as_json=args.as_json)
        if args.command == "init":
            created = initialize_job(args.job_directory, args.job_id, args.inputs)
            print(f"initialized {created}")
            print(f"inputs {len(args.inputs)}")
            print("static master pending approval")
            return 0
        if args.command == "validate-config":
            load_job_config(args.configuration)
            print(f"valid {args.configuration}")
            return 0
    except AnimatorError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    parser.error(f"unknown command: {args.command}")
    return 2


def _doctor(*, as_json: bool) -> int:
    checks = run_checks()
    if as_json:
        report = {
            "ok": all(check.ok for check in checks),
            "checks": [check.to_dict() for check in checks],
        }
        print(json.dumps(report, indent=2))
    else:
        for check in checks:
            status = "PASS" if check.ok else "FAIL"
            print(f"{status} {check.name}: {check.detail}")
    return 0 if all(check.ok for check in checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
