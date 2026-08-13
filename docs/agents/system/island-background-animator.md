# Island Background Animator

The Island Background Animator is an internal McRitchie Studio tool for preparing
deterministic media jobs. Its Python environment lives under
`tools/island-background-animator/`; it adds no gems, npm packages, Rails routes,
models, jobs, or production processes.

## Current boundary

The first milestone can:

- initialize an isolated job directory;
- identify PNG, JPEG, and WebP inputs from their bytes;
- validate version 1 job configuration;
- create static-master and human-approval placeholders; and
- check Pillow, jsonschema, FFmpeg, FFprobe, and future encoder capabilities.

It does **not** generate images, segment regions, create masks, animate pixels,
encode media, or approve a static master. Those stages remain closed until later
milestones add their deterministic implementation and review gates.

## Setup

From an isolated McRitchie Studio worktree:

```bash
brew bundle --file=tools/island-background-animator/Brewfile
cd tools/island-background-animator
uv sync --locked
```

The native dependencies are `uv` and FFmpeg. The nested `pyproject.toml` and
`uv.lock` own the Python dependencies; never add them to the flagship Gemfile or
root `package.json`.

## Commands

Run commands through the repository wrapper:

```bash
bin/island-background help
bin/island-background doctor
bin/island-background doctor --json
bin/island-background init tmp/island-background-jobs/sample \
  --job-id sample-island \
  --input /absolute/path/to/island.png
bin/island-background validate-config \
  tmp/island-background-jobs/sample/job.json
```

`init` refuses an existing target and stages the entire job before moving it into
place. It copies source bytes without re-encoding them, names the stored copy from
the detected content format, and records a SHA-256 digest. A `.png` extension is
never accepted as evidence that a file contains PNG data.

## Initial job structure

```text
<job>/
├── job.json
├── inputs/
│   ├── manifest.json
│   └── raw/
├── static/
│   ├── candidates/
│   └── approved/
├── state/
│   ├── job-state.json
│   └── approvals/static-master.json
├── work/
│   ├── renders/
│   └── exports/
├── reports/
└── deliverables/
```

The approval record begins in `pending` state. Nothing in this milestone can
populate `static/approved/master.png` or change that state.

## Verification

```bash
tools/island-background-animator/bin/check
```

The check installs the locked environment, runs Ruff lint and format checks,
runs strict mypy, and runs pytest. CI executes the same command, then runs the
dependency doctor against the runner's FFmpeg installation.

## Recovery

- A failed initializer removes its private staging directory and leaves no job.
- An existing target is never overwritten; choose a new directory or inspect the
  existing job.
- Generated jobs belong under the repository's ignored `tmp/` directory unless
  Mr. McRitchie selects another workspace.
- To roll back this milestone, revert its tool, wrapper, CI lane, and this document.
  No database or production cleanup is required.
