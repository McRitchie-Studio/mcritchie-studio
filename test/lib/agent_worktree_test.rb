# frozen_string_literal: true

# Standalone test for bin/agent-worktree's pure helpers — port allocation and
# the finish --pr handoff (PR-URL parse + task stamp). Mirrors
# test/lib/release_cli_test.rb: it `load`s the script in a clean subprocess so the
# guarded dispatch (`if $PROGRAM_NAME == __FILE__`) never fires, redefines the
# I/O-bound helpers (allocated_ports / port_listening? / port_pid / process_cwd)
# as stubs, and exercises the real allocation + adoption-guard logic. Run directly:
#   ruby -Itest test/lib/agent_worktree_test.rb
# Also picked up by the normal `bin/rails test` sweep.
require "minitest/autorun"
require "open3"
require "time" # Time#iso8601 — the claim-lease expiry format the reclaim guard reads
require_relative "../support/session_env"

class AgentWorktreeTest < Minitest::Test
  BIN = File.expand_path("../../bin/agent-worktree", __dir__)

  # How many times to re-spawn a check whose subprocess produced no usable output.
  # See run_in_script for why a deterministic computation is safe to retry.
  SUBPROCESS_ATTEMPTS = 3

  # Load the script (dispatch suppressed by its main guard), run `body`, return
  # the printed value.
  #
  # The COMPUTATION here is deterministic — every check stubs the I/O helpers and
  # exercises pure allocation logic over the static APP_OVERRIDES/satellites config,
  # so a correct run ALWAYS prints the same thing. The PROCESS SPAWN is not: under
  # CI's parallel-fork harness a child occasionally got reaped/killed before it
  # flushed stdout, and the old helper discarded both stderr (`err: File::NULL`) and
  # the exit status, so that transient surfaced as a bare, undiagnosable `Actual: ""`
  # (the flake this test was named for).
  #
  # Hardening, both halves:
  #   * Open3.capture3 blocking-reads stdout AND stderr and waits for the child to
  #     exit, so there is no early-read / unflushed-output race.
  #   * Because the output is deterministic, a transient empty/failed spawn is
  #     RETRIED up to SUBPROCESS_ATTEMPTS times. A real logic error fails every
  #     attempt (deterministically), so the retry cannot mask a genuine regression —
  #     it only absorbs the non-deterministic spawn hiccup.
  #   * If every attempt yields no usable output it FLUNKS with the captured
  #     exit/signal + stderr, so the empty-output mode can never again recur
  #     silently. (rubygems "already initialized" warnings land on the child's
  #     stderr but are ignored on success — we only surface stderr when flunking.)
  def run_in_script(body)
    script = "load #{BIN.inspect}\n#{body}"
    last = nil
    SUBPROCESS_ATTEMPTS.times do
      # SessionEnv.neutralized: the child loads bin/agent-worktree, which resolves
      # session identity — it must name NO session (test/support/session_env.rb).
      out, err, status = Open3.capture3(SessionEnv.neutralized, "ruby", "-e", script)
      return out.strip if status.success? && !out.strip.empty?

      last = { out: out, err: err, status: status }
    end

    status = last[:status]
    flunk <<~MSG
      agent-worktree subprocess produced no usable output after #{SUBPROCESS_ATTEMPTS} attempts.
        exit=#{status.exitstatus.inspect} signal=#{status.termsig.inspect}
        stdout=#{last[:out].inspect}
        stderr:
      #{last[:err].to_s.gsub(/^/, "    ")}
    MSG
  end

  # --- allocate_port: reserved_ports are skipped, not just live listeners ------

  def test_allocate_port_skips_reserved_ports
    out = run_in_script(<<~RUBY)
      def allocated_ports(_a); (3001..3019).to_a; end
      def port_listening?(_p); false; end
      app = { "primary_port" => 3000, "range_end" => 3099, "range_start" => 3000, "reserved_ports" => [3020] }
      print allocate_port(app)
    RUBY
    assert_equal "3021", out, "3001-3019 used + 3020 reserved => next free is 3021"
  end

  def test_allocate_port_uses_the_port_when_not_reserved
    out = run_in_script(<<~RUBY)
      def allocated_ports(_a); (3001..3019).to_a; end
      def port_listening?(_p); false; end
      app = { "primary_port" => 3000, "range_end" => 3099, "range_start" => 3000, "reserved_ports" => [] }
      print allocate_port(app)
    RUBY
    assert_equal "3020", out, "control: without the reservation 3020 is allocated"
  end

  # --- worktree header task line (fast-lane-output-clarity) --------------------

  # [unit] The task-line VALUE: a bound URL passes through; an unbound desk gets a
  # non-alarming "here's how to bind" fallback, never the old "bind after task
  # creation" that read like a failed bind inside `bin/task begin`.
  def test_task_line_value_falls_back_to_a_non_alarming_message
    out = run_in_script(<<~RUBY)
      print [
        task_line_value("https://mcritchie.studio/tasks/demo"),
        "|",
        task_line_value(nil)
      ].join
    RUBY
    bound, unbound = out.split("|", 2)
    assert_equal "https://mcritchie.studio/tasks/demo", bound, "a bound URL passes through unchanged"
    refute_includes unbound, "bind after task creation", "the stale, failure-reading fallback is gone"
    assert_includes unbound, "bind-task", "the fallback names the next action"
  end

  # [integration] The whole header render through the REAL script (load + print_plan):
  # the `task:` line must not READ like a failure when the desk isn't bound yet.
  # `new`/`plan` print this before bind-task runs, and inside `bin/task begin` — which
  # binds at its very next step — the old fallback looked as if the bind had FAILED.
  def test_worktree_header_task_line_is_not_alarming_when_unbound
    out = run_in_script(<<~RUBY)
      def task_url(_v); nil; end                  # the desk is not bound yet
      def base_branch_for(_r); "accepted"; end
      def redis_physical_count; 64; end
      app = { "display_name" => "Demo", "slug" => "demo", "repo" => "/tmp/demo",
              "session_env" => "DEMO_SESSION_KEY", "primary_port" => 3000 }
      values = { "REDIS_URL" => "redis://localhost/29", "APP_PORT" => "3029",
                 "DATABASE_URL" => "postgresql://localhost/demo_dev", "DEMO_SESSION_KEY" => "_demo_session" }
      print_plan(app, "my-task", values, "/tmp/demo/.worktrees/my-task")
    RUBY
    task_line = out.lines.find { |l| l.start_with?("task:") }
    assert task_line, "the header must print a task: line, got:\\n#{out}"
    refute_includes task_line, "bind after task creation",
                    "the stale, failure-reading fallback must be gone"
    assert_includes task_line, "bind-task", "the fallback must name the next action (bind-task)"
  end

  # --- own_stack_on_port?: the foreign-adoption guard -------------------------

  def test_own_stack_true_when_listener_cwd_is_the_worktree
    out = run_in_script(<<~RUBY)
      def port_pid(_p); "12345"; end
      def process_cwd(_pid); "/Users/alex/projects/mcritchie-studio/.worktrees/foo"; end
      print own_stack_on_port?(3020, "/Users/alex/projects/mcritchie-studio/.worktrees/foo")
    RUBY
    assert_equal "true", out
  end

  def test_own_stack_false_for_a_foreign_listener
    out = run_in_script(<<~RUBY)
      def port_pid(_p); "12345"; end
      def process_cwd(_pid); "/Users/alex/projects/rolio"; end
      print own_stack_on_port?(3020, "/Users/alex/projects/mcritchie-studio/.worktrees/foo")
    RUBY
    assert_equal "false", out, "a rolio process on the port is not this worktree's stack"
  end

  def test_own_stack_false_when_port_is_free
    out = run_in_script(<<~RUBY)
      def port_pid(_p); ""; end
      print own_stack_on_port?(3020, "/x")
    RUBY
    assert_equal "false", out
  end

  # --- reclaim guard: claim_hold (devops-shift-lease follow-up) ---------------
  # The claim decision (ClaimLease) over the task's devops record, with the board read
  # (task_record_for_pr) stubbed. A LIVE claim withholds the desk; a lapsed or unbound one
  # fails open. A BOUND-but-unreadable record is WITHHELD on every lane — there is no
  # "advisory" lane, because every caller's answer is consumed to destroy.

  # A BOUND desk (it has a task slug) — an UNBOUND one short-circuits to "free" before the
  # claim is even consulted, which is its own case below.
  def live_claimed(devops_ruby)
    run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false); { "metadata" => { "devops" => #{devops_ruby} } }; end
      print !claim_hold({ env: { "TASK_RECORD_SLUG" => "t" }, task: "t" }).nil?
    RUBY
  end

  def test_claim_hold_withholds_for_a_non_expired_claim
    assert_equal "true",
                 live_claimed(%({ "claimed_session" => "s", "claim_expires_at" => "2099-01-01T00:00:00Z" })),
                 "a builder actively renewing its claim protects the desk"
  end

  def test_claim_hold_frees_a_lapsed_claim
    assert_equal "false",
                 live_claimed(%({ "claimed_session" => "s", "claim_expires_at" => "2000-01-01T00:00:00Z" })),
                 "a crashed/closed builder's lease has lapsed → reclaimable"
  end

  def test_claim_hold_frees_an_unclaimed_or_unbound_task
    assert_equal "false", live_claimed("{}"), "no claim → reclaimable"
    # an UNBOUND desk fails open (we cannot look up a claim we cannot identify)
    out = run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false); {}; end
      print !claim_hold({}).nil?
    RUBY
    assert_equal "false", out, "an unbound desk is not a live claim"
  end

  # THE ASYMMETRY. Three "no live claim found" cases, and they are NOT alike:
  #   unbound  — we cannot identify the desk. Forced fail-open (withholding every
  #              unidentifiable desk would wedge cleanup entirely).
  #   lapsed   — we checked; the builder is gone. Free.
  #   bound + UNREADABLE — we know the desk COULD be claimed and failed to find out.
  # There is no "advisory" lane: every caller answers "is this a cleanup candidate?", and that
  # answer is consumed to destroy (the registry feeds qa-intake, which prints `remove --yes`).
  # So an unverifiable desk is withheld EVERYWHERE. During an outage the truthful answer is
  # "I cannot tell" — withholding IS that answer; nominating is the lie.
  def test_bound_but_unreadable_is_withheld_everywhere
    hold = run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false); nil; end
      print claim_hold({ env: { "TASK_RECORD_SLUG" => "t" }, task: "t" })
    RUBY
    assert_match(/could not be read/, hold, "a desk we could not verify must never be nominated")
    assert_match(/withholding rather than nominating/, hold)
  end

  # An UNBOUND desk still fails open — there is no claim to look up, so withholding it would
  # wedge every ad-hoc worktree forever.
  def test_unbound_still_fails_open
    out = run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false); nil; end
      print claim_hold({ task: "t" }).inspect
    RUBY
    assert_equal "nil", out
  end

  # The HOLD REASON is what the destructive paths print instead of a silent skip — it must
  # name the hold and carry the builder's heartbeat age so the operator can check it.
  def test_claim_hold_reason_names_the_live_builder_and_its_heartbeat_age
    expires = (Time.now + 110).utc.iso8601
    out = run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false)
        { "metadata" => { "devops" => { "claimed_session" => "s", "claim_expires_at" => #{expires.inspect} } } }
      end
      print claim_hold({ env: { "TASK_RECORD_SLUG" => "busy-task" }, task: "busy-task" })
    RUBY
    assert_match(/held by a live builder claim \(busy-task\)/, out)
    assert_match(/builder heartbeat \d+s ago/, out, "the age makes the hold verifiable, not a bare refusal")
  end

  # A CORRUPT claim — the lease is PRESENT but its expiry is unparseable, so liveness cannot be
  # verified. live? merges it into "possibly live" (the desk is still WITHHELD, which is right),
  # but the honest reason is NOT "a builder is here" — it is "we could not check". Before this
  # branch existed the corrupt case fell through to the live-builder message and interpolated a
  # nil heartbeat age ("builder heartbeat  s ago"), both misattributing the hold AND printing
  # garbage. ClaimLease.corrupt_expiry? exists precisely to split this out.
  def test_claim_hold_reason_for_a_corrupt_claim_says_expiry_unverifiable_not_live_builder
    out = run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false)
        { "metadata" => { "devops" => { "claimed_session" => "s", "claim_expires_at" => "not-a-timestamp" } } }
      end
      print claim_hold({ env: { "TASK_RECORD_SLUG" => "busy-task" }, task: "busy-task" })
    RUBY
    assert_match(/expiry unverifiable/, out,
                 "a corrupt lease means we could not check liveness — the hold must say so")
    assert_match(/busy-task/, out, "name the task so the operator can inspect it")
    refute_match(/live builder/, out,
                 "a corrupt claim must NOT be misattributed to a confirmed live builder")
    refute_match(/heartbeat/, out,
                 "no heartbeat age is knowable from an unparseable lease — the garbled " \
                 "'heartbeat  s ago' interpolation must be gone entirely")
  end

  def test_claim_hold_is_nil_when_free
    out = run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false); { "metadata" => { "devops" => {} } }; end
      print claim_hold({ env: {} }).inspect
    RUBY
    assert_equal "nil", out, "an unheld desk yields no reason (and is reclaimable)"
  end

  # The ONE decision every destructive path, doctor AND the registry route through, so the
  # conductor's front door can never nominate a desk the sweep would refuse. Returns
  # [reclaimable?, hold_reason] — a bare boolean helper would not serve the callers (they
  # all need the reason), which is how the previous cut ended up with a shared predicate
  # that nothing actually called.
  def test_reclaim_verdict_is_the_one_decision
    # git-eligible + unheld → free, no reason
    assert_equal "[true, nil]", verdict_for(held: false, dirty: false)
    # git-eligible but HELD → withheld, WITH a reason to print
    assert_match(/\A\[false, "held by a live builder claim/, verdict_for(held: true, dirty: false))
    # not git-eligible → never a candidate, and NOT "withheld" (nothing to narrate)
    assert_equal "[false, nil]", verdict_for(held: false, dirty: true)
  end

  def verdict_for(held:, dirty:)
    devops = held ? %({ "claimed_session" => "s", "claim_expires_at" => #{(Time.now + 110).utc.iso8601.inspect} }) : "{}"
    run_in_script(<<~RUBY)
      def task_record_for_pr(_r, fresh: false); { "metadata" => { "devops" => #{devops} } }; end
      record = { dirty: #{dirty}, merged: true, equivalent_to_main: true,
                 env: { "TASK_RECORD_SLUG" => "t" }, task: "t" }
      print reclaim_verdict(record).inspect
    RUBY
  end

  # THE POSITIVE CONTROL. This guard's failure mode is BIMODAL: fail-open
  # destroys a live desk (the original incident), fail-CLOSED silently wedges the whole sweep.
  # Every other guard test here asserts a REFUSAL, so if the guard withheld EVERY desk the
  # suite would stay green while reclaim was silently dead. This is the FREE cell — the one
  # the asymmetry matrix never covered.
  def test_the_guard_still_frees_a_readable_unclaimed_desk
    assert_equal "[true, nil]", verdict_for(held: false, dirty: false),
                 "the guard must withhold only what it CANNOT verify — a desk it read and found " \
                 "unclaimed is still reclaimable, or the sweep is silently wedged"
  end

  # --- the held-desk PROSE must not invert under a substring test -------------------------
  #
  # The doctor/registry issue text for a held desk used to read "…; not a cleanup candidate".
  # bin/qa-intake joins the issue list into ONE STRING and tests `include?("cleanup
  # candidate")`, so the negation matched and the conductor's front door recommended
  # `remove … --yes` for a desk with a LIVE builder at it — the exact incident this guard
  # exists to prevent, re-entered through the one path that deliberately does not block.
  #
  # qa-intake now reads the structured verdict instead (pinned in qa_intake_command_test),
  # but the phrase stays OUT of the negative branch regardless. Prose that inverts its
  # meaning under a substring match is a landmine for the next consumer, and the answer this
  # message carries is consumed to DESTROY. Belt and braces: fix the reader, disarm the text.
  def test_the_held_desk_message_never_contains_the_phrase_cleanup_candidate
    source = File.read(BIN)
    held_line = source.lines.find { |line| line.include?("clean and landed on") }

    refute_nil held_line, "the held-desk doctor message vanished — did it get renamed?"
    refute_includes held_line, "cleanup candidate",
                    "the HELD-desk message must not contain the phrase 'cleanup candidate' in any " \
                    "form, negated or not: consumers substring-match this prose and a negation " \
                    "reads as an affirmation, which nominates an occupied desk for teardown"
    assert_includes held_line, "withheld from reclaim",
                    "the held-desk message must still say plainly that the desk is off-limits"
  end

  # --- 404 classification: only the API's OWN "task not found" means the task is gone ------
  #
  # bin/task renders every non-2xx as "<METHOD> <path> -> <code>: <body>", so matching the
  # STATUS alone accepts any 404 — including a Heroku ROUTER 404 (board renamed/deleted) or a
  # Rails ROUTE 404 (path moved, or a stale local board). Those are FAILED READS, and because
  # they are board-WIDE an over-broad match makes EVERY bound desk read free at once, silently
  # disarming the guard on the destroy path. Hence the checks below assert BOTH directions —
  # a test that only proves the happy 404 passes on the broken form too, which is exactly how
  # the `||` slipped through.
  def hold_for(stderr)
    run_in_script(<<~RUBY)
      def capture_status(*_cmd, **_kw); [false, "", #{stderr.inspect}]; end
      def command_env(*_a); {}; end
      record = { env: { "TASK_RECORD_SLUG" => "gone" }, task: "gone",
                 dir: Dir.pwd, app: { "slug" => "mcritchie-studio" } }
      print claim_hold(record).inspect
    RUBY
  end

  # POSITIVE: the board ANSWERED "there is no such task" → free, even on the destroy path.
  def test_a_real_task_404_is_free
    assert_equal "nil", hold_for("error: GET /api/v1/tasks/gone -> 404: task not found"),
                 "a deleted/renamed slug must not be withheld forever — the board answered"
  end

  # NEGATIVE CONTROLS — the tests that actually prove the fix. A 404 whose body is NOT the
  # API's "task not found" is a board we could NOT read, and must WITHHOLD on the destroy
  # path. Without these, the over-broad `||` form still passes.
  def test_a_router_404_withholds_and_does_not_read_as_free
    hold = hold_for("error: GET /api/v1/tasks/gone -> 404: <!DOCTYPE html><html><body>Not Found</body></html>")
    assert_match(/could not be read/, hold,
                 "a Heroku router 404 is a board-wide FAILED read — treating it as free would " \
                 "disarm the guard for EVERY bound desk at once")
  end

  def test_a_route_404_withholds_and_does_not_read_as_free
    hold = hold_for("error: GET /api/v1/tasks/gone -> 404: Not found")
    assert_match(/could not be read/, hold, "a route-level 404 (moved path / stale board) is a failed read")
  end

  def test_a_500_still_withholds
    hold = hold_for("error: GET /api/v1/tasks/gone -> 500: internal server error")
    assert_match(/could not be read/, hold, "the outage that motivated this guard is still withheld")
  end

  # --- exit-code classification: the guard reads bin/task's EXIT CODE first ----
  #
  # bin/task exits EXIT_TASK_NOT_FOUND (4) ONLY when the board positively answered
  # "there is no such task" — it verifies the HTTP 404 + the API's own body at the
  # source, where the response is still structured. fetch_task_record classifies on
  # that code, demoting the stringly stderr match above to a FALLBACK for an older
  # bin/task (which exits 1 for every failure). These cases run a REAL fake bin/task
  # executable through capture_status, so the whole seam — spawn, timeout plumbing,
  # exit status, classification — is exercised, not stubbed.
  def hold_for_fake_task_cli(script)
    run_in_script(<<~RUBY)
      def command_env(*_a); {}; end
      require "tmpdir"
      require "fileutils"
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "bin"))
        fake = File.join(dir, "bin", "task")
        File.write(fake, #{script.inspect})
        File.chmod(0o755, fake)
        record = { env: { "TASK_RECORD_SLUG" => "gone" }, task: "gone",
                   dir: dir, app: { "slug" => "mcritchie-studio" } }
        print claim_hold(record).inspect
      end
    RUBY
  end

  # POSITIVE: a new-style bin/task answers not-found by EXIT CODE alone. The stderr
  # deliberately does NOT contain "task not found", so only the code can free it —
  # this is the test that fails if the classification still rides the message.
  def test_exit_code_4_frees_the_desk_without_the_stderr_phrase
    script = "#!/bin/sh\necho 'error: GET /api/v1/tasks/gone -> 404: NOT_FOUND' >&2\nexit 4\n"
    assert_equal "nil", hold_for_fake_task_cli(script),
                 "exit 4 is the board's positive 'no such task' answer — the desk is free even when " \
                 "the stderr rendering changes (the stringly match is only a fallback now)"
  end

  # NEGATIVE: a new-style bin/task exiting 1 is a FAILED read (transport, 5xx,
  # router/route 404) — the outage must still withhold on the destroy path.
  def test_exit_code_1_transport_failure_still_withholds
    script = "#!/bin/sh\necho 'error: GET /api/v1/tasks/gone -> 500: internal server error' >&2\nexit 1\n"
    assert_match(/could not be read/, hold_for_fake_task_cli(script),
                 "exit 1 without the not-found stderr is an unreadable board — never the free bucket")
  end

  # FALLBACK: an old-style bin/task (exits 1 for EVERY failure, renders
  # "-> 404: task not found") must still classify as free — a worktree pinned to an
  # older branch keeps a working guard.
  def test_old_style_exit_1_with_the_stderr_phrase_still_frees
    script = "#!/bin/sh\necho 'error: GET /api/v1/tasks/gone -> 404: task not found' >&2\nexit 1\n"
    assert_equal "nil", hold_for_fake_task_cli(script),
                 "the stderr fallback for an older bin/task must keep freeing a genuinely deleted slug"
  end

  # The plumbing under the classification: capture_status must report the child's
  # exit code as its 4th element on BOTH lanes (plain and bounded), nil when the
  # child never ran or was killed — nil can never equal the not-found code, so an
  # unclassifiable exit always lands in the withheld bucket.
  def test_capture_status_reports_the_child_exit_code_on_both_lanes
    out = run_in_script(<<~RUBY)
      plain = capture_status("sh", "-c", "exit 7")
      bounded = capture_status("sh", "-c", "exit 7", timeout: 5)
      ok, _out, _err, code = capture_status("true")
      _t_ok, _t_out, _t_err, t_code = capture_status("sleep", "3", timeout: 1)
      print [plain[0], plain[3], bounded[0], bounded[3], ok, code, t_code].inspect
    RUBY
    assert_equal "[false, 7, false, 7, true, 0, nil]", out,
                 "exit codes must survive both capture lanes; a timeout has NO exit code (nil), " \
                 "which classifies as a failed read, never as not-found"
  end

  # --- the board read must be REALLY bounded ---------------------------------
  # Timeout.timeout around Open3.capture3 bounds NOTHING: capture3's ensure joins the wait
  # thread, which blocks until the child exits, swallowing the Timeout::Error (a 2s guard
  # around `sleep 6` returned after 6.01s on Ruby 3.3.11). A hung board would have stalled a
  # whole sweep while the code claimed to be bounded. The bound must KILL the child.
  #
  # Asserted by BEHAVIOUR, not wall-clock. The old guard measured `elapsed < 3` around a
  # SPAWNED subprocess — only 3x headroom, and spawn latency inflated ~2.75x under load, so
  # it red-failed a CORRECT implementation on a busy box. But asserting only the timeout
  # BRANCH is not enough: a no-op terminate_group STILL returns the timed-out verdict (the
  # unbounded popen3 ensure just waits the child out), so the read failing "timed out"
  # proves the branch, not the KILL. So force the kill to PROVE ITSELF: the child TRAPS
  # SIGTERM, so only terminate_group's escalation-to-KILL can stop it — and the escalation
  # runs its grace-poll, which calls the INJECTED sleeper. Reading the sleeper is thus a
  # deterministic witness of the kill (no wall-clock): with an injected clock the grace
  # deadline elapses at once, the poll fires once, and the KILL lands.
  #
  # The assertion, all four deterministic: the read FAILED (ok=false) through the timeout
  # branch (the "timed out" message only it emits), the escalation poll RAN (slept.any? —
  # the witness of the kill on a TERM-ignoring child), and it never slept beyond its 0.05s
  # quantum. Mutations each go RED: drop the bound (join without the timeout) -> child exits
  # naturally, ok:true; make terminate_group a no-op -> the child is never killed and the
  # poll never runs, slept.empty?; sleep past the quantum -> slept.max > 0.05.
  def test_capture_status_timeout_escalates_to_kill_a_term_ignoring_child
    out = run_in_script(<<~'RUBY')
      slept = []
      # An injected clock whose first read seeds the grace deadline and whose next read is
      # already past it, so terminate_group polls once (the witness) then escalates to KILL —
      # no real grace wait, no wall-clock in the assertion.
      ticks = [0.0, 0.01, 100.0]
      clock = -> { ticks.length > 1 ? ticks.shift : ticks.first }
      # `trap '' TERM` makes the child IGNORE SIGTERM: only the escalation KILL stops it, so a
      # no-op bound would sleep it out to natural exit and the poll (sleeper) would never run.
      ok, _out, err = capture_status("sh", "-c", "trap '' TERM; sleep 6", timeout: 1,
                                     clock: clock, sleeper: ->(s) { slept << s })
      print [ok, err.include?("timed out"), slept.any?, (slept.max || 0) <= 0.05].inspect
    RUBY
    assert_equal "[false, true, true, true]", out,
                 "a 1s bound around a TERM-ignoring `sleep 6` fails the read through the timeout branch AND " \
                 "reaches terminate_group's escalation KILL (its grace poll ran) — proof of the kill itself, " \
                 "within the 0.05s quantum, with no wall-clock assertion"
  end

  # --- integration: the REAL mcritchie config carries the reservation through
  #     the merge, and allocate_port honours it end-to-end ----------------------

  def test_mcritchie_config_reserves_3020_through_the_real_merge
    # This is the only test that resolves the REAL mcritchie-studio config via
    # app_for, which validates the repo dir exists (`abort "repo missing"`). When
    # this suite runs somewhere that checkout isn't at PROJECTS_DIR/mcritchie-studio
    # — e.g. studio-engine's consumer CI, where mcritchie-studio is cloned to a
    # different path — that abort otherwise false-fails an unrelated run. Guard it:
    # the subprocess reads the config directly (apps[...] doesn't abort; only
    # app_for does) and signals SKIP when the repo dir is absent.
    out = run_in_script(<<~RUBY)
      def allocated_ports(_a); (3001..3019).to_a; end
      def port_listening?(_p); false; end
      config = apps[ALIASES.fetch("mcritchie-studio", "mcritchie-studio")]
      if config.nil? || !Dir.exist?(config.fetch("repo"))
        print "SKIP"
      else
        app = app_for("mcritchie-studio") # real APP_OVERRIDES -> merge -> config
        print [app["reserved_ports"], allocate_port(app)].inspect
      end
    RUBY
    skip "mcritchie-studio checkout not present at PROJECTS_DIR/mcritchie-studio" if out == "SKIP"
    assert_equal "[[3020], 3021]", out, "rolio's 3020 is reserved in the real config and skipped"
  end

  def test_git_worktree_dirs_parses_porcelain_without_filter_map_dependency
    out = run_in_script(<<~RUBY)
      def capture_status(*)
        [true, "worktree /repo/main\\nHEAD abc123\\n\\nworktree /repo/.worktrees/task\\nHEAD def456\\n", ""]
      end
      def canonical_path(path); path; end
      print git_worktree_dirs("/repo").inspect
    RUBY
    assert_equal '["/repo/main", "/repo/.worktrees/task"]', out
  end

  # --- regression: the silent empty-output flake --------------------------------
  #
  # A subprocess that produces NO usable output must fail LOUD with its stderr
  # surfaced — it must never slip through as a bare `Actual: ""` (how the original
  # CI flake masqueraded, because the old helper discarded stderr + exit status).
  # We force that mode deterministically: a body that writes to stderr and exits
  # nonzero on every attempt. The old IO.popen(err: File::NULL) helper would return
  # "" silently (no raise) and fail THIS assertion; the hardened helper flunks with
  # the stderr included.
  def test_run_in_script_flunks_loudly_when_subprocess_yields_no_output
    error = assert_raises(Minitest::Assertion) do
      run_in_script("STDERR.puts 'forced-subprocess-failure'; exit 1")
    end
    assert_match(/forced-subprocess-failure/, error.message,
                 "the swallowed subprocess stderr must surface in the failure message")
    assert_match(/no usable output/, error.message)
  end

  # --- regression: finish --pr must stamp the created PR's URL on the task ------
  #
  # finish --pr opened the PR (gh prints the URL) but never wrote devops.pr_url,
  # so bin/dor-check's CI gate reported NO_PR until someone ran
  # `bin/task update --pr-url` by hand. The fix parses the URL from `gh pr create`
  # output and stamps it through the same best-effort `bin/task` board-write path
  # the handoff already uses — a board blip must never fail the finish.

  def test_pr_url_from_output_extracts_the_created_pr_url
    out = run_in_script(<<~RUBY)
      noisy = "Warning: 1 uncommitted change\\nhttps://github.com/amcritchie/mcritchie-studio/pull/999\\n"
      print [pr_url_from_output(noisy), pr_url_from_output("no url here")].inspect
    RUBY
    assert_equal '["https://github.com/amcritchie/mcritchie-studio/pull/999", nil]', out
  end

  def test_open_draft_pr_stamps_the_created_pr_url_on_the_bound_task
    out = run_in_script(<<~RUBY)
      def capture_status(*_cmd, chdir: nil, env: {})
        [true, "https://github.com/amcritchie/mcritchie-studio/pull/999\\n", ""]
      end
      def human_title(_task); "Finish stamps PR url"; end
      def pr_body(_record); "body"; end
      STAMPS = []
      def stamp_task_pr_url(slug, url); STAMPS << [slug, url]; true; end
      record = { env: { "TASK_RECORD_SLUG" => "finish-stamps-pr-url" },
                 base_branch: "release", branch: "feat/finish-stamps-pr-url" }
      open_draft_pr(record, "/tmp/wt", "finish-stamps-pr-url")
      print "STAMPED=" + STAMPS.inspect
    RUBY
    assert_match(
      'STAMPED=[["finish-stamps-pr-url", "https://github.com/amcritchie/mcritchie-studio/pull/999"]]',
      out,
      "the created PR URL must be stamped on the bound task record"
    )
  end

  def test_open_draft_pr_survives_a_failed_board_stamp
    # Best-effort guarantee: a failed stamp warns; the finish still completes and
    # the URL is still returned (the operator can stamp manually).
    out = run_in_script(<<~RUBY)
      def capture_status(*_cmd, chdir: nil, env: {})
        [true, "https://github.com/x/y/pull/1\\n", ""]
      end
      def human_title(_task); "t"; end
      def pr_body(_record); "b"; end
      def stamp_task_pr_url(_slug, _url); false; end
      url = open_draft_pr({ env: {}, base_branch: "release", branch: "b" }, "/tmp/wt", "t")
      print "RETURNED=" + url.to_s
    RUBY
    assert_match "RETURNED=https://github.com/x/y/pull/1", out
  end

  def test_stamp_task_pr_url_returns_false_on_a_board_blip_instead_of_raising
    out = run_in_script(<<~RUBY)
      def system(*_argv, **_opts); false; end
      $stderr.reopen(File::NULL) # the warn is expected; keep the child's stderr clean
      print stamp_task_pr_url("some-task", "https://github.com/x/y/pull/1").inspect
    RUBY
    assert_equal "false", out
  end

  # Integration: the stamp crosses the real process boundary through the task CLI
  # seam (`task_cli_path`), with the board mocked at the executable edge — a fake
  # `task` script records the argv it was invoked with.
  def test_stamp_task_pr_url_writes_through_the_task_cli_boundary
    out = run_in_script(<<~RUBY)
      require "tmpdir"
      DIR = Dir.mktmpdir
      ARGV_FILE = File.join(DIR, "argv")
      FAKE = File.join(DIR, "task")
      File.write(FAKE, "#!/bin/sh\\necho \\"$@\\" > \#{ARGV_FILE.inspect}\\n")
      File.chmod(0o755, FAKE)
      def task_cli_path; FAKE; end
      ok = stamp_task_pr_url("finish-stamps-pr-url", "https://github.com/x/y/pull/9")
      print [ok, File.read(ARGV_FILE).strip].inspect
    RUBY
    assert_equal '[true, "update finish-stamps-pr-url --pr-url https://github.com/x/y/pull/9"]', out
  end

  # Regression (build-assets-on-worktree-bringup): `new` provisions the isolated test DB
  # so a fresh worktree "runs bin/rails test out of the box" — but app/assets/builds/ is
  # GITIGNORED, so a virgin worktree carries no built CSS, and `db:test:prepare` does not
  # build it (tailwindcss-rails enhances `test:prepare`, falling back to db:test:prepare
  # only when test:prepare is undefined — it never is in a Rails app). Any run that passes
  # explicit test paths — `bin/agent-worktree test <app> <task> test/models/x_test.rb`, and
  # every bin/fast-check lane — makes Rails SKIP test:prepare (Rails::Command::TestCommand
  # only runs it `if self.args.none?(EXACT_TEST_ARGUMENT_PATTERN)`), so nothing ever built
  # the asset and every view-rendering test errored with `The asset "tailwind.css" is not
  # present in the asset pipeline`. Preparing the test env means the DB *and* the bundler
  # hook, in one boot.
  def test_prepare_test_env_runs_the_bundler_hook_alongside_the_db_prepare
    out = run_in_script(<<~RUBY)
      CALLS = []
      def sh(*cmd, chdir: nil, env: {}, allow_fail: false); CALLS << cmd; true; end
      def test_database_url(_values); "postgres://localhost/studio_test_wt"; end
      def write_test_env_local(*_args); nil; end
      prepare_test_env("/tmp/wt", { "slug" => "mcritchie-studio" }, {})
      print CALLS.inspect
    RUBY
    assert_equal '[["bin/rails", "db:test:prepare", "test:prepare"]]', out,
                 "bringup must prepare the test env in ONE boot: the isolated test DB AND Rails' " \
                 "test:prepare hook, which is what builds the gitignored bundled CSS"
  end

  # The asset build must NOT be gated on a DATABASE concern. A worktree with no derivable
  # test DB still renders views, and hanging the CSS build off `return unless
  # test_database_url` is precisely how the missing-asset bug creeps back in: no test DB →
  # skip db:test:prepare ONLY, and still build.
  def test_prepare_test_env_builds_assets_even_with_no_test_database
    out = run_in_script(<<~RUBY)
      CALLS = []
      def sh(*cmd, chdir: nil, env: {}, allow_fail: false); CALLS << cmd; true; end
      def test_database_url(_values); nil; end
      def write_test_env_local(*_args); raise "must not write .env.test.local without a test DB"; end
      prepare_test_env("/tmp/wt", { "slug" => "mcritchie-studio" }, {})
      print CALLS.inspect
    RUBY
    assert_equal '[["bin/rails", "test:prepare"]]', out,
                 "no test DB skips db:test:prepare ONLY — the bundled-asset build still runs"
  end
end
