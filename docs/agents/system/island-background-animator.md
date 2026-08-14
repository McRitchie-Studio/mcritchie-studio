# Island Background Animator

The Island Background Animator is an internal McRitchie Studio tool for preparing
deterministic media jobs. Its Python environment lives under
`tools/island-background-animator/`; it adds no gems, npm packages, Rails routes,
models, jobs, or production processes.

## Current boundary

The current milestones can:

- initialize an isolated job directory;
- identify PNG, JPEG, and WebP inputs from their bytes;
- validate version 1 job configuration;
- register fully decoded PNG illustration candidates without re-encoding them;
- render a deterministic labeled contact sheet;
- freeze one checksum-confirmed candidate after human approval;
- create versioned static-master and human-approval state; and
- check Pillow, jsonschema, FFmpeg, FFprobe, and future encoder capabilities.

Image generation remains Codex-driven and nondeterministic. Generated output is
not trusted until `add-candidate` identifies PNG content from its bytes, fully
decodes every pixel, copies the source bytes unchanged, and records their SHA-256
digest. The tool does **not** segment regions, create masks, animate pixels, or
encode media. Those stages remain closed until later milestones add their
deterministic implementation and review gates.

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
bin/island-background add-candidate \
  tmp/island-background-jobs/sample \
  --candidate /absolute/path/to/generated-candidate.png \
  --label "Editorial Gouache"
bin/island-background contact-sheet \
  tmp/island-background-jobs/sample
```

`init` refuses an existing target and stages the entire job before moving it into
place. It copies source bytes without re-encoding them, names the stored copy from
the detected content format, and records a SHA-256 digest. A `.png` extension is
never accepted as evidence that a file contains PNG data.

`add-candidate` accepts only content-detected, fully decoded PNG data. All
candidates in one job must share dimensions. It stores versioned metadata at
`state/static-candidates.json`; duplicate bytes and post-registration pixel
changes are rejected. `contact-sheet` verifies every registered checksum before
rendering `reports/static-master-contact-sheet.png`. Contact-sheet pixels are
derived review material and never replace candidate pixels.

## Static-master approval gate

Stop after generating the contact sheet and show it to Mr. McRitchie. Never infer
approval from a prompt, filename, preferred style, or prior discussion. After he
explicitly selects a candidate, read its SHA-256 from
`state/static-candidates.json` and bind that exact selection:

```bash
bin/island-background approve-static \
  tmp/island-background-jobs/sample \
  --candidate-id candidate-001 \
  --approved-by "Mr. McRitchie" \
  --confirm-sha256 <64-character-candidate-sha256>
```

Approval creates `static/approved/master.png` as a byte-for-byte copy of the
selected candidate. It records approval schema version 2, candidate ID, candidate
path, SHA-256, approver, and UTC time. A changed candidate, stale checksum, second
approval, or attempt to add candidates after approval fails closed. Animation
must later read the approved checksum and must never modify this file.

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
│   ├── static-candidates.json
│   └── approvals/static-master.json
├── work/
│   ├── renders/
│   └── exports/
├── reports/
└── deliverables/
```

The approval record begins in `pending` state. Only the explicit, checksum-bound
`approve-static` command can populate `static/approved/master.png` and advance it
to `approved`.

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
- Registered candidates remain immutable evidence; create a new job if an approved
  direction must be replaced.
- Delete and regenerate the contact sheet freely; it is derived from verified
  candidates.
- Generated jobs belong under the repository's ignored `tmp/` directory unless
  Mr. McRitchie selects another workspace.
- To roll back this milestone, revert its tool, wrapper, CI lane, and this document.
  No database or production cleanup is required.
