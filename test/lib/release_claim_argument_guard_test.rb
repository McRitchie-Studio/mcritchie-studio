# frozen_string_literal: true

# [unit] ReleaseClaimCli must account for EVERY argument before it dispatches.
#
# THE DEFECT (the sibling of the one PR 974 closed on ReviewClaimCli): unknown flags
# fell through parse_flags into an ignored key and the subcommand ran anyway. A
# `--role deployre` typo did not refuse — it dispatched with no role, and a `-h` probe
# was not even recorded as an ignored key: the single-dash token vanished entirely.
#
# EXPOSURE IS LOWER HERE THAN ON THE REVIEW CLAIM, and saying so is part of the fix
# being honest. There is no `bin/task release-claim` subcommand for an agent to probe,
# and every subcommand requires --role, so a bare `--help` line dies on the missing
# role before it mutates. This closes a family; it does not fix a live incident.
#
# WHAT THIS FILE PROTECTS MOST IS THE OTHER DIRECTION. A guard that refuses everything
# looks exactly like a guard that works, and here the failure is silent and expensive:
# refuse the DETACHED RENEWER's own spawned argv and every conductor lease lapses
# mid-act, so two `bin/release prepare` runs assemble the same release. So the argv
# INVENTORY below is the centerpiece — every real invocation in the repo, replayed
# through the guard, asserted to dispatch with its slug and flag VALUES intact.
#
# The CLI's board behavior lives in test/lib/release_claim_cli_test.rb; the operator
# seam (a real process, a real stub board) in test/lib/release_claim_flags_test.rb.
#
#   ruby -Itest test/lib/release_claim_argument_guard_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "stringio"
# Arms the narration-marker sandbox for this PROCESS: this file drives a CLI that
# WRITES the marker store, so an unpinned run could reach the operator's real
# ~/projects/.agents. Same reason test/lib/release_claim_cli_test.rb requires it.
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/release_claim_cli.rb", __dir__)

class ReleaseClaimArgumentGuardTest < Minitest::Test
  SESSION = "7cc218a6-8676-4cf5-ce12-81804d9cb728"
  SLUG = "rel-20260721-abc123"

  Resp = Struct.new(:code, :body)

  # A stand-in for AgentApi that RECORDS every request. Recording is the point: the
  # refusal assertions below are all "the board was never touched", and a fake that
  # answered without recording would make them true for the wrong reason.
  class FakeApi
    attr_reader :calls

    def initialize(projects_dir:, data: {})
      @projects_dir = projects_dir
      @data = data
      @calls = []
    end

    def token = "tok"
    def projects_dir = @projects_dir
    def env = { "CLAUDE_PROJECTS_DIR" => @projects_dir }
    def invalidate_token!(*) = nil
    def present?(value) = !value.to_s.strip.empty?

    def http_json(method, path, body = nil, **)
      @calls << { method: method, path: path, body: body }
      Resp.new(200, JSON.generate({ data: @data }))
    end
  end

  # Records the dispatch instead of performing it, so an argv's SURVIVAL is observable
  # without a board, a renewer, or a sleep. Every command arm is overridden, which is
  # what lets one loop cover the whole inventory — and what makes "the flag values
  # arrived intact" an assertion rather than an inference.
  class DispatchRecorder < ReleaseClaimCli
    attr_reader :dispatched

    def acquire(slug, flags)    = record("acquire", slug, flags)
    def renew(slug, flags)      = record("renew", slug, flags)
    def renew_loop(slug, flags) = record("renew-loop", slug, flags)
    def release(slug, flags)    = record("release", slug, flags)
    def status(slug, flags)     = record("status", slug, flags)
    def any_live(flags)         = record("any-live", nil, flags)

    def record(command, slug, flags)
      @dispatched = { command: command, slug: slug, flags: flags }
      ReleaseClaimCli::OK
    end
  end

  # ── THE ARGV INVENTORY ───────────────────────────────────────────────────────
  # Every way this CLI is invoked anywhere in the repo, with the source that builds
  # each line. Grepped for `release_claim_cli` / `ReleaseClaimCli` / `release-claim`
  # across the whole tree, not just bin/. `renew` and `status` have no production
  # caller — they are hand/internal commands — so their documented shapes are pinned
  # here from the CLI's own header block, which is the contract an operator types.
  #
  # The renewer's line is NOT hand-copied into this table; it is captured from a real
  # acquire in test_the_detached_renewers_own_argv_survives_the_guard_it_reenters,
  # because a hand copy proves the transcription, not the code.
  REAL_ARGV = [
    { source: "bin/release.rb:717 acquire_conductor_claim!",
      argv: ["acquire", SLUG, "--role", "deployer"],
      command: "acquire", slug: SLUG, flags: { "role" => "deployer" } },
    { source: "bin/release.rb:743 release_conductor_claim!",
      argv: ["release", SLUG, "--role", "assembler"],
      command: "release", slug: SLUG, flags: { "role" => "assembler" } },
    { source: "bin/release.rb:1595 the __forming__ sentinel (same call site, sentinel slug)",
      argv: ["acquire", ReleaseClaimCli::FORMING_SLUG, "--role", "assembler"],
      command: "acquire", slug: ReleaseClaimCli::FORMING_SLUG, flags: { "role" => "assembler" } },
    { source: "bin/agent-worktree:3092 role_claim_liveness (the reclaim guard)",
      argv: ["any-live", "--role", "assembler"],
      command: "any-live", slug: nil, flags: { "role" => "assembler" } },
    { source: "bin/lib/release_claim_cli.rb header — the documented hand `renew`",
      argv: ["renew", SLUG, "--role", "deployer"],
      command: "renew", slug: SLUG, flags: { "role" => "deployer" } },
    { source: "bin/lib/release_claim_cli.rb header — the documented hand `status`",
      argv: ["status", SLUG, "--role", "deployer"],
      command: "status", slug: SLUG, flags: { "role" => "deployer" } },
    { source: "bin/lib/release_claim_cli.rb header — `acquire` with the optional --label",
      argv: ["acquire", SLUG, "--role", "assembler", "--label", "Snorlax"],
      command: "acquire", slug: SLUG, flags: { "role" => "assembler", "label" => "Snorlax" } }
  ].freeze

  def cli(klass: ReleaseClaimCli, env: {}, data: {}, projects_dir:)
    c = klass.new(env: { "RELEASE_CONDUCTOR_CLAIM_SESSION" => SESSION,
                         "RELEASE_CONDUCTOR_CLAIM_ANCHOR_PID" => Process.pid.to_s }.merge(env),
                  out: (@out = StringIO.new), err: (@err = StringIO.new))
    c.instance_variable_set(:@api, (@api = FakeApi.new(projects_dir: projects_dir, data: data)))
    @spawned = []
    c.instance_variable_set(:@spawner, ->(spawn_env, argv) { @spawned << [spawn_env, argv]; 4242 })
    c
  end

  # ── The wall check: every real invocation still gets through ─────────────────

  # THE POSITIVE CONTROL, and the reason this file exists in the shape it does. Three
  # separate mutations of the sibling's guard turned it into a wall and were caught
  # ONLY here: bad_arguments returning argv, COMMAND_FLAGS emptied, and — the subtle
  # one — the positional walk failing to consume flag VALUES, so `--role deployer` read
  # "deployer" as a stray positional and refused every real line in the repo.
  def test_every_real_invocation_in_the_repo_still_dispatches
    Dir.mktmpdir do |proj|
      REAL_ARGV.each do |row|
        c = cli(klass: DispatchRecorder, projects_dir: proj)
        code = c.run(row[:argv].dup)

        assert_equal ReleaseClaimCli::OK, code, "#{row[:source]} was REFUSED: #{@err.string}"
        refute_nil c.dispatched, "#{row[:source]} never reached a command — #{@err.string}"
        # One equality over the whole dispatch: the command it reached, the slug it
        # resolved, AND every flag value it carried. Anything less would pass a guard
        # that let the line through but mangled what it handed the command.
        assert_equal({ command: row[:command], slug: row[:slug], flags: row[:flags] }, c.dispatched,
                     "#{row[:source]} reached the command with a mangled slug or flag VALUE")
      end
    end
  end

  # The renewer is the expensive half of the wall risk: `acquire` spawns it detached
  # with out:/err: File::NULL, so a guard that refused its line would print the refusal
  # into /dev/null and the conductor claim would lapse ~120s into a multi-minute
  # assemble or ship — two conductors on one release, silently. Captured from a REAL
  # acquire and fed back through run(), which is the guard it re-enters.
  def test_the_detached_renewers_own_argv_survives_the_guard_it_reenters
    Dir.mktmpdir do |proj|
      acquirer = cli(projects_dir: proj, data: { "acquired" => true })
      assert_equal ReleaseClaimCli::OK, acquirer.run(["acquire", SLUG, "--role", "deployer"])

      _env, spawn_argv = @spawned.first
      refute_nil spawn_argv, "acquire must start a detached renewer to have an argv to re-enter"

      # [ruby, this_file, "renew-loop", …] — drop the interpreter and the script path
      # to get exactly what run() sees.
      replay = spawn_argv.drop(2)
      assert_equal "renew-loop", replay.first, "the renewer re-enters this very CLI"

      c = cli(klass: DispatchRecorder, projects_dir: proj)
      assert_equal ReleaseClaimCli::OK, c.run(replay.dup),
                   "the renewer's own spawned line was refused by the guard it re-enters: #{@err.string}"
      got = c.dispatched
      assert_equal "renew-loop", got[:command]
      assert_equal SLUG, got[:slug], "the renewer must renew THIS release"
      assert_equal "deployer", got[:flags]["role"], "a renewer with the wrong role renews nothing, silently"
      refute_nil got[:flags]["anchor-pid"], "the anchor pid must survive — without it the renewer never stops"
      assert got[:flags].key?("anchor-start"), "the anchor start signature must survive"
    end
  end

  # A drift guard on the inventory itself. The table above is only as good as its
  # claim to be COMPLETE, so pin the two external call sites by source: a new one, or
  # a new flag on an existing one, fails here and forces COMMAND_FLAGS to be extended
  # rather than discovering the wall in a live release.
  def test_the_external_call_sites_still_match_the_pinned_argv_shapes
    release_rb = File.read(File.expand_path("../../bin/release.rb", __dir__))
    invocations = release_rb.scan(/conductor_claim\("/)
    assert_equal 2, invocations.length,
                 "bin/release.rb gained or lost a claim-CLI call site — add it to REAL_ARGV and COMMAND_FLAGS"
    assert_match(/conductor_claim\("acquire", s, "--role", role\)/, release_rb)
    assert_match(/conductor_claim\("release", c\[:slug\], "--role", c\[:role\]\)/, release_rb)

    worktree = File.read(File.expand_path("../../bin/agent-worktree", __dir__))
    assert_match(/"any-live", "--role", role/, worktree,
                 "the reclaim guard's liveness read is the third real caller")
  end

  # ── Refusal: the defect this task closes ─────────────────────────────────────

  def test_an_unknown_flag_refuses_instead_of_dispatching
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(["acquire", SLUG, "--role", "deployer", "--force"])

      assert_equal ReleaseClaimCli::CANT_RUN, code
      assert_empty @api.calls, "an unrecognized flag must never reach the board"
      assert_match(/unrecognized argument "--force"/, @err.string, "the refusal NAMES the offending argument")
      assert_match(/valid flags: --role, --label/, @err.string, "and lists what IS valid")
    end
  end

  # A misspelled role flag used to dispatch with NO role and die on usage_role, which
  # reads like "you forgot --role" when you did not — you typo'd it.
  def test_a_misspelled_flag_names_itself_rather_than_reading_as_a_missing_role
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(["acquire", SLUG, "--rol", "deployer"])

      assert_match(/unrecognized argument "--rol"/, @err.string)
      refute_match(/needs --role assembler\|deployer\z/, @err.string,
                   "a typo'd flag must not masquerade as an omitted one")
    end
  end

  # The more dangerous spelling: parse_flags only ever looked at "--", so a
  # single-dash token was not even recorded as an ignored key. It vanished.
  def test_a_single_dash_token_refuses_rather_than_vanishing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(["acquire", SLUG, "-r", "deployer"])

      assert_equal ReleaseClaimCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/unrecognized arguments "-r", "deployer"/, @err.string)
    end
  end

  # A second positional is a caller who meant something else — most likely the role,
  # typed bare. Claiming the FIRST one and discarding the rest is the same silent
  # substitution as the dropped flag, one seam over.
  def test_a_stray_positional_refuses
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(["acquire", SLUG, "deployer"])

      assert_equal ReleaseClaimCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/unrecognized argument "deployer"/, @err.string)
    end
  end

  def test_an_unknown_subcommand_prints_usage_and_touches_nothing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(["yoink", SLUG, "--role", "deployer"])

      assert_equal ReleaseClaimCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/usage: release-claim acquire/, @err.string)
    end
  end

  # ── --help from any position ─────────────────────────────────────────────────

  def test_help_prints_usage_and_mutates_nothing_from_any_position
    Dir.mktmpdir do |proj|
      [["--help"], ["acquire", "--help"], ["acquire", SLUG, "--role", "deployer", "--help"],
       ["-h"], ["acquire", SLUG, "-h", "--role", "deployer"]].each do |argv|
        c = cli(projects_dir: proj)
        code = c.run(argv.dup)

        assert_empty @api.calls, "#{argv.inspect} must not reach the board"
        assert_empty @spawned, "#{argv.inspect} must not start a renewer"
        assert_match(/usage: release-claim acquire/, @err.string, "#{argv.inspect} prints usage")
        assert_equal ReleaseClaimCli::CANT_RUN, code, "#{argv.inspect} must not answer with a claim-state code"
      end
    end
  end

  # WHY HELP EXITS 1 AND NOT 0, diverging from ReviewClaimCli (PR 974), deliberately:
  # in THIS CLI exit 0 is not "the command worked", it is a claim-state ASSERTION —
  # `acquire` 0 means "you hold the lease" (bin/release.rb:722 then records a held
  # claim it would have to release) and `any-live` 0 means "a release is live, withhold
  # the workspaces". Answering a help probe with 0 states a fact about the world that
  # is not true, which is the exact class of bug this task closes. CANT_RUN is where
  # every other usage error already lands (usage_slug/usage_role), and both readers
  # already treat it safely: bin/release fails OPEN, the reclaim guard fails CLOSED.
  def test_help_never_answers_with_a_claim_state_code
    Dir.mktmpdir do |proj|
      assert_equal ReleaseClaimCli::CANT_RUN, cli(projects_dir: proj).run(["acquire", "--help"]),
                   "0 would make bin/release record a claim it does not hold"
      assert_equal ReleaseClaimCli::CANT_RUN, cli(projects_dir: proj).run(["any-live", "--help"]),
                   "0 would tell the reclaim guard a release is live"
    end
  end

  # ── A value-flag with no value ───────────────────────────────────────────────

  # Non-blocker (b) from the sibling review, and it BITES here: parse_flags stores
  # `true` for a flag that consumed no token, and acquire does `flags["label"].to_s`,
  # so a trailing `--label` labelled the conductor claim the literal string "true".
  # The stand-down message then names a holder called "true".
  def test_a_value_flag_with_no_value_refuses_rather_than_becoming_the_string_true
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(["acquire", SLUG, "--role", "deployer", "--label"])

      assert_equal ReleaseClaimCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/--label needs a value/, @err.string)
    end
  end

  # Same defect, other shape: the flag is followed by ANOTHER flag rather than by the
  # end of the line, so it silently consumed nothing.
  def test_a_value_flag_swallowed_by_the_next_flag_refuses
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(["acquire", SLUG, "--label", "--role", "deployer"])

      assert_equal ReleaseClaimCli::CANT_RUN, code
      assert_match(/--label needs a value/, @err.string)
      assert_empty @api.calls, "before this guard the claim went through, labelled \"true\""
    end
  end

  # An EMPTY value is not a missing one. The renewer legitimately spawns with
  # `--anchor-start ""` when ps cannot read the anchor's start signature, and refusing
  # that line would kill the renewer over a degenerate-but-handled case (process_alive?
  # already reads a blank signature as "stop renewing").
  def test_an_empty_value_is_consumed_not_refused
    Dir.mktmpdir do |proj|
      c = cli(klass: DispatchRecorder, projects_dir: proj)
      code = c.run(["renew-loop", SLUG, "--role", "deployer", "--anchor-pid", "4242", "--anchor-start", ""])

      assert_equal ReleaseClaimCli::OK, code, "an empty flag value is a value: #{@err.string}"
      assert_equal "", c.dispatched[:flags]["anchor-start"]
    end
  end

  # ── The refusal COPY is per-subcommand ───────────────────────────────────────

  # Non-blocker (a) from the sibling review. PR 974's refusal ends "NOTHING was
  # claimed" on every subcommand. Here that sentence is not merely imprecise on
  # `release`, it is wrong in the DANGEROUS direction: a refused `release` leaves the
  # claim HELD and its detached renewer still renewing, so the lease does not even
  # lapse. An operator told "nothing was claimed" would walk away from a locked lane.
  def test_a_refused_release_says_the_claim_is_still_held
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(["release", SLUG, "--role", "deployer", "--force"])

      assert_match(/STILL HELD/, @err.string)
      refute_match(/NOTHING was claimed/, @err.string,
                   "a refused release did not fail to claim — it failed to RELEASE")
    end
  end

  def test_a_refused_acquire_says_nothing_was_claimed
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(["acquire", SLUG, "--role", "deployer", "--force"])

      assert_match(/NOTHING was claimed/, @err.string)
    end
  end

  # A refused READ must not read as a mutation verdict either: "nothing was claimed"
  # on `any-live` invites the reclaim guard's operator to conclude no release is live.
  def test_a_refused_read_says_it_answered_nothing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(["any-live", "--role", "deployer", "--force"])

      assert_match(/nothing was read/, @err.string)
      refute_match(/NOTHING was claimed/, @err.string)
    end
  end

  # ── Drift guards ─────────────────────────────────────────────────────────────

  # COMMAND_FLAGS doubles as the set of subcommands run() dispatches, so a key with no
  # `when` arm (or an arm with no key) is drift that would refuse a real command.
  def test_command_flags_and_the_dispatch_arms_stay_in_lockstep
    src = File.read(File.expand_path("../../bin/lib/release_claim_cli.rb", __dir__))
    body = src[/def run\(argv\).*?^  end$/m]
    arms = body.scan(/^\s*when "([a-z-]+)"/).flatten

    assert_equal ReleaseClaimCli::COMMAND_FLAGS.keys.sort, arms.sort,
                 "every COMMAND_FLAGS key needs a dispatch arm and vice versa"
  end

  def test_every_subcommand_declares_its_refusal_consequence
    assert_equal ReleaseClaimCli::COMMAND_FLAGS.keys.sort,
                 ReleaseClaimCli::REFUSAL_CONSEQUENCE.keys.sort,
                 "a subcommand with no consequence copy would inherit an acquire-shaped refusal"
  end

  # Every flag this CLI defines today takes a value, so the missing-value refusal
  # applies to all of them. A future BOOLEAN flag must change this test deliberately
  # rather than silently inheriting a refusal that would reject its correct usage.
  def test_value_flags_covers_every_declared_flag
    assert_equal ReleaseClaimCli::COMMAND_FLAGS.values.flatten.uniq.sort,
                 ReleaseClaimCli::VALUE_FLAGS.sort,
                 "a new boolean flag must be excluded from VALUE_FLAGS on purpose"
  end

  def test_help_flags_match_the_spellings_bin_task_honors
    assert_equal %w[--help -h].sort, ReleaseClaimCli::HELP_FLAGS.sort,
                 "an agent probing this CLI cannot know it is a different parser"
    assert_equal ReviewClaimHelpSpellings.expected, ReleaseClaimCli::HELP_FLAGS.sort,
                 "the two claim CLIs must honor the same two spellings"
  end

  # Read from the sibling CLI's source rather than loading it: loading a second
  # standalone CLI into this process would re-open its own constants and markers.
  module ReviewClaimHelpSpellings
    def self.expected
      src = File.read(File.expand_path("../../bin/lib/review_claim_cli.rb", __dir__))
      src[/HELP_FLAGS = %w\[([^\]]+)\]/, 1].split.sort
    end
  end
end
