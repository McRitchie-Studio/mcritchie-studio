from __future__ import annotations

from pathlib import Path

from PIL import Image

from island_background_animator.cli import main


def test_help_command_prints_commands(capsys: object) -> None:
    assert main(["help"]) == 0
    output = capsys.readouterr().out  # type: ignore[attr-defined]
    assert "init" in output
    assert "doctor" in output
    assert "validate-config" in output


def test_init_and_validate_config_through_cli(tmp_path: Path, capsys: object) -> None:
    source = tmp_path / "source.png"
    Image.new("RGB", (8, 6), (30, 60, 90)).save(source, format="PNG")
    job_directory = tmp_path / "job"

    assert (
        main(
            [
                "init",
                str(job_directory),
                "--job-id",
                "cli-island",
                "--input",
                str(source),
            ]
        )
        == 0
    )
    assert main(["validate-config", str(job_directory / "job.json")]) == 0
    output = capsys.readouterr().out  # type: ignore[attr-defined]
    assert "static master pending approval" in output
    assert "valid" in output
