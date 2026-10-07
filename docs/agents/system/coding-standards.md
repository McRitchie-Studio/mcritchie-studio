# Coding Standards

## General
- Keep code barebones and hackable
- Optimize for speed of iteration
- Prefer simple, direct solutions over abstractions
- Pragmatic Rails — follow conventions loosely, bend them when simpler

## Slugs
- Every model gets a `slug` column for human-readable identification
- Use the `Sluggable` concern with `before_save :set_slug` callback
- Each model implements `name_slug` method
- Exception: Task uses `before_validation :generate_slug` with random hex (immutable)
- Exception: SkillAssignment has no slug (join table)
- Exception: Activity sets slug via `after_create` (needs id)
- A slug is written once, at create (studio-engine `Sluggable`); a later save never
  recomputes it. The one way to change it is `rename_slug!` (or `rename_slug` for a
  form), which rewrites every child column in one transaction and raises
  `Sluggable::SlugRefused` (a 422) when the slug is blank, badly formed or taken.
  The hub exposes it at `PATCH /people/:slug/slug` and `PATCH /api/v1/slugs/:kind/:slug`.
- A model whose slugs hold more than lowercase hyphenated words sets
  `self.slug_format` (User, and the models whose slugs carry a snake_case word).
- A column that holds a parent's slug with no association on the parent is
  declared there with `has_slug_children "table" => :column`;
  `test/models/slug_children_test.rb` fails when a census column is missing.

## Foreign Keys
- All foreign keys use slug strings, not integer IDs
- Associations use `foreign_key: :agent_slug, primary_key: :slug` pattern
- Example: `has_many :tasks, foreign_key: :agent_slug, primary_key: :slug`
- Every slug column the census (`bin/rails db:slug_census`) resolves carries a
  database foreign key to its parent's `slug`, `ON UPDATE CASCADE`, with
  `ON DELETE` RESTRICT, SET NULL or CASCADE chosen per column. The columns left
  without one are listed with their reasons in `SlugCensus::UNCONSTRAINED`, and
  `test/models/slug_foreign_keys_test.rb` holds both lists to the schema. A new
  slug column takes its key in the migration that adds it.
- A writer that passes whatever handle its caller holds (telemetry, task notes,
  the desk inventory) declares `clears_unknown_slug` (`ClearsUnknownSlug`), so a
  slug no parent holds is cleared, or kept in metadata, rather than refused.
- A refusal the database makes (`InvalidForeignKey`, `RecordNotUnique`) answers 422
  with the reason through `ConstraintViolationResponses`, on the web and the API.

## Error Handling
- `ErrorLog.capture!(exception, target:, parent:)` for structured error logging
- Use specific rescues: `RecordNotFound`, `RecordInvalid`, `RuntimeError`
- `RecordNotFound` is expected (no error log needed)
- `RecordInvalid` / `RuntimeError` = log via `ErrorLog.capture!`

## Guards, Refusals And Shared Constants
- **Run a printed remedy against the state that printed it.** A refusal whose fix,
  followed verbatim, leaves the refusal standing is a loop. When a remedy spans two
  things that each hash something different (a working tree and a ref), say which
  one each step moves.
- **An allow-list entry asserts its own precondition**, ideally that the defect it
  excuses is still present, so the entry fails when the defect is fixed. A reason
  written only as a comment is not measured.
- **Slice between markers only with checks.** Assert the start marker precedes the
  end marker and that the exact old text is present; a reversed pair yields an
  empty slice that inserts at index 0. A marker must be frozen text, never a value
  the file's own workflow rewrites (a count, a total).
- **One constant, one vocabulary.** A second caller that reads a shared map under
  a different meaning gets its own named map, not borrowed keys.
- **Record an event; do not infer it from two clocks.** Differencing a server
  timestamp against a local mtime fails at every skew tolerance. Add the write that
  makes the event observable.

## Ruby Traps
- **Read an opt-in ENV flag as `ENV["X"] == "1"`, never `.present?`**, whenever it
  gates spending, deleting or overwriting. `"0"`, `"no"` and `"false"` are all present,
  so every spelling of no means yes.
- **Set a wall-clock hour with `time.change(hour: N)`, never `beginning_of_day +
  N.hours`.** On a DST transition day the sum lands an hour off. Test the transition
  day itself, not a date in the other offset.
- **`sub`/`gsub` interpret backslashes in a replacement STRING:** `\'` is the text
  after the match, so splicing literal code can duplicate a file's tail. Use the block
  form, `s.sub(anchor) { replacement }`, for text carrying quotes or backslashes.

## Shell (zsh on macOS)
- **A pipe reports the last stage's status.** `cmd | tail; echo $?` prints `tail`'s
  0. Capture first: `out=$(cmd 2>&1); code=$?`, or redirect to a file. In zsh the
  per-stage array is `$pipestatus` (lowercase, 1-indexed); `${PIPESTATUS[0]}`
  expands empty. Reproduce any "script X exits 0 on failure" claim unpiped first.
- **A zero exit is the weakest evidence.** Confirm the outcome itself: query the
  row, read the log, curl the port.
- **A probe that proves an absence must be able to find a presence.** `timeout` does
  not exist here, so a command wrapped in it never runs and reads as "found nothing".
  Bound waits with the tool that waits (`run_in_background`, `bin/submit-wait`).
- **An empty read is not a value.** Test `[ -z "$x" ]` before comparing. A failing
  pipeline stage yields empty output that `>>` appends without error, and
  `out=$(grep -c x missing-file)` gives `""` while the substitution hides grep's
  exit 2. When output is the only copy of something you will delete, assert it is
  non-empty before deleting.
- **zsh does not word-split `$var`.** Use an array (`E=(A=1 B=2); env -i "${E[@]}" cmd`)
  or `${=var}`, and assert a sandbox variable inside the child.
- **zsh traps:** near a command that prints a secret, isolate stderr with a brace
  group, `{ cmd >/dev/null; } 2>&1`, or send each stream to its own file, and never
  rely on redirect order; `echo ===` fails as an `=word` expansion and aborts the
  compound command, so quote it.
- **Backticks and `$(...)` execute inside double quotes.** Prose with backticks in
  `-m`, `--body` or `--agent-context` runs as a command and vanishes from the text.
  Write long text with a quoted heredoc (`cat > f <<'EOF'`), pass the file, and read
  the stored value back.
- **`env -i HOME=` is not isolation.** An empty `HOME` falls back to the real one.
  Point it at a fresh `mktemp -d`, and include a command that fails there for the
  right reason. To show a tool CREATES state, probe from a shell that provably lacks it.
- **A child under another project's toolchain needs the original environment
  restored** (`Bundler.original_env`), not an enumerated deny-list of variables.
- **No shell state survives between agent turns.** Write the full path at every step
  of a multi-step procedure; a variable or `cd` from an earlier step is gone.
- **`heroku run … rails runner '<code>'` expands `$1`, `$4` in a remote shell.** Send
  the script on stdin: `heroku run -a <app> --no-tty -- rails runner - < script.rb`.
- **Never probe with a mutating command.** Read a script's source for the flags it
  parses before passing `--help` or a guessed flag, and test state with a read, not
  by re-running the command.

## API Controllers
- Inherit from `Api::V1::BaseController` (ActionController::API)
- Return JSON, no session overhead
- Rescue `RecordNotFound` → 404, `RecordInvalid` → 422

## Views
- Tailwind CSS via CDN, Alpine.js for interactivity
- Dark theme: navy background, mint accents, violet highlights
- Stage badges follow `Task::STAGE_LABELS` and the two-workflow stage model
  (`designed`, `building`, `submitted`, `reviewed`, `assembled`, `shipped`,
  `blocked`, `archived`).
