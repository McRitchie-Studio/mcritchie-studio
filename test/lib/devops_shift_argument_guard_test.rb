# frozen_string_literal: true

# [unit] DevopsShiftCli must account for EVERY argument before it takes a shift.
#
# THE DEFECT — the third and last member of the family PR #974 (review_claim_cli) and
# PR #980 (release_claim_cli) closed. bin/devops-shift resolved its lane with a bare
# `argv.find { |a| !a.start_with?("--") }`, scanned for no help flag, and let
# parse_flags drop every unrecognized token into an ignored key. So:
#
#   bin/devops-shift acquire avi --help
#
# printed no usage, TOOK A REAL SHIFT LEASE on the avi lane, wrote the held-shift
# marker, and spawned a detached renewer to hold it — from a probe whose entire
# purpose was to ask what the command does. A single-dash token was worse still: the
# parser only ever looked at "--", so `-h` was not even recorded as an ignored key.
# It vanished, side effect and all.
#
# WHY THIS CLI IS THE ONE WHERE HELP EXITS 1, NOT 0. See
# test_help_never_answers_with_a_shift_state_code below: here exit 0 is not "the
# command worked", it is the ASSERTION "you are on shift", and it is the ONLY channel
# that assertion travels on.
#
# WHAT THIS FILE PROTECTS MOST IS THE OTHER DIRECTION. A guard that refuses
# everything looks exactly like a guard that works, and the failure is silent and
# expensive: refuse the DETACHED RENEWER's own spawned argv and every shift lease
# lapses ~120s into a multi-minute act, so two same-lane conductors run concurrently
# — the precise 2026-07-20 incident bin/lib/shift_renewer.rb exists to prevent. So
# REAL_ARGV below is the centerpiece: every real invocation of this CLI anywhere in
# the ecosystem, replayed through the guard, asserted to dispatch with its lane and
# flag VALUES intact.
#
# The CLI's board behavior lives in test/lib/devops_shift_cli_test.rb; the operator
# seam (a real process, a real stub board, a real detached renewer) in
# test/lib/devops_shift_flags_test.rb.
#
#   ruby -Itest test/lib/devops_shift_argument_guard_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "stringio"
# Arms the narration-marker sandbox for this PROCESS: this file drives a CLI that
# WRITES the marker store, so an unpinned run could reach the operator's real
# ~/projects/.agents. Same reason test/lib/devops_shift_cli_test.rb requires it.
require_relative "../support/session_env"

load File.expand_path("../../bin/devops-shift", __dir__)

class DevopsShiftArgumentGuardTest < Minitest::Test
  SESSION = "3bb327a7-8676-4cf5-ce12-81804d9cb728"

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
  #
  # The arities mirror the real arms exactly (`renew`/`release` take no flags hash,
  # `status` takes nothing), so a dispatch that would raise ArgumentError in
  # production raises it here too instead of being papered over by a *args stand-in.
  class DispatchRecorder < DevopsShiftCli
    attr_reader :dispatched

    def acquire(lane, flags)    = record("acquire", lane, flags)
    def renew(lane)             = record("renew", lane, {})
    def renew_loop(lane, flags) = record("renew-loop", lane, flags)
    def release(lane)           = record("release", lane, {})
    def status                  = record("status", nil, {})

    def record(command, lane, flags)
      @dispatched = { command: command, lane: lane, flags: flags }
      DevopsShiftCli::OK
    end
  end

  # ── THE ARGV INVENTORY ───────────────────────────────────────────────────────
  #
  # Every way this CLI is invoked anywhere, with the source that builds each line.
  # Grepped UNCAPPED for `devops-shift` / `devops_shift` / `DevopsShiftCli` /
  # `SHIFT_BIN` across the WHOLE projects root — every sibling repo (turf-monster,
  # rolio, studio-engine, solana-studio, turf-vault, chain-ops), every worktree, the
  # `.agents` narration store, and ~/.claude — not just this repo's bin/.
  #
  # THE RESULT OF THAT SWEEP IS ITSELF LOAD-BEARING: bin/devops-shift is HUB-ONLY.
  # No sibling repo, no hook, and no agent skill invokes it; the only non-hub
  # reference anywhere is the operator's permission allowlist
  # (~/projects/.claude/settings.local.json:1134,1145 — `Bash(bin/devops-shift
  # acquire *)` and `Bash(bin/devops-shift release *)`), which corroborates rows 1
  # and 2 rather than adding a shape. Knowing that mattered on the release-claim
  # sibling and it matters here: it is what bounds the wall risk to this table.
  #
  # The renewer's line is NOT hand-copied into this table; it is captured from a real
  # acquire in test_the_detached_renewers_own_argv_survives_the_guard_it_reenters,
  # because a hand copy proves the transcription, not the code.
  REAL_ARGV = [
    { source: "docs/agents/agents/alex/sops/clean-up.md:274 — clean-up takes the avi shift",
      argv: %w[acquire avi],
      command: "acquire", lane: "avi", flags: {} },
    { source: "docs/agents/agents/alex/sops/clean-up.md:353 — clean-up drops it when the wave ends",
      argv: %w[release avi],
      command: "release", lane: "avi", flags: {} },
    { source: "docs/agents/agents/alex/sops/clean-up.md:319 + system/devops-shift-lease.md:87 — the bare read",
      argv: %w[status],
      command: "status", lane: nil, flags: {} },
    { source: "bin/statusline:229,231 — the render-time heartbeat (the second renewer)",
      argv: %w[renew avi],
      command: "renew", lane: "avi", flags: {} },
    { source: "bin/devops-shift header:8 — acquire with the documented optional --label",
      argv: ["acquire", "alex", "--label", "Mew"],
      command: "acquire", lane: "alex", flags: { "label" => "Mew" } },
    { source: "test/lib/devops_shift_renewer_integration_test.rb:139 — the real detached renew-loop",
      argv: ["renew-loop", "avi", "--anchor-pid", "4242", "--anchor-start", "Mon Aug 17 09:12:01 2026"],
      command: "renew-loop", lane: "avi",
      flags: { "anchor-pid" => "4242", "anchor-start" => "Mon Aug 17 09:12:01 2026" } }
  ].freeze

  def cli(klass: DevopsShiftCli, env: {}, data: {}, projects_dir:)
    c = klass.new(env: { "DEVOPS_SHIFT_SESSION" => SESSION,
                         "DEVOPS_SHIFT_ANCHOR_PID" => Process.pid.to_s }.merge(env),
                  out: (@out = StringIO.new), err: (@err = StringIO.new))
    c.instance_variable_set(:@api, (@api = FakeApi.new(projects_dir: projects_dir, data: data)))
    @spawned = []
    c.instance_variable_set(:@spawner, ->(spawn_env, argv) { @spawned << [spawn_env, argv]; 4242 })
    c
  end

  # ── The wall check: every real invocation still gets through ─────────────────

  # THE POSITIVE CONTROL, and the reason this file exists in the shape it does. On the
  # release-claim sibling three separate mutations turned the guard into a wall and
  # were caught ONLY by this test: bad_arguments returning argv, COMMAND_FLAGS
  # emptied, and — the subtle one — the positional walk failing to consume flag
  # VALUES, so `--label Mew` read "Mew" as a stray positional and refused every real
  # line in the repo.
  def test_every_real_invocation_still_dispatches
    Dir.mktmpdir do |proj|
      REAL_ARGV.each do |row|
        c = cli(klass: DispatchRecorder, projects_dir: proj)
        code = c.run(row[:argv].dup)

        assert_equal DevopsShiftCli::OK, code, "#{row[:source]} was REFUSED: #{@err.string}"
        refute_nil c.dispatched, "#{row[:source]} never reached a command — #{@err.string}"
        # One equality over the whole dispatch: the command it reached, the lane it
        # resolved, AND every flag value it carried. Anything less would pass a guard
        # that let the line through but mangled what it handed the command.
        assert_equal({ command: row[:command], lane: row[:lane], flags: row[:flags] }, c.dispatched,
                     "#{row[:source]} reached the command with a mangled lane or flag VALUE")
      end
    end
  end

  # The renewer is the expensive half of the wall risk: `acquire` spawns it detached
  # with out:/err: File::NULL, so a guard that refused its line would print the
  # refusal into /dev/null and the shift would lapse ~120s into a multi-minute act —
  # two same-lane conductors, silently, which is the 2026-07-20 incident. Captured
  # from a REAL acquire and fed back through run(), which is the guard it re-enters.
  def test_the_detached_renewers_own_argv_survives_the_guard_it_reenters
    Dir.mktmpdir do |proj|
      acquirer = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      assert_equal DevopsShiftCli::OK, acquirer.run(%w[acquire avi])

      _env, spawn_argv = @spawned.first
      refute_nil spawn_argv, "acquire must start a detached renewer to have an argv to re-enter"

      # [ruby, bin/devops-shift, "renew-loop", …] — drop the interpreter and the
      # script path to get exactly what run() sees.
      replay = spawn_argv.drop(2)
      assert_equal "renew-loop", replay.first, "the renewer re-enters this very CLI"

      c = cli(klass: DispatchRecorder, projects_dir: proj)
      assert_equal DevopsShiftCli::OK, c.run(replay.dup),
                   "the renewer's own spawned line was refused by the guard it re-enters: #{@err.string}"
      got = c.dispatched
      assert_equal "renew-loop", got[:command]
      assert_equal "avi", got[:lane], "the renewer must renew THIS lane"
      refute_nil got[:flags]["anchor-pid"], "the anchor pid must survive — without it the renewer never stops"
      assert got[:flags].key?("anchor-start"), "the anchor start signature must survive"
    end
  end

  # An EMPTY value is not a missing one, and this CLI genuinely spawns one:
  # start_renewer builds `--anchor-start #{anchor[:start].to_s}`, and
  # SessionIdentity.proc_start returns "" whenever `ps` cannot read the anchor's start
  # signature (bin/lib/session_identity.rb:151-155). Refusing that line would kill the
  # renewer over a degenerate-but-HANDLED case — process_alive? already reads a blank
  # signature as "stop renewing", which is the safe direction, not an error.
  def test_an_empty_flag_value_is_consumed_not_refused
    Dir.mktmpdir do |proj|
      c = cli(klass: DispatchRecorder, projects_dir: proj)
      code = c.run(["renew-loop", "avi", "--anchor-pid", "4242", "--anchor-start", ""])

      assert_equal DevopsShiftCli::OK, code, "an empty flag value is a value: #{@err.string}"
      assert_equal "", c.dispatched[:flags]["anchor-start"]
      assert_equal "avi", c.dispatched[:lane], "and the empty value is not mistaken for the lane"
    end
  end

  # A drift guard on the inventory itself. The table above is only as good as its
  # claim to be COMPLETE, so pin the two external call sites by source: a new one, or
  # a new flag on an existing one, fails here and forces COMMAND_FLAGS to be extended
  # rather than discovering the wall in a live conductor act.
  def test_the_external_call_sites_still_match_the_pinned_argv_shapes
    statusline = File.read(File.expand_path("../../bin/statusline", __dir__))
    assert_match(/"\$SHIFT_BIN" renew "\$lane"/, statusline,
                 "the status-line heartbeat is the one external caller that runs on every render")

    cleanup = File.read(File.expand_path("../../docs/agents/agents/alex/sops/clean-up.md", __dir__))
    assert_match(/^bin\/devops-shift acquire avi$/, cleanup)
    assert_match(/^bin\/devops-shift release avi$/, cleanup)
    assert_match(/bin\/devops-shift status/, cleanup)

    renewer_test = File.read(File.expand_path("devops_shift_renewer_integration_test.rb", __dir__))
    assert_match(/"renew-loop", "avi",\s*\n\s*"--anchor-pid",/, renewer_test,
                 "the real detached-process test is the fourth caller — its shape must stay in REAL_ARGV")
  end

  # ── Refusal: the defect this task closes ─────────────────────────────────────

  def test_an_unknown_flag_refuses_instead_of_taking_the_shift
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(["acquire", "avi", "--force"])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_empty @api.calls, "an unrecognized flag must never reach the board"
      assert_empty @spawned, "and must never anchor a renewer"
      refute_path_exists File.join(proj, ".agents", "sessions"), "nor write the held-shift marker"
      assert_match(/unrecognized argument "--force"/, @err.string, "the refusal NAMES the offending argument")
      assert_match(/valid flags: --label/, @err.string, "and lists what IS valid")
    end
  end

  # A misspelled label used to dispatch with the flag silently dropped, so the shift
  # was taken under the session mascot instead of the label the operator typed —
  # a lease whose holder line named someone they did not choose.
  def test_a_misspelled_flag_names_itself
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      c.run(["acquire", "avi", "--lable", "Mew"])

      assert_empty @api.calls
      assert_match(/unrecognized argument "--lable"/, @err.string)
    end
  end

  # The more dangerous spelling: parse_flags only ever looked at "--", so a
  # single-dash token was not even recorded as an ignored key. It vanished.
  def test_a_single_dash_token_refuses_rather_than_vanishing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(["acquire", "avi", "-l", "Mew"])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/unrecognized arguments "-l", "Mew"/, @err.string)
    end
  end

  # A second positional is a caller who meant something else. Taking the FIRST lane
  # and discarding the rest is the same silent substitution as the dropped flag.
  def test_a_stray_positional_refuses
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(%w[acquire avi alex])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/unrecognized argument "alex"/, @err.string)
    end
  end

  # `status` is the CROSS-lane read: it reports every lane and takes no lane at all.
  # Before the guard `status avi` silently answered about ALL of them, which is the
  # same substitution one seam over — the caller named one lane and got a different
  # answer than the one they asked for.
  def test_a_lane_on_the_cross_lane_read_refuses_and_names_the_command_they_meant
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(%w[status avi])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/unrecognized argument "avi"/, @err.string)
      assert_match(/reports EVERY lane/, @err.string, "the refusal says why the lane had nowhere to go")
    end
  end

  # A value-flag that consumed no token: parse_flags stores `true` for it, and
  # `true.to_s` is the string "true" — so a trailing `--label` labelled the shift the
  # literal string "true", and the stand-down message then named a holder called
  # "true". A flag that consumed nothing is a usage error, not a boolean.
  def test_a_value_flag_with_no_value_refuses_rather_than_becoming_the_string_true
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(["acquire", "avi", "--label"])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/--label needs a value/, @err.string)
    end
  end

  # Same defect, other shape: the flag is followed by ANOTHER flag rather than by the
  # end of the line, so it silently consumed nothing.
  def test_a_value_flag_swallowed_by_the_next_flag_refuses
    Dir.mktmpdir do |proj|
      c = cli(klass: DispatchRecorder, projects_dir: proj)
      code = c.run(["renew-loop", "avi", "--anchor-pid", "--anchor-start", "Mon Aug 17 09:12:01 2026"])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_nil c.dispatched, "before this guard the renewer started with an anchor pid of `true`"
      assert_match(/--anchor-pid needs a value/, @err.string)
    end
  end

  # The lane used to be `argv.find { |a| !a.start_with?("--") }`, which reads the
  # VALUE of a preceding value-flag as the lane: `acquire --label Mew avi` took a
  # shift on a lane called "Mew" — a lane nothing else contends, so the lease looked
  # held and protected nothing.
  def test_the_lane_is_read_past_a_value_flag
    Dir.mktmpdir do |proj|
      c = cli(klass: DispatchRecorder, projects_dir: proj)
      code = c.run(["acquire", "--label", "Mew", "avi"])

      assert_equal DevopsShiftCli::OK, code
      assert_equal "avi", c.dispatched[:lane], "the LANE is the target, not the label"
      assert_equal "Mew", c.dispatched[:flags]["label"]
    end
  end

  def test_an_unknown_subcommand_prints_usage_and_touches_nothing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(%w[yoink avi])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(%r{usage: bin/devops-shift acquire}, @err.string)
    end
  end

  # A missing lane is a DIFFERENT mistake from an unaccountable argument, and it keeps
  # its own message: "you forgot the lane" must not read as "that lane is unknown".
  def test_a_missing_lane_still_says_so_rather_than_naming_a_bad_argument
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      code = c.run(%w[acquire])

      assert_equal DevopsShiftCli::CANT_RUN, code
      assert_empty @api.calls
      assert_match(/needs a lane/, @err.string)
      refute_match(/unrecognized/, @err.string)
    end
  end

  # ── --help from any position ─────────────────────────────────────────────────

  # THE HEADLINE REGRESSION, standing alone so nothing can mask it. `bin/devops-shift
  # acquire avi --help` — an agent asking what the command does — printed no usage and
  # TOOK THE avi SHIFT: it POSTed the acquire, wrote the held-shift marker, and
  # spawned a detached renewer to hold the lane for the life of the session.
  #
  # The assertions are ordered mutation-FIRST on purpose. Pre-fix this line also
  # printed a plausible message and exited 0 — it exited 0 HAVING TAKEN THE LEASE, so
  # printed text and exit code are both compatible with the bug. The absent POST is
  # the only thing a regression breaks.
  def test_help_after_a_lane_does_not_take_the_shift
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
      code = c.run(%w[acquire avi --help])

      assert_empty @api.calls, "a help probe must not POST the acquire"
      assert_empty @spawned, "nor anchor a detached renewer to hold the lane"
      refute_path_exists File.join(proj, ".agents", "sessions"),
                         "nor write the held-shift marker the status line renews from"
      assert_match(%r{usage: bin/devops-shift acquire}, @err.string, "usage goes to STDERR")
      assert_equal DevopsShiftCli::CANT_RUN, code
      # And it is ANSWERED, not scolded. This is the HELP_FLAGS scan's own contract,
      # and without it the line is still safe — `--help` would fall through to
      # unknown_flags and refuse — so nothing else in this file goes red when the scan
      # is deleted. What changes is the copy: `release avi --help` would greet a help
      # probe with `unrecognized argument "--help" … the shift is STILL HELD, and its
      # renewer keeps renewing it`, which is a typo's message and an alarm, for a
      # question. --help is a recognized request, not a mistake.
      refute_match(/unrecognized/, @err.string, "a help probe is answered, not treated as a typo")
    end
  end

  def test_help_prints_usage_and_mutates_nothing_from_any_position
    Dir.mktmpdir do |proj|
      [%w[acquire avi --help], %w[acquire avi -h], %w[acquire -h avi], %w[acquire --help],
       %w[release avi --help], %w[status --help], %w[--help], %w[-h]].each do |argv|
        c = cli(projects_dir: proj, data: { "acquired" => true, "holder" => {} })
        code = c.run(argv.dup)

        assert_empty @api.calls, "#{argv.inspect} must not reach the board"
        assert_empty @spawned, "#{argv.inspect} must not anchor a renewer"
        refute_path_exists File.join(proj, ".agents", "sessions"), "#{argv.inspect} must not write a marker"
        assert_match(%r{usage: bin/devops-shift acquire}, @err.string, "#{argv.inspect} prints usage")
        refute_match(/unrecognized/, @err.string, "#{argv.inspect} is a question, not a typo")
        assert_equal DevopsShiftCli::CANT_RUN, code, "#{argv.inspect} must not answer with a shift-state code"
      end
    end
  end

  # WHY HELP EXITS 1 AND NOT 0 — the deliberate divergence from ReviewClaimCli (PR
  # #974), and the same call ReleaseClaimCli made (PR #980), for a reason that is
  # STRONGER here than in either sibling.
  #
  # In this CLI exit 0 is not "the command worked", it is the assertion "YOU ARE ON
  # SHIFT" — and it is the ONLY channel that assertion travels on. ReviewClaimCli
  # could afford 0 because its claim rides on STDOUT (a caller reads
  # `slug=$(bin/task claim-next-review)`, so a 0 with empty stdout is self-evidently
  # not a claim). devops-shift has no such second channel: `acquire` prints prose for
  # a human and hands the machine 0-vs-10, nothing else. A help probe answered with 0
  # is indistinguishable from a real acquisition, and the caller that reads it —
  # clean-up's review wave, which acquires the avi lane and then spins reviewers —
  # would proceed believing it holds a lane it does not. That is exactly the
  # two-concurrent-supervisors failure the lease exists to prevent.
  #
  # CANT_RUN is where every other usage error already lands (usage_lane, cant_run),
  # and it is safe for every caller: bin/statusline discards the exit code entirely
  # (`>/dev/null 2>&1`), the detached renewer is spawned and never reaped for status,
  # and a conductor SOP reading 1 fails OPEN — proceeding while KNOWING it holds no
  # shift, which is the honest state, with usage text on stderr saying so.
  def test_help_never_answers_with_a_shift_state_code
    Dir.mktmpdir do |proj|
      assert_equal DevopsShiftCli::CANT_RUN, cli(projects_dir: proj).run(%w[acquire --help]),
                   "0 would tell clean-up's review wave it is on shift when it holds nothing"
      refute_equal DevopsShiftCli::STOOD_DOWN, cli(projects_dir: proj).run(%w[acquire --help]),
                   "10 would be the opposite lie — it would wedge the lane against a holder that does not exist"
    end
  end

  # ── The refusal COPY is per-subcommand ───────────────────────────────────────

  # PR #974's refusal ends "NOTHING was claimed" on every subcommand. On `release`
  # that sentence is not merely imprecise, it is wrong in the DANGEROUS direction: a
  # refused release leaves the shift HELD *and* its detached renewer still renewing,
  # so the lease does not even lapse on its TTL. An operator told "nothing was
  # claimed" would walk away from a lane that is locked until their process dies.
  def test_a_refused_release_says_the_shift_is_still_held
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(["release", "avi", "--force"])

      assert_match(/STILL HELD/, @err.string)
      assert_match(/renewer/, @err.string, "and that the renewer keeps it from lapsing")
      refute_match(/NOTHING was claimed/, @err.string,
                   "a refused release did not fail to claim — it failed to RELEASE")
    end
  end

  def test_a_refused_acquire_says_nothing_was_claimed
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(["acquire", "avi", "--force"])

      assert_match(/NOT on shift/, @err.string)
      refute_match(/STILL HELD/, @err.string)
    end
  end

  # A refused READ must not read as a mutation verdict either: "nothing was claimed"
  # on `status` invites the reader to conclude the lanes are free.
  def test_a_refused_read_says_it_answered_nothing
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(%w[status avi])

      assert_match(/nothing was read/, @err.string)
      refute_match(/NOTHING was claimed/, @err.string)
    end
  end

  # A refused renew must not claim the shift is dying — the detached renewer is the
  # PRIMARY beat and this one is the status line's redundant second, so overstating
  # the cost would send an operator chasing a lease that is perfectly healthy.
  def test_a_refused_renew_says_only_that_this_beat_was_lost
    Dir.mktmpdir do |proj|
      c = cli(projects_dir: proj)
      c.run(["renew", "avi", "--force"])

      assert_match(/this heartbeat never reached the board/, @err.string)
      refute_match(/STILL HELD|NOTHING was claimed/, @err.string)
    end
  end

  # ── Drift guards ─────────────────────────────────────────────────────────────

  # COMMAND_FLAGS doubles as the set of subcommands run() dispatches, so a key with no
  # `when` arm (or an arm with no key) is drift that would refuse a real command.
  def test_command_flags_and_the_dispatch_arms_stay_in_lockstep
    src = File.read(File.expand_path("../../bin/devops-shift", __dir__))
    body = src[/def run\(argv\).*?^  end$/m]
    arms = body.scan(/^\s*when "([a-z-]+)"/).flatten

    assert_equal DevopsShiftCli::COMMAND_FLAGS.keys.sort, arms.sort,
                 "every COMMAND_FLAGS key needs a dispatch arm and vice versa"
  end

  def test_every_subcommand_declares_its_refusal_consequence
    assert_equal DevopsShiftCli::COMMAND_FLAGS.keys.sort,
                 DevopsShiftCli::REFUSAL_CONSEQUENCE.keys.sort,
                 "a subcommand with no consequence copy would inherit an acquire-shaped refusal"
  end

  # Every flag this CLI defines today takes a value, so the missing-value refusal
  # applies to all of them. A future BOOLEAN flag must change this test deliberately
  # rather than silently inheriting a refusal that would reject its correct usage.
  def test_value_flags_covers_every_declared_flag
    assert_equal DevopsShiftCli::COMMAND_FLAGS.values.flatten.uniq.sort,
                 DevopsShiftCli::VALUE_FLAGS.sort,
                 "a new boolean flag must be excluded from VALUE_FLAGS on purpose"
  end

  # LANE_COMMANDS must name only real subcommands, or a typo there would make a
  # command's own lane look like a stray positional and refuse every real line.
  def test_lane_commands_are_all_real_subcommands
    assert_empty DevopsShiftCli::LANE_COMMANDS - DevopsShiftCli::COMMAND_FLAGS.keys
    refute_includes DevopsShiftCli::LANE_COMMANDS, "status",
                    "status is the CROSS-lane read — giving it a lane is what the guard refuses"
  end

  def test_help_flags_match_the_spellings_the_sibling_clis_honor
    assert_equal %w[--help -h].sort, DevopsShiftCli::HELP_FLAGS.sort,
                 "an agent probing this CLI cannot know it is a different parser"
    assert_equal SiblingHelpSpellings.expected, DevopsShiftCli::HELP_FLAGS.sort,
                 "all three claim/lease CLIs must honor the same two spellings"
  end

  # Read from the sibling CLI's source rather than loading it: loading a second
  # standalone CLI into this process would re-open its own constants and markers.
  module SiblingHelpSpellings
    def self.expected
      src = File.read(File.expand_path("../../bin/lib/release_claim_cli.rb", __dir__))
      src[/HELP_FLAGS = %w\[([^\]]+)\]/, 1].split.sort
    end
  end
end
