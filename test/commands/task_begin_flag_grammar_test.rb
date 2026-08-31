require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "fileutils"
require "json"
require "ripper"

# [unit] `bin/task begin`'s flags must LAND or REFUSE — never be dropped in silence.
#
# THE DEFECT THIS EXISTS TO CATCH, measured 2026-08-29. `begin` has two forms:
# a CREATE (`--title …`, which forwards create flags) and a RESUME
# (`begin <slug>`, which accepted only --steal). The documented fast lane says to
# pass `--agent <soul>`, and on the RESUME form that flag was accepted, ignored,
# and never mentioned again. Four tasks resumed that way came out with
# agent_slug nil AND devops.built_by nil, while the same flag on a create
# stamped both.
#
# WHY A DROPPED FLAG IS WORSE THAN A FAILED ONE. `devops.built_by` is the ONLY
# input `bin/reviewer-select` can use to keep a soul off their own PR. Blank, it
# REFUSES to pick and a human hand-picks instead — and a hand-picked light once
# turned out to be the PR's own author. `begin` printed the worktree and reported
# success either way, so the builder had no signal; the failure surfaced a day
# later, in review, wearing a different costume.
#
# EVERY ASSERTION HERE RUNS OFF-NETWORK by construction: both refusals happen in
# argument parsing, before `begin` resolves a slug against the board. TASK_API_BASE
# is pinned at an unroutable address so a REGRESSION that defers either check
# until after the lookup fails loudly here instead of silently reaching prod.
class TaskBeginFlagGrammarTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  # Loopback on a port nothing listens on: the connection is REFUSED immediately.
  # An unroutable address (TEST-NET-1) would blackhole and hang the suite instead —
  # measured. The point is the same either way: a check that wrongly moved below
  # the API call cannot accidentally pass by reaching a real board.
  OFFLINE = { "TASK_API_BASE" => "http://127.0.0.1:1", "TASK_SKIP_MARKER" => "1" }.freeze

  # EVERY TOKEN TYPE THAT IS PROSE, not code. `=begin`/`=end` blocks do NOT lex as
  # :on_comment — they arrive as :on_embdoc_beg / :on_embdoc / :on_embdoc_end, one
  # token per line at col 0 — so a stripper that filtered on :on_comment alone let
  # a block comment through WHOLE. bin/task carries none today, which is exactly
  # the condition under which the hole goes unnoticed: it re-opens M4 the first
  # time someone explains a reader inside `=begin`.
  COMMENT_TOKENS = %i[on_comment on_embdoc_beg on_embdoc on_embdoc_end].freeze

  # The local M6 injects into the begin block, named so the test can find its own
  # probe line again without matching anything bin/task legitimately contains.
  MULTIBYTE_PROBE = "multibyte_probe"

  # The canonical sources. The projects-root CLAUDE.md / AGENTS.md are GENERATED
  # from these two, so a correction lands here or it does not land at all.
  ENTRY_DOCS = %w[docs/agents/claude.md docs/agents/index.md].freeze
  FLAG_COUNT_WORDS = { 5 => "FIVE", 6 => "SIX", 7 => "SEVEN", 8 => "EIGHT" }.freeze

  test "a create flag on the resume form is refused, not dropped" do
    _out, err, status = run_task("begin", "some-slug", "--shape", "backend")

    refute status.success?, "a flag begin cannot honour must fail the command"
    assert_includes err, "unknown flag", "the refusal must name the flag as unknown here"
    assert_includes err, "--shape"
    assert_includes err, "bin/task update", "and must name where the flag DOES belong"
  end

  # ── DOOR 2: THE TASK ALREADY EXISTS ─────────────────────────────────────────
  #
  # THE DEFECT, and it is the same class as the one above rather than a new one.
  # The guard keyed on a BLANK --title. But a blank title is only ONE WAY to reach
  # a resume — what actually makes a create flag inert is THE TASK ALREADY
  # EXISTING. So this walked straight past the check and dropped --shape in
  # silence:
  #
  #     bin/task begin --title "Some Existing Title" --shape backend
  #
  # and it did so on the DOCUMENTED re-run path, because `begin` is advertised as
  # resumable and re-running it is normal — which makes this the door a real
  # builder is more likely to walk through than the blank-title one.
  #
  # THIS DOOR NEEDS THE BOARD, unavoidably: nothing can know the task exists until
  # the lookup says so. That is precisely why the blank-title door STAYS above the
  # network in the test above — a grammar fact must not depend on a reachable
  # board — and why these two checks are not collapsed into one.
  test "a create flag is refused once the task turns out to already exist" do
    err, status = begin_against_existing_task("--title", "Probe Task", "--shape", "backend")

    refute status.success?, "a flag begin cannot honour must fail the command, not be dropped"
    assert_includes err, "unknown flag", "the refusal must name the flag as unknown"
    assert_includes err, "--shape"
    assert_includes err, "already exists",
                     "the refusal must name WHY the flag is inert — the task exists, so this " \
                     "is a resume — not merely that a flag was unrecognised"
    assert_includes err, "bin/task update probe-task",
                     "and must name the remedy against THIS task, ready to paste"
    refute_includes err, "begin 2/5 worktree",
                    "the refusal must land BEFORE begin allocates a desk — a run that is " \
                    "going to be refused must not leave a worktree behind first"
  end

  # THE REFUSAL MUST LEAVE A WAY FORWARD, and this is the cost of the fix above
  # rather than a free win. Re-running the whole create line IS a real habit: the
  # fast lane prints that line and `begin` is advertised as resumable, so this
  # change turns a silent drop into a hard stop for anyone who re-runs it verbatim.
  # That trade is only worth making if the stop is one paste from working — a
  # refusal that just says "no" would swap a quiet wrong answer for a dead end.
  test "the already-exists refusal names how to resume" do
    err, _status = begin_against_existing_task("--title", "Probe Task", "--shape", "backend")

    assert_includes err, "bin/task begin probe-task",
                     "the refusal must name the resume command, not only the update remedy — " \
                     "re-running the create line is the habit this newly refuses"
  end

  # The flag that must NOT be refused here. --title is how a re-run names the task
  # whose slug `begin` just resolved; refusing it would break every documented
  # re-run and turn a silent drop into a hard stop, which is not the trade.
  test "the title itself survives the already-exists refusal" do
    err, _status = begin_against_existing_task("--title", "Probe Task")

    refute_includes err, "unknown flag",
                    "--title named the task begin resumed; it is not an attempt to re-create it"
    # It got PAST the guard and went on resuming. Asserting the whole run exits 0
    # would assert something else entirely — the later steps want a real worktree
    # on disk, which this test deliberately does not build.
    assert_includes err, "already exists [designed]; resuming",
                    "begin must carry on into the resume rather than stop at the flag"
    assert_includes err, "begin 2/5 worktree", "and reach the steps the refusal would have cut off"
  end

  # THE FLAG THE FAST LANE ACTUALLY DOCUMENTS. If this ever starts refusing, the
  # published workflow breaks for every resumed task — so the grammar is pinned
  # from both sides, not just the refusing one.
  test "the builder flag is accepted by the resume form" do
    _out, err, _status = run_task("begin", "no-such-task-xyz", "--agent", "alex")

    refute_includes err, "unknown flag",
                     "--agent is forwarded to the claim as --actor; refusing it would break " \
                     "the documented fast lane for every resumed task"
  end

  # SHAPE, NOT MEMBERSHIP. The CLI holds no Rails constants and cannot see the
  # Agent table — and a missing Agent row is NOT what breaks the stamp (every soul
  # is seeded). What breaks it is a value outside SOUL_SLUG, which
  # Task#builder_to_stamp tests before it writes built_by. `--agent Steffon` and
  # `--agent turf_monster` are the realistic spellings that silently no-op.
  test "an agent value that could never stamp is refused at the door" do
    ["Steffon", "turf_monster", "carl2"].each do |bad|
      _out, err, status = run_task("create", "--title", "Probe Three Words", "--agent", bad)

      refute status.success?, "#{bad.inspect} cannot match SOUL_SLUG, so it must not be accepted"
      assert_includes err, "must be a soul slug", "the refusal must say what shape is required"
      assert_includes err, "built_by", "and why it matters — the stamp is the whole point"
    end
  end

  test "a soul-shaped agent value passes validation" do
    _out, err, _status = run_task("create", "--title", "Probe Three Words", "--agent", "turf-monster")

    refute_includes err, "must be a soul slug",
                     "a hyphenated soul is the shape Task::SOUL_SLUG accepts"
  end

  # GUARD THE MIRROR. bin/task carries its own copy of SOUL_SLUG because it holds
  # no Rails constants. Two copies of one contract drift, and the drift is silent:
  # the CLI would accept a value the model then refuses to stamp, which is exactly
  # the failure this whole task exists to remove.
  test "the CLI soul pattern still matches the model it mirrors" do
    cli = File.read(BIN)[/^SOUL_SLUG = (.+)$/, 1]

    assert_equal Task::SOUL_SLUG.inspect, cli.strip,
                 "bin/task's SOUL_SLUG must stay identical to Task::SOUL_SLUG"
  end

  # ── THE FORWARD ITSELF (acceptance criterion 2) ─────────────────────────────
  #
  # The grammar tests above prove --agent is ACCEPTED. This proves it is USED.
  # Without the forward, begin's child `move` defaults its actor to the session
  # UUID — not a soul — so Task#builder_to_stamp rule 1 cannot fire; and on a
  # resume agent_slug is nil, so rule 4 cannot either. That is the whole of why
  # begin had no path to built_by, and an accepted-but-unused flag would satisfy
  # every assertion above while fixing nothing.
  #
  # The child move is intercepted through TASK_BEGIN_MOVE_BIN and its argv
  # recorded, so this observes the ACTUAL command begin builds rather than the
  # source line that builds it.
  test "the builder is forwarded to the claim as --actor" do
    argv = captured_move_argv("--agent", "carl")

    assert_includes argv, "--actor", "begin must name the builder on the child move"
    assert_equal "carl", argv[argv.index("--actor") + 1]
    assert_includes argv, "building", "and it is still the build claim it forwards onto"
  end

  # No builder, no actor — begin must not invent one. A fabricated actor would be
  # worse than a blank: reviewer-select REFUSES a blank builder (fail-closed) but
  # would happily exclude a wrong soul, silently, and pick the PR's own author.
  test "no builder means no actor is invented" do
    refute_includes captured_move_argv, "--actor",
                    "a blank built_by fails review CLOSED; a WRONG one fails it open"
  end


  # ── EVERY ADVERTISED FLAG MUST BE WIRED ─────────────────────────────────────
  #
  # FOUND IN REVIEW of this very PR, and it is the same defect the PR removes.
  # An earlier draft listed --dev-size as accepted on the resume form and then
  # dropped it on the already-`building` RENEWAL branch, where `dev_size` never
  # appeared at all. Accepting a flag and ignoring it is exactly the silent drop
  # this task exists to end — advertising it is arguably worse than refusing it,
  # because the caller has been told it works.
  #
  # The same review found --repo had regressed the OTHER way: it is genuinely read
  # on the shared path (as lists["repositories"], to pick which app's desk is
  # allocated), and the guard turned a working flag into a refused one.
  # NOTE WHICH BRANCH THIS DRIVES, because the first version of this test drove the
  # wrong one and PASSED WITH THE FIX REVERTED. `begin` claims two ways: a task in
  # `designed` gets a child `move` (argv, already correct), and a task already in
  # `building` gets an inline PATCH — and the PATCH was the branch that dropped
  # --dev-size. A test against the child-move path cannot express the defect at all.
  test "the resume form honours the size it advertises on the renewal branch" do
    body = captured_renewal_body("--agent", "carl", "--dev-size", "large")

    assert_equal "large", body["dev_size"],
                 "a resume of an ALREADY-building task must send the size it accepted — " \
                 "dev_size rides beside devops as a top-level column, the way `move` sends it"
  end

  # THE HEADLINE LINE, and nothing pinned it until this test. FOUND IN REVIEW
  # (round 2): deleting the renewal branch's `event.actor` forward left all 31
  # tests across the three relevant files GREEN — the SAME shape round 1 was
  # blocked for (a renewal-branch behaviour whose only test drove the child-move
  # branch), on the sibling line of the same if/else. Without the forward, a
  # resume of an ALREADY-building task renews the claim with no actor:
  # Task#builder_to_stamp rule 1 cannot fire, and a resume sets no agent_slug so
  # rule 4 cannot either — built_by stays blank, which is the whole defect this
  # task exists to remove.
  test "the renewal branch names the builder as the event actor" do
    body = captured_renewal_body("--agent", "carl")

    assert_equal "carl", body.dig("event", "actor"),
                 "a resume of an already-building task must name the builder on the " \
                 "claim renewal — it is the ONLY path to built_by on that branch"
  end

  test "the child-move branch forwards the size too" do
    argv = captured_move_argv("--agent", "carl", "--dev-size", "large")

    assert_includes argv, "--dev-size"
    assert_equal "large", argv[argv.index("--dev-size") + 1]
  end

  test "the repo flag is accepted because the resume path reads it" do
    _out, err, _status = run_task("begin", "no-such-task-xyz", "--repo", "turf-monster")

    refute_includes err, "unknown flag",
                    "--repo is read on the shared path to choose which app's desk is " \
                    "allocated; refusing it regressed a flag that worked"
  end

  # ── THE GUARD ON THE GUARD ──────────────────────────────────────────────────
  #
  # Anything the resume form advertises has to be READ somewhere in the `begin`
  # block, or the whitelist is lying to its caller. This is a source-level check
  # on purpose: it is the one assertion that fails when a future editor adds a
  # flag to the list and forgets to wire it.
  #
  # IT MUST READ CODE, NOT PROSE — and for one release it did not. FOUND IN
  # REVIEW of the PR that introduced it, and PROVED BY MUTATION twice over:
  #
  #   M4  Unwire --repo in the CODE, leave the comment that explains it. The
  #       comment contained the literal `lists["repositories"]`, so the guard's
  #       OWN RATIONALE satisfied the guard. Suite stayed GREEN with the flag
  #       broken.
  #   M5  Consume --steal but never use it. The reader pattern was /steal/, and
  #       both the whitelist line `%w[... --steal]` and the usage string contain
  #       "--steal" — so the ADVERTISEMENT satisfied the assertion that the
  #       advertisement is honest. GREEN again.
  #
  # Two of five entries could not fail for the reason they claimed to test. Three
  # changes kill both mutations, and all three are load-bearing:
  #   1. COMMENTS ARE STRIPPED before matching. Ripper's lexer decides what is a
  #      comment, so a `#` inside a string literal and a `#{}` interpolation are
  #      left standing — a regex over /#.*$/ gets both wrong.
  #   2. THE WHITELIST MOVED OUT of the begin block (bin/task's
  #      BEGIN_RESUME_FLAGS), so it can no longer stand in as its own proof.
  #   3. EACH READER NAMES A USE OF THE PARSED VALUE, never the flag's spelling.
  #      --steal's reader is `steal: steal` — the forward into the claim gate —
  #      not the string "--steal" that still appears in the usage text.
  #
  # Both mutations are frozen as tests below, and each one first ASSERTS THE
  # HAZARD IS PRESENT in the mutated source; otherwise it would pass without
  # exercising the fix at all.
  READERS = { "--slug" => /top\["slug"\]/,
              "--repo" => /lists\["repositories"\]/,
              "--agent" => /top\["agent"\]/,
              "--dev-size" => /top\["dev_size"\]/,
              "--steal" => /steal: steal\b/ }.freeze

  test "every flag the resume form advertises is read by begin" do
    assert_empty unwired_flags(File.read(BIN)),
                 "these flags are advertised by the resume form but nothing in `begin` reads " \
                 "them — an accepted-and-ignored flag is the silent drop this guard removes"
  end

  # THE TABLE MUST MATCH THE WHITELIST EXACTLY, in both directions. The reader
  # table is hand-written by the same author as the code it checks, which makes it
  # self-confirming in principle: a stale entry keeps asserting against a flag that
  # no longer exists, and a missing one lets a newly advertised flag through
  # unchecked. Pinning the two sets equal is the cheapest defence available to a
  # source-level guard, and it is what makes the loop above exhaustive.
  test "the reader table covers exactly the advertised whitelist" do
    assert_equal advertised_flags(File.read(BIN)).sort, READERS.keys.sort,
                 "bin/task's BEGIN_RESUME_FLAGS and this test's READERS table have drifted; " \
                 "every advertised flag needs a reader pattern and vice versa"
  end

  # [integration] M4, FROZEN. The mutation that stayed green: --repo unwired in
  # code, its explanatory comment left standing.
  test "a comment naming the reader cannot satisfy the wiring guard" do
    source = unwire_repo_in_code(File.read(BIN))
    block = source[/^when "begin"$.*?^when "/m]

    # PROVE THE HAZARD IS PRESENT. Without a surviving comment that names the
    # reader, this test would pass on the strength of the deletion alone and say
    # nothing whatever about comment stripping.
    assert_match(/lists\["repositories"\]/, block,
                 "the mutation must leave a COMMENT naming the reader inside the block, " \
                 "or it does not exercise the comment stripper at all")

    assert_equal ["--repo"], unwired_flags(source),
                 "--repo is unwired in code and only a comment still names its reader; " \
                 "the guard must report it as unwired"
  end

  # [integration] M5, FROZEN. --steal consumed so it is not refused as unknown,
  # then never used — while the usage string keeps advertising it.
  test "a flag the block only mentions cannot satisfy the wiring guard" do
    source = unwire_steal_in_code(File.read(BIN))
    block = source[/^when "begin"$.*?^when "/m]

    # PROVE THE HAZARD IS PRESENT: the naive /steal/ this guard used to carry
    # would still match the mutated block, so the tightened reader is what is
    # doing the work here.
    assert_match(/steal/, block,
                 "the mutated block must still MENTION steal, or this test says nothing " \
                 "about the tightened reader pattern")

    assert_equal ["--steal"], unwired_flags(source),
                 "--steal is consumed and never used; only its spelling survives, and a " \
                 "spelling is not a reader"
  end

  # [integration] The stripper must not overshoot. A guard that blanked too much
  # would report every flag unwired and read as a very thorough test while
  # asserting nothing — the failure mode where a scan passes having read nothing.
  test "stripping comments leaves the code that does the reading" do
    stripped = code_only(File.read(BIN))

    refute_includes stripped, "the mutation that guard now has to fail",
                    "comment text must not survive the strip"
    assert_includes stripped, %q(lists["repositories"].first if lists.key?("repositories")),
                    "the real reader must survive the strip"
    assert_includes stripped, %q(`bin/task update #{update_target} #{arg} ...`),
                    "an interpolation is a `#` the stripper must NOT treat as a comment"
    assert_includes stripped, %q("a resumed task is never re-shaped by begin: pass --title to CREATE one"),
                    "a string literal is not a comment and must survive"
  end

  # [integration] M6, FROZEN — M4 WEARING A MULTIBYTE COSTUME. Ripper reports the
  # comment's column in BYTES; String#[] slices CHARACTERS. So a trailing comment
  # sitting after an em dash or an emoji survives the strip by (bytes - chars)
  # characters, and a long enough prefix leaks the READER NAME itself. That is M4
  # exactly — reachable again, through a line nobody would look at twice.
  #
  # NOT REACHABLE IN TODAY'S bin/task: measured 0 of 1104 comment tokens affected,
  # because every multibyte character in the file happens to sit AFTER its `#`.
  # That is a property of the current text, not of the guard, and it holds only
  # until the next person writes a trailing comment after an emoji.
  test "a multibyte comment naming the reader cannot satisfy the wiring guard" do
    source = inject_multibyte_reader_comment(unwire_repo_in_code(File.read(BIN)))
    block = source[/^when "begin"$.*?^when "/m]

    hazard = block.lines.find { |line| line.include?(MULTIBYTE_PROBE) }
    refute_nil hazard, "the mutation must inject its probe INSIDE the begin block"

    # PROVE THE HAZARD IS PRESENT, and prove it against the OLD slice rather than
    # by counting characters here: the probe only exercises this fix if the
    # character-based slice it replaces would have leaked the reader through.
    assert_match(/lists\["repositories"\]/, char_sliced(hazard),
                 "the probe must be a line the OLD character-slice leaked the reader through, " \
                 "or M6 is only M4 again and says nothing whatever about byte columns")
    assert_operator hazard.bytesize, :>, hazard.size,
                    "the probe line must carry multibyte characters BEFORE its comment, or byte " \
                    "and character columns agree and there is nothing here to catch"

    assert_equal ["--repo"], unwired_flags(source),
                 "--repo is unwired in code and only a MULTIBYTE-SHIFTED comment still names its " \
                 "reader; a byte-correct strip must still report it unwired"
  end

  # [unit] THE SLICE ITSELF, at the smallest scale that can tell a byte column
  # from a character one. Exact equality rather than a substring check on purpose:
  # the leak is (bytes - chars) characters wide, so a fixture tuned to leak one
  # particular word would still pass while leaking three characters of another.
  test "the strip cuts at the comment even when multibyte characters precede it" do
    source = <<~'RUBY'
      plain = lists["repositories"] # ascii comment, no column shift
      shifted = warn!("🗿💧 begin — resuming") # lists["repositories"] named in prose
    RUBY

    assert_operator source.bytesize, :>, source.size,
                    "the fixture must be multibyte or it cannot distinguish the two columns"

    assert_equal <<~'RUBY', code_only(source)
      plain = lists["repositories"]
      shifted = warn!("🗿💧 begin — resuming")
    RUBY
  end

  # [unit] A BLOCK COMMENT IS PROSE TOO. `=begin`/`=end` lex as :on_embdoc_beg /
  # :on_embdoc / :on_embdoc_end, NEVER as :on_comment, so a stripper filtering on
  # :on_comment alone left one standing whole. bin/task uses no block comments
  # today, which is precisely why adopting one would reintroduce M4 unnoticed.
  test "a block comment cannot survive the strip either" do
    source = <<~'RUBY'
      plain = lists["repositories"]
      =begin
      this prose names lists["repositories"] and must not survive the strip
      =end
      tail = 1
    RUBY

    stripped = code_only(source)

    refute_includes stripped, "must not survive the strip",
                    "=begin/=end prose survived: a block comment can still satisfy the guard"
    assert_includes stripped, %q(plain = lists["repositories"]),
                    "the real reader must survive — a strip that blanks code asserts nothing"
    assert_equal source.lines.size, stripped.lines.size,
                 "the strip must preserve line structure, or the begin-block regex loses its bounds"
  end

  # ── THE DOCS MUST NAME WHAT THE CODE HONOURS ────────────────────────────────
  #
  # PROSE HAS NO OTHER WAY TO FAIL. Both entry docs said a resume "HONOURS FIVE
  # FLAGS" and listed BEGIN_RESUME_FLAGS — but door 2 ALSO whitelists `--title`
  # (bin/task's `also_valid`), so the live refusal prints SIX. The gap taught the
  # opposite of the behaviour: a builder read that re-running the create line is
  # refused, while the code resumes it cleanly and refuses only the OTHER create
  # flags riding along on it.
  #
  # THE COUNT IS DERIVED FROM THE SOURCE and never restated here, so a sixth or
  # seventh flag added to either whitelist reddens this until the sentence catches up.
  test "the entry docs name every flag a resume actually honours" do
    source = File.read(BIN)
    honoured = advertised_flags(source) + door_two_extra_flags(source)
    word = FLAG_COUNT_WORDS.fetch(honoured.size) { flunk("no word for #{honoured.size} flags") }

    ENTRY_DOCS.each do |rel|
      body = Rails.root.join(rel).read

      assert_includes body, "A RESUME HONOURS #{word} FLAGS",
                      "#{rel} states a flag count bin/task does not honour (#{honoured.size}: " \
                      "#{honoured.join(", ")})"
      honoured.each do |flag|
        assert_includes body, "`#{flag}`",
                        "#{rel} omits #{flag} from the flags it says a resume honours"
      end
    end
  end

  private

  # ── THE WIRING CHECK, AS A FUNCTION OF SOURCE ───────────────────────────────
  # Taking SOURCE rather than reading BIN directly is what lets the mutation
  # tests above run the real check against a deliberately-broken copy of the real
  # file, instead of against a hand-written fake that could only ever confirm
  # what its author already believed.
  def unwired_flags(source)
    body = executable_begin_block(source)
    advertised_flags(source).reject { |flag| body.match?(READERS.fetch(flag)) }
  end

  # Door 2's extra whitelist entry, read from the source rather than restated.
  # `--title` is legal on the already-exists path because it is how a re-run NAMES
  # the task whose slug `begin` just resolved — and it is exactly the flag the
  # entry docs left out of their count.
  def door_two_extra_flags(source)
    source[/also_valid: %w\[([^\]]+)\]/, 1]&.split ||
      flunk("could not read door 2's also_valid whitelist out of bin/task")
  end

  # THE OLD, CHARACTER-BASED SLICE — kept only so M6 can prove its hazard. A probe
  # line is only worth asserting against if the implementation this replaces would
  # actually have leaked the reader through it.
  def char_sliced(line)
    pos, = Ripper.lex(line).find { |_pos, type, _tok, _state| type == :on_comment }
    line[0, pos[1]]
  end

  # M6's mutation: a line of CODE carrying multibyte characters, then a trailing
  # comment naming --repo's reader. The emoji and the em dash are the whole point
  # — each one pushes Ripper's byte column further past the character index of the
  # `#`, and that gap is how much comment a character-slice keeps.
  def inject_multibyte_reader_comment(source)
    probe = %(  #{MULTIBYTE_PROBE} = "🗿💧🗿💧🗿💧🗿💧 — em dash" ) +
            %(# lists["repositories"] named only in prose\n)
    raise "M6 anchor missing from bin/task" unless source.match?(/^when "begin"\n/)

    source.sub(/^when "begin"\n/) { |m| m + probe }
  end

  def advertised_flags(source)
    source[/^BEGIN_RESUME_FLAGS = %w\[([^\]]+)\]/, 1]&.split ||
      flunk("could not read BEGIN_RESUME_FLAGS out of bin/task")
  end

  def executable_begin_block(source)
    code_only(source)[/^when "begin"$.*?^when "/m] || flunk("could not isolate the begin block")
  end

  # Blank every COMMENT, preserving line structure so the block regex still
  # bounds on `when "..."` lines. Ripper's LEXER classifies the tokens, so a `#`
  # inside a string literal and a `#{}` interpolation are left alone; a regex over
  # /#.*$/ mangles both, and bin/task contains examples of each.
  #
  # SLICE BY BYTE, NOT BY CHARACTER. Ripper reports `col` as a BYTE offset while
  # String#[] counts CHARACTERS, so on any line where a multibyte character
  # precedes the `#`, the slice keeps (bytes - chars) extra characters OF COMMENT.
  # MEASURED: a `#` at character 14 is reported at col 22, leaking eight characters
  # of comment text past the strip.
  #
  # The direction is ONE-WAY, and that is what makes it dangerous rather than
  # merely wrong: a byte offset is never SMALLER than the character offset it
  # corresponds to, so this can only ever UNDER-strip. It never eats code — it
  # leaks comment. Leaked comment text is precisely what satisfied M4, so this
  # quietly re-opens the hole the strip exists to close, on the first trailing
  # comment written after an em dash or an emoji.
  def code_only(source)
    lines = source.lines
    Ripper.lex(source).each do |(lineno, col), type, _tok, _state|
      next unless COMMENT_TOKENS.include?(type)

      lines[lineno - 1] = "#{lines[lineno - 1].byteslice(0, col).rstrip}\n"
    end
    lines.join
  end

  # Run `begin --title …` against a board that answers with an ALREADY-EXISTING
  # task, and return [stderr, status]. The worktree, preflight and move children
  # are stubbed, so a run that gets PAST the refusal still does no real work —
  # which is what lets the second test assert a clean resume succeeds.
  def begin_against_existing_task(*args)
    Dir.mktmpdir do |dir|
      stub(dir, "move-stub", "exit 0")
      stub(dir, "worktree-stub", "echo #{dir}")
      stub(dir, "preflight-stub", "exit 0")
      err = status = nil

      with_board_sink(dir) do |base|
        _out, err, status = Open3.capture3(
          { "TASK_API_BASE" => base, "AGENT_API_SECRET" => "not-a-real-secret",
            "TASK_SKIP_MARKER" => "1", "TASK_BEGIN_PROJECTS_DIR" => dir,
            "TASK_BEGIN_MOVE_BIN" => File.join(dir, "move-stub"),
            "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
            "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub") },
          BIN, "begin", *args
        )
      end

      [err, status]
    end
  end

  # Mutate the `begin` block ONLY, then splice it back. Scoping matters: `steal:
  # steal` also appears in the `move` block, and unwiring THAT one would prove
  # nothing about `begin`. The block form of sub is deliberate — a replacement
  # STRING would reinterpret the backslash line-continuations the block contains.
  def within_begin_block(source)
    block = source[/^when "begin"$.*?^when "/m] || flunk("could not isolate the begin block")
    source.sub(block) { yield(block) }
  end

  # Delete each anchor from the block, proving first that it is there exactly
  # once — a mutation that silently applied to nothing would leave the guard
  # looking at unbroken code and report a pass that means nothing.
  def delete_from_begin_block(source, anchors, mutation)
    within_begin_block(source) do |block|
      anchors.inject(block) do |acc, anchor|
        assert_equal 1, acc.scan(anchor).size,
                     "the #{mutation} mutation is anchored on #{anchor.strip.inspect}, which the " \
                     "begin block no longer contains exactly once — re-anchor it on the code that " \
                     "reads this flag today, do not delete the test"
        acc.sub(anchor) { "" }
      end
    end
  end

  # M4: delete --repo's reader from the CODE, leave its comments standing.
  def unwire_repo_in_code(source)
    delete_from_begin_block(source, ['(lists["repositories"].first if lists.key?("repositories")), '], "M4")
  end

  # M5: leave --steal consumed (so it is not refused as an unknown flag) and
  # remove every USE of the parsed value.
  def unwire_steal_in_code(source)
    delete_from_begin_block(source, ["steal: steal, ", %(    move_cmd << "--steal" if steal\n)], "M5")
  end


  # Run `begin` against a board sink this test owns, with the worktree, preflight
  # and move children replaced by recording stubs, and return the argv the child
  # `move` was called with.
  def captured_move_argv(*extra)
    Dir.mktmpdir do |dir|
      move_log = File.join(dir, "move-argv")
      stub(dir, "move-stub", "printf '%s\n' \"$@\" > #{move_log}")
      stub(dir, "worktree-stub", "echo #{dir}")
      stub(dir, "preflight-stub", "exit 0")

      with_board_sink(dir) do |base|
        Open3.capture3(
          { "TASK_API_BASE" => base, "AGENT_API_SECRET" => "not-a-real-secret",
            "TASK_SKIP_MARKER" => "1", "TASK_BEGIN_PROJECTS_DIR" => dir,
            "TASK_BEGIN_MOVE_BIN" => File.join(dir, "move-stub"),
            "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
            "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub") },
          BIN, "begin", "probe-task", *extra
        )
      end

      File.exist?(move_log) ? File.read(move_log).split("\n") : []
    end
  end

  # Drive the RENEWAL branch: the task is already `building`, and a session identity
  # is present so `begin` writes the claim rather than leaving it alone. Returns the
  # decoded body of the LAST PATCH it sent.
  def captured_renewal_body(*extra)
    Dir.mktmpdir do |dir|
      stub(dir, "worktree-stub", "echo #{dir}")
      stub(dir, "preflight-stub", "exit 0")
      writes = []

      with_board_sink(dir, stage: "building", writes: writes) do |base|
        Open3.capture3(
          { "TASK_API_BASE" => base, "AGENT_API_SECRET" => "not-a-real-secret",
            "TASK_SKIP_MARKER" => "1", "TASK_BEGIN_PROJECTS_DIR" => dir,
            "CLAUDE_CODE_SESSION_ID" => "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b",
            "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
            "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub") },
          BIN, "begin", "probe-task", "--steal", *extra
        )
      end

      parsed = writes.filter_map { |w| JSON.parse(w) rescue nil }
      flunk "the renewal branch sent no PATCH — the test never reached the code it targets" if parsed.empty?
      parsed.last
    end
  end

  # A board answering the two calls `begin` makes before it claims: the bearer
  # exchange (/auth), then the task read. The task comes back in `designed`, so
  # begin takes the child-move branch rather than the already-building renewal
  # branch. ROUTING BY PATH MATTERS — a sink that returns one body for every
  # request answers /auth with a task and bin/task dies on a missing "token".
  def with_board_sink(_dir, stage: "designed", writes: nil)
    server = TCPServer.new("127.0.0.1", 0)
    task = { data: { slug: "probe-task", stage: stage, title: "Probe Task",
                     metadata: { devops: { worktree_slug: "probe-task",
                                           repositories: ["mcritchie-studio"] } } } }.to_json
    auth = { token: "sink-bearer" }.to_json
    thread = Thread.new do
      while (client = server.accept)
        request = client.gets.to_s
        # Drain headers, keeping Content-Length so a PATCH body can be READ rather
        # than discarded — the renewal branch's payload is the assertion.
        length = 0
        while (line = client.gets) && line.strip != ""
          length = Regexp.last_match(1).to_i if line =~ /^Content-Length:\s*(\d+)/i
        end
        payload = length.positive? ? client.read(length) : nil
        writes << payload if writes && payload && request.start_with?("PATCH")
        body = request.include?("/api/v1/auth") ? auth : task
        client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill
  end

  def stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def run_task(*args)
    Open3.capture3(OFFLINE, BIN, *args)
  end
end
