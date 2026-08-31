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
require "fileutils"
require "json"
require "open3"
require "time" # Time#iso8601 — the claim-lease expiry format the reclaim guard reads
require "tmpdir"
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
  # `env:` merges OVER the neutralized base, for the checks that must control where
  # the script believes the projects root is (PROJECTS_DIR is read into a constant at
  # load, so it cannot be stubbed after the fact — it has to be in the child's env).
  def run_in_script(body, env: {})
    script = "load #{BIN.inspect}\n#{body}"
    last = nil
    SUBPROCESS_ATTEMPTS.times do
      # SessionEnv.neutralized: the child loads bin/agent-worktree, which resolves
      # session identity — it must name NO session (test/support/session_env.rb).
      out, err, status = Open3.capture3(SessionEnv.neutralized.merge(env), "ruby", "-e", script)
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

  # The CLAIM-focused checks drive records with no desk ON DISK, so the desk channel
  # (below) would withhold every one of them for "could not be dated" and they would
  # stop testing the thing they are named for. Stub the desk to a long-abandoned,
  # quiet one so the claim decision is what decides here. The desk decision has its
  # own checks below, and the REAL filesystem path is driven end to end against a
  # staged git worktree in test/commands/agent_worktree_test.rb.
  ABANDONED_DESK = <<~RUBY
    def desk_age_seconds(_r); ClaimLease::DESK_IDLE_SECONDS * 10; end
    def desk_touched_recently?(_r); false; end
  RUBY

  def verdict_for(held:, dirty:)
    devops = held ? %({ "claimed_session" => "s", "claim_expires_at" => #{(Time.now + 110).utc.iso8601.inspect} }) : "{}"
    run_in_script(<<~RUBY)
      #{ABANDONED_DESK}
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

  # --- reclaim guard: the DESK channel (fresh-desk fix) ------------------------------------
  #
  # THE HOLE THE CLAIM CHANNEL COULD NOT COVER. On 2026-08-13 a `cleanup --reclaim` sweep
  # destroyed a desk a builder had just created and was working in. Nothing malfunctioned:
  # a brand-new worktree is CLEAN (nobody has committed yet) and carries NOTHING ahead of
  # its base, so cleanup_ready? passes on it VACUOUSLY — a fresh desk and a fast-forward-
  # merged one are byte-identical to git. And the claim above cannot rescue it, because the
  # desks most at risk are exactly the ones with no live claim to read: inside the `new` →
  # `bind-task` → `move building` window, or half-allocated by a failed bind, or simply
  # between lease renewals.
  #
  # So every check below runs with NO claim on the record (`{}` devops). The claim channel
  # says "free" for all of them; what is under test is whether the DESK channel still holds
  # them back — and, in the control, still lets a genuinely abandoned one go.
  #
  # The two filesystem seams are stubbed here so every combination is reachable in a unit;
  # the real mtimes and the real `.git` marker are driven end to end against a staged git
  # worktree in test/commands/agent_worktree_test.rb.

  def desk_verdict(age:, touched:, task_json: %({ "metadata" => { "devops" => {} } }), env: %({ "TASK_RECORD_SLUG" => "t" }))
    run_in_script(<<~RUBY)
      def desk_age_seconds(_r); #{age}; end
      def desk_touched_recently?(_r); #{touched.inspect}; end
      def task_record_for_pr(_r, fresh: false); #{task_json}; end
      record = { dirty: false, merged: true, equivalent_to_main: true,
                 env: #{env}, task: "t", dir: "/repo/.worktrees/t" }
      print reclaim_verdict(record).inspect
    RUBY
  end

  # THE INCIDENT ITSELF. Clean, landed on base, no claim — and four minutes old.
  def test_a_freshly_created_desk_is_withheld_however_git_identical_to_a_merged_one
    out = desk_verdict(age: 240, touched: true)

    assert_match(/\A\[false, "the desk is only/, out,
                 "a desk minutes old must never be a reclaim candidate: it is git-identical to a " \
                 "merged one, and its builder's uncommitted work is what a teardown destroys")
    assert_match(/younger than the/, out, "the hold names the window it is measured against")
  end

  # AGE IS AN INDEPENDENT CHANNEL, not a restatement of the mtimes. A fresh checkout
  # normally answers `touched => true` on its own creation, so the two agree — but they
  # agree by coincidence, and this pins the floor for the case where they do not: a desk
  # whose contents the mtime walk cannot see (a walk that hit its budget, a checkout whose
  # files all sit under pruned paths, a half-allocated desk with almost nothing in it, a
  # tree restored with backdated timestamps). Age needs no walk and no prune list.
  def test_the_age_floor_holds_a_new_desk_even_when_the_mtime_walk_reports_untouched
    out = desk_verdict(age: 240, touched: false)

    assert_match(/\A\[false, "the desk is only/, out,
                 "the floor must hold on its own — if it only ever fires alongside the mtimes, " \
                 "it is decoration and the desk rides on one channel, not two")
  end

  # AGE IS A FLOOR, NOT THE WHOLE ANSWER. An hour-and-a-half-old desk being edited right
  # now is live, and an age threshold alone would have released it.
  def test_an_aged_desk_being_edited_right_now_is_withheld
    out = desk_verdict(age: 6 * 3_600, touched: true)

    assert_match(/\A\[false, "the desk was written to within the last/, out,
                 "past the age floor the mtimes decide, and a desk being written to is in use")
    assert_match(/uncommitted work/, out, "the hold says what a teardown would actually cost")
  end

  # A CERT WRITES NOTHING INTO ITS DESK for up to the measured 94-minute p99, so an aged,
  # quiet desk mid-gate looks exactly like a walked-away one to age and mtimes alike. This
  # is why "just add an age threshold" was not the fix.
  def test_an_aged_quiet_desk_with_a_gate_in_flight_is_withheld
    out = desk_verdict(age: 6 * 3_600, touched: false,
                       task_json: %({ "holder_gate_in_flight" => true, "metadata" => { "devops" => {} } }))

    assert_match(/\A\[false, "a gate the holder may have opened is still running/, out,
                 "a holder mid-cert writes nothing into the desk — reclaiming it destroys live work")
  end

  # The gate channel is HOLDER-SCOPED, and falls back to the task-wide fact on an older
  # board that publishes no holder key. The fallback is the protective direction: it counts
  # everyone's gate, so it can only keep a desk, never free one.
  def test_an_older_board_without_holder_keys_falls_back_to_the_task_wide_gate
    out = desk_verdict(age: 6 * 3_600, touched: false,
                       task_json: %({ "gate_in_flight" => true, "metadata" => { "devops" => {} } }))

    assert_match(/\A\[false, "a gate the holder may have opened is still running/, out,
                 "a board too old to publish holder-scoped facts must degrade to the protective twin")
  end

  # A task parked on the operator (`--approval waiting`) is not abandoned; its agent is
  # deliberately doing nothing, which is exactly what an idle desk looks like.
  def test_a_desk_whose_task_waits_on_the_operator_is_withheld
    out = desk_verdict(age: 6 * 3_600, touched: false,
                       task_json: %({ "metadata" => { "devops" => { "approval_status" => "waiting" } } }))

    assert_match(/\A\[false, "the bound task is waiting on the operator/, out)
  end

  def test_a_desk_whose_task_landed_a_recent_artifact_is_withheld
    out = desk_verdict(age: 6 * 3_600, touched: false,
                       task_json: %({ "holder_liveness_seconds_ago" => 90, "metadata" => { "devops" => {} } }))

    assert_match(/\A\[false, "the bound task landed a durable artifact/, out,
                 "a holder working through the board rather than the filesystem is still working")
  end

  # UNKNOWNS PROTECT, both of them, and they say so honestly — "we could not check" is
  # never dressed up as "somebody is here".
  def test_an_undatable_desk_is_withheld_rather_than_guessed_at
    out = desk_verdict(age: "nil", touched: false)

    assert_match(/\A\[false, "the desk could not be dated/, out)
    refute_match(/somebody is working in it/, out,
                 "an undatable desk is an unknown, not a confirmed worker — do not misattribute one")
  end

  def test_a_desk_whose_files_could_not_be_read_is_withheld_rather_than_guessed_at
    out = desk_verdict(age: 6 * 3_600, touched: nil)

    assert_match(/\A\[false, "the desk's files could not be read/, out)
    refute_match(/somebody is working in it/, out)
  end

  # THE HALF-ALLOCATED DESK — worktree created, stack and bind-task failed, so there is no
  # task and no claim to read at all. The Redis band ceiling produced several of these on
  # the incident day. The claim channel is FORCED to fail open on them (you cannot look up
  # what you cannot identify), which is precisely why the desk channel must not.
  def test_an_unbound_half_allocated_desk_is_still_protected_while_it_is_fresh
    out = desk_verdict(age: 300, touched: true, env: "{}")

    assert_match(/\A\[false, "the desk is only/, out,
                 "the desk we actually lost had no task to look up — age and mtimes are all it has")
  end

  # ...AND IS RELEASED ONCE IT IS COLD. A failed allocation that nobody came back for is
  # exactly the litter reclaim exists to sweep; protecting it forever would trade one leak
  # for another.
  def test_an_unbound_half_allocated_desk_is_released_once_it_goes_cold
    assert_equal "[true, nil]", desk_verdict(age: 6 * 3_600, touched: false, env: "{}"),
                 "a cold, unclaimed, unbound desk is litter — the sweep must still collect it"
  end

  # THE POSITIVE CONTROL for this channel. Its failure mode is bimodal: fail-open destroys
  # a live desk, fail-CLOSED silently wedges the sweep and every check above would stay
  # green while nothing was ever reclaimed again. An old, quiet, unclaimed desk must go.
  def test_the_desk_channel_still_releases_an_old_quiet_abandoned_desk
    assert_equal "[true, nil]", desk_verdict(age: 6 * 3_600, touched: false),
                 "a guard that withholds every desk is a wedge, not a fix — the abandoned ones " \
                 "must still be torn down"
  end

  # --- reclaim guard: the _ship/_gate SHIP-WORKSPACE exclusion (release-conductor-claims) ---
  # `bin/release` moved OFF the shared `avi` shift and ONTO the per-release
  # ReleaseConductorClaim, so the shift no longer excludes clean-up from a live release.
  # These re-enforce "never reclaim _ship/_gate while a release conductor is working" via
  # that claim: withhold the fixed-path ship/cert workspaces while ANY role's claim is live,
  # reclaim them when none, and WITHHOLD on can't-tell (a destroy path — a release MIGHT be
  # live). release_claim_liveness is stubbed here; its board read is covered by the CLI +
  # controller tests. Only _ship/_gate are guarded — a task desk ignores the release claim.

  def ship_hold(liveness, task)
    run_in_script(<<~RUBY)
      def release_claim_liveness(fresh: false); #{liveness.inspect}; end
      print claim_hold({ task: #{task.inspect}, dir: "/repo/.worktrees/#{task}", env: {} }).inspect
    RUBY
  end

  def test_ship_workspace_withheld_while_a_release_claim_is_live
    %w[_ship _gate].each do |ws|
      out = ship_hold(:live, ws)
      refute_equal "nil", out, "#{ws} must be WITHHELD while a live release claim exists (a prepare or ship in progress)"
      assert_match(/a release is live/, out, "#{ws} names the reason: a release conductor is live")
      assert_match(/assembler\/deployer/, out, "the reason names BOTH roles it asked about")
    end
  end

  def test_ship_workspace_reclaimable_when_no_release_claim_is_live
    %w[_ship _gate].each do |ws|
      assert_equal "nil", ship_hold(:none, ws),
                   "#{ws} is a normal reclaim candidate when the board says no release conductor is live"
    end
  end

  def test_ship_workspace_withheld_when_the_release_claim_read_fails
    out = ship_hold(:unknown, "_ship")
    assert_match(/could not check for a live release/, out,
                 "an unreadable release-claim read WITHHOLDS _ship (fail-closed on a destroy path — a release MIGHT be live)")
    assert_match(/withholding/, out)
  end

  def test_a_task_desk_is_unaffected_by_the_release_claim
    # Only the fixed-path _ship/_gate are guarded by the release claim; a normal task desk
    # must NOT consult it (that would wedge task reclaim on every live release).
    out = run_in_script(<<~RUBY)
      def release_claim_liveness(fresh: false); :live; end
      def task_record_for_pr(_r, fresh: false); { "metadata" => { "devops" => {} } }; end
      print claim_hold({ task: "t", dir: "/repo/.worktrees/t", env: { "TASK_RECORD_SLUG" => "t" } }).inspect
    RUBY
    assert_equal "nil", out, "a task desk is reclaimable regardless of a live release — the guard is _ship/_gate only"
  end

  def test_reclaim_verdict_withholds_ship_workspace_during_a_live_release
    out = run_in_script(<<~RUBY)
      def release_claim_liveness(fresh: false); :live; end
      record = { task: "_ship", dir: "/repo/.worktrees/_ship", dirty: false, merged: true,
                 equivalent_to_main: true, env: {} }
      print reclaim_verdict(record).inspect
    RUBY
    assert_match(/\A\[false, ".*release is live/, out,
                 "a live release withholds _ship from reclaim through the ONE decision every destroy path routes through")
  end

  def test_reclaim_verdict_reclaims_ship_workspace_when_no_release_is_live
    out = run_in_script(<<~RUBY)
      #{ABANDONED_DESK}
      def release_claim_liveness(fresh: false); :none; end
      record = { task: "_gate", dir: "/repo/.worktrees/_gate", dirty: false, merged: true,
                 equivalent_to_main: true, env: {} }
      print reclaim_verdict(record).inspect
    RUBY
    assert_equal "[true, nil]", out, "with no live release, _gate is a normal reclaim candidate (bin/release recreates it)"
  end

  # A `_gate` workspace mid-cert is a WORKING desk even with no release claim: the
  # cert checks out into it and then writes nothing for up to 94 minutes. The desk
  # channel covers that on the same evidence it covers a task desk with.
  def test_a_ship_workspace_being_written_to_is_withheld_even_with_no_release_claim
    out = run_in_script(<<~RUBY)
      def desk_age_seconds(_r); ClaimLease::DESK_IDLE_SECONDS * 10; end
      def desk_touched_recently?(_r); true; end
      def release_claim_liveness(fresh: false); :none; end
      record = { task: "_gate", dir: "/repo/.worktrees/_gate", dirty: false, merged: true,
                 equivalent_to_main: true, env: {} }
      print reclaim_verdict(record).inspect
    RUBY
    assert_match(/\A\[false, "the desk was written to/, out,
                 "a cert workspace being written into is in use, release claim or no release claim")
  end

  # --- THE 2026-08-14 REGRESSION: the guard asked ONE role of a TWO-role lifecycle -------
  #
  # `_ship` is not "the tree the deploy works in". `bin/release prepare` — the ASSEMBLER,
  # Avi's qa-release sweep — merges release branches forward and runs `bundle lock` for
  # every consumer inside the very same workspace. While that ran, the deployer claim was
  # legitimately free, so a deployer-only check answered :none and a `cleanup --reclaim`
  # listed BOTH repos' `_ship` desks as "safe: merged on origin/accepted (clean)".
  #
  # This drives the REAL compute_release_claim_liveness with only the ASSEMBLER role live
  # (the CLI answers exit 0 for assembler, exit 3 — "no live claim" — for deployer). A guard
  # that asks only about the deployer reads :none here and nominates the workspace.
  def test_release_liveness_is_live_when_only_the_assembler_role_is_held
    out = run_in_script(<<~RUBY)
      def File.exist?(_p); true; end                       # the CLI is present
      def capture_status(*args, **_kw)
        role = args[args.index("--role") + 1]
        [role == "assembler", "", "", role == "assembler" ? 0 : 3]
      end
      print compute_release_claim_liveness.inspect
    RUBY
    assert_equal ":live", out,
                 "a live PREPARE pins _ship exactly as a live ship does; asking only the deployer " \
                 "role is a guard that is absent half the time"
  end

  def test_release_liveness_is_live_when_only_the_deployer_role_is_held
    out = run_in_script(<<~RUBY)
      def File.exist?(_p); true; end
      def capture_status(*args, **_kw)
        role = args[args.index("--role") + 1]
        [role == "deployer", "", "", role == "deployer" ? 0 : 3]
      end
      print compute_release_claim_liveness.inspect
    RUBY
    assert_equal ":live", out, "the original ship case must keep working"
  end

  # THE POSITIVE CONTROL for the role sweep: with every role answering "no live claim",
  # the workspaces are ordinary candidates. Without this, a guard that simply returned
  # :live would pass both checks above and wedge every release workspace forever.
  def test_release_liveness_is_none_only_when_every_role_answers_none
    out = run_in_script(<<~RUBY)
      def File.exist?(_p); true; end
      def capture_status(*_args, **_kw); [false, "", "", 3]; end
      print compute_release_claim_liveness.inspect
    RUBY
    assert_equal ":none", out, "all roles free ⇒ _ship/_gate are reclaimable litter"
  end

  # PURE precedence, stated as a matrix so the safety order cannot drift into an
  # arithmetic one: any live holds, any unknown holds, empty is unknown.
  def test_combine_claim_liveness_precedence
    out = run_in_script(<<~RUBY)
      print [
        combine_claim_liveness([:none, :live]),
        combine_claim_liveness([:none, :unknown]),
        combine_claim_liveness([:unknown, :live]),
        combine_claim_liveness([:none, :none]),
        combine_claim_liveness([])
      ].inspect
    RUBY
    assert_equal "[:live, :unknown, :live, :none, :unknown]", out,
                 "one live role withholds; one unreadable role withholds even beside a `none`; " \
                 "only an all-none answer frees, and asking nothing is not an answer"
  end

  # --- reclaim TOCTOU: fresh: true RE-READS the release claim under-lock -----------------
  #
  # release_claim_liveness memoizes @release_claim_liveness PROCESS-WIDE (one board read per
  # command). The reclaim under-lock re-verify (reclaim_verdict → claim_hold, fresh: true)
  # exists to catch a claim taken AFTER the candidate list was selected — but the
  # ship-workspace path used to IGNORE `fresh:`, so a release STARTING mid `cleanup
  # --reclaim --yes` loop was read from the memoized stale :none and its `_ship`/`_gate`
  # reclaimed, breaking the in-flight deploy. The build-claim guard already bypasses its own
  # memo on the re-verify (task_record_for_pr fresh:); this pins the SAME parity here.
  #
  # The EFFECT under test — not a branch, not "a method was called": with the memo seeded
  # :none and the LIVE state then changed to a held release claim, a non-fresh re-check
  # STILL reads the stale :none (reclaimable), while fresh: true RE-READS and returns the
  # CURRENT held value (WITHHELD). compute_release_claim_liveness is stubbed to a mutable
  # state so the memo/bypass distinction is observable through the REAL memoization logic.
  def test_reclaim_toctou_fresh_reverify_rereads_the_live_release_claim
    out = run_in_script(<<~RUBY)
      $live = :none
      def compute_release_claim_liveness; $live; end
      rec = { task: "_ship", dir: "/repo/.worktrees/_ship", env: {} }
      seeded = release_claim_liveness               # memoizes the stale :none from selection
      $live  = :live                                # a release STARTS after the list was picked
      stale  = claim_hold(rec.dup)                  # non-fresh → memoized :none → reclaimable (nil)
      fresh  = claim_hold(rec.dup, fresh: true)     # under-lock re-verify → MUST re-read → :live → withhold
      print [seeded, stale.nil?, fresh].inspect
    RUBY
    assert_match(/\A\[:none, true, ".*release is live/, out,
                 "fresh: true RE-READS the release claim and returns the CURRENT held value (WITHHELD), " \
                 "even though the process-wide memo was seeded :none and a non-fresh re-check still reads that stale :none")
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

  # --- reclaim guard: the PR channel (open, unmerged work is not litter) ------------------
  #
  # THE PROPERTY: a desk whose branch still carries an OPEN, UNMERGED pull request is
  # withheld, however finished it looks to git. Git-eligibility asks whether the CONTENT is
  # represented on the base; a branch whose diff against the base is empty (the base moved
  # on, an equivalent change landed another way) satisfies that while its PR is still open
  # and a reviewer is still working it.
  #
  # The checks below drive the PURE decision so every cell of the matrix is reachable —
  # including the two that are not about GitHub at all: when gh cannot be asked, the BOARD
  # decides, because a task carrying a pr_url with no merged stamp is unlanded work.

  def pr_reason(gh_status, pr_ref: "41", board_pr_url: nil, board_merged: false)
    run_in_script(<<~RUBY)
      print pr_hold_reason(gh_status: #{gh_status.inspect}, pr_ref: #{pr_ref.inspect},
                           branch: "feat/x", board_pr_url: #{board_pr_url.inspect},
                           board_merged: #{board_merged.inspect}).inspect
    RUBY
  end

  def test_an_open_unmerged_pr_withholds_the_desk
    out = pr_reason(:open)

    assert_match(/OPEN, unmerged pull request \(#41\)/, out,
                 "an open PR is live work — the sweep must refuse the desk and name the PR")
    assert_match(/deletes that local branch/, out, "the reason states what a teardown would cost")
  end

  # THE POSITIVE CONTROL. This guard's failure mode is bimodal: fail-open strands live
  # review work, fail-closed wedges the sweep so nothing is ever reclaimed again. GitHub
  # answering "no open PR" must free the desk.
  def test_no_open_pr_frees_the_desk
    assert_equal "nil", pr_reason(:none, pr_ref: nil),
                 "gh answered: nothing is open on this branch — the desk is ordinary litter"
  end

  # gh missing/failing is not an answer, so the board is asked instead.
  def test_an_unreachable_gh_withholds_a_desk_the_board_calls_unlanded
    out = pr_reason(:unavailable, pr_ref: nil, board_pr_url: "https://github.com/x/y/pull/41")

    assert_match(/could not ask GitHub/, out, "the hold says plainly that the check did not happen")
    assert_match(/no merged stamp/, out, "and names the board evidence it fell back to")
  end

  def test_an_unreachable_gh_frees_a_desk_whose_task_landed
    assert_equal "nil",
                 pr_reason(:unavailable, pr_ref: nil, board_pr_url: "https://github.com/x/y/pull/41",
                           board_merged: true),
                 "a merged stamp is independent evidence the work landed — do not wedge on it"
  end

  def test_an_unreachable_gh_frees_a_desk_with_no_pr_at_all
    assert_equal "nil", pr_reason(:unavailable, pr_ref: nil),
                 "withholding every desk on a machine without gh would wedge the sweep permanently"
  end

  # THE WHOLE DECISION, end to end: the same abandoned, diff-empty desk every other control
  # frees is WITHHELD once its branch carries an open PR — and freed again when it does not.
  # Asserting both cells is the point: a guard that always withheld would pass the first.
  def verdict_with_open_pr(pr_status)
    run_in_script(<<~RUBY)
      #{ABANDONED_DESK}
      def open_pr_for_branch(_r); #{pr_status}; end
      def task_record_for_pr(_r, fresh: false); { "metadata" => { "devops" => {} } }; end
      record = { task: "t", dir: "/repo/.worktrees/t", branch: "feat/t", dirty: false,
                 merged: false, equivalent_to_main: true, env: { "TASK_RECORD_SLUG" => "t" },
                 base_ref: "origin/accepted" }
      print reclaim_verdict(record).inspect
    RUBY
  end

  def test_reclaim_verdict_withholds_an_abandoned_desk_whose_pr_is_still_open
    assert_match(/\A\[false, "an OPEN, unmerged pull request/, verdict_with_open_pr("[:open, \"41\"]"),
                 "clean + diff-empty + long abandoned is NOT enough: the PR is the work, and it is open")
  end

  def test_reclaim_verdict_frees_the_same_desk_once_nothing_is_open
    assert_equal "[true, nil]", verdict_with_open_pr("[:none, nil]"),
                 "the control: with no open PR the identical desk is still reclaimable litter"
  end

  # --- reclaim guard: the REVIEW channel (somebody else's session is AT this desk) --------
  #
  # A reviewer works the builder's desk without ever taking the BUILD claim, and mostly
  # READS — so the claim channel sees nothing and the desk's mtimes stay quiet. On
  # 2026-08-14 a sweep nominated a desk another live session was reviewing. The board
  # publishes `review_in_progress`; positive-signal only, so an older board that cannot
  # answer does not re-decide the unreadable-board case claim_hold already owns.
  def verdict_with_review(task_json)
    run_in_script(<<~RUBY)
      #{ABANDONED_DESK}
      def open_pr_for_branch(_r); [:none, nil]; end
      def task_record_for_pr(_r, fresh: false); #{task_json}; end
      record = { task: "t", dir: "/repo/.worktrees/t", branch: "feat/t", dirty: false,
                 merged: true, equivalent_to_main: true, env: { "TASK_RECORD_SLUG" => "t" },
                 base_ref: "origin/accepted" }
      print reclaim_verdict(record).inspect
    RUBY
  end

  def test_a_desk_under_live_review_is_withheld
    out = verdict_with_review(%({ "review_in_progress" => true, "metadata" => { "devops" => {} } }))

    assert_match(/\A\[false, "a review is in progress/, out,
                 "a reviewer holds no build claim and writes nothing — the board is the only " \
                 "channel that can see them")
  end

  def test_a_desk_whose_review_has_finished_is_freed
    assert_equal "[true, nil]",
                 verdict_with_review(%({ "review_in_progress" => false, "metadata" => { "devops" => {} } })),
                 "the control: review over, desk quiet, nothing open — ordinary litter"
  end

  # --- the RATIONALE: every nomination explains itself ------------------------------------
  #
  # "safe: merged on origin/accepted (clean)" is a GIT fact, and it was true of all three
  # load-bearing desks the 08-14 sweep nominated. The rationale states what each CHANNEL
  # asked and answered, so a blind channel is legible in the dry run and in the ledger row
  # months later.
  def test_a_free_desk_carries_a_rationale_naming_every_channel
    out = run_in_script(<<~RUBY)
      #{ABANDONED_DESK}
      def open_pr_for_branch(_r); [:none, nil]; end
      def task_record_for_pr(_r, fresh: false); { "review_in_progress" => false, "metadata" => { "devops" => {} } }; end
      record = { task: "t", dir: "/repo/.worktrees/t", branch: "feat/t", dirty: false,
                 merged: true, equivalent_to_main: true, env: { "TASK_RECORD_SLUG" => "t" },
                 base_ref: "origin/accepted" }
      print reclaim_evidence(record)[:rationale]
    RUBY

    assert_match(/merged into origin\/accepted, tree clean/, out, "the git fact")
    assert_match(/no open PR for feat\/t \(GitHub asked\)/, out, "the PR channel, and that it was actually asked")
    assert_match(/no live build claim on t/, out, "the claim channel")
    assert_match(/no review in progress/, out, "the review channel")
    assert_match(/desk idle/, out, "the desk channel")
  end

  # A WITHHELD desk gets no rationale — it gets the hold. An explanation that survived the
  # refusal would read as a clearance in the ledger.
  def test_a_withheld_desk_has_no_rationale
    out = run_in_script(<<~RUBY)
      #{ABANDONED_DESK}
      def open_pr_for_branch(_r); [:open, "7"]; end
      def task_record_for_pr(_r, fresh: false); { "metadata" => { "devops" => {} } }; end
      record = { task: "t", dir: "/repo/.worktrees/t", branch: "feat/t", dirty: false,
                 merged: true, equivalent_to_main: true, env: { "TASK_RECORD_SLUG" => "t" },
                 base_ref: "origin/accepted" }
      e = reclaim_evidence(record)
      print [e[:free], e[:rationale].nil?, e[:hold].to_s[0, 12]].inspect
    RUBY

    assert_equal %([false, true, "an OPEN, unm"]), out,
                 "a refusal carries the reason, never a clearance"
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
  # Asserted by BEHAVIOUR, not wall-clock — and the behaviour is the KILL ITSELF, not a
  # proxy for it. The old guard measured `elapsed < 3` around a SPAWNED subprocess (3x
  # headroom, spawn latency inflated ~2.75x under load -> red on a busy box). But observing
  # the timeout BRANCH is not enough (a no-op terminate_group STILL returns the timed-out
  # verdict — the unbounded popen3 ensure just waits the child out), and observing the grace
  # POLL is not enough either (a run that TERMs and polls but never sends the KILL still ran
  # the poll). So the child itself reports whether it was killed: it IGNORES SIGTERM and,
  # only if it SURVIVES its sleep, writes a marker on natural exit. The marker's ABSENCE is
  # the witness — the child was stopped before it could finish, which on a TERM-ignoring
  # child ONLY the escalation KILL can do.
  #
  # An injected clock elapses the grace deadline at once, so the correct path polls once
  # then KILLs and returns fast — no wall-clock. The assertion: the read FAILED (ok=false)
  # through the timeout branch, the marker is ABSENT (killed, not waited out), and
  # terminate_group never slept beyond its 0.05s quantum. Every mutation goes RED: drop the
  # bound (join without the timeout) -> ok:true; remove ONLY the escalation KILL (keep
  # TERM+poll) -> the child sleeps out and writes the marker -> present; no-op terminate ->
  # present too; sleep past the quantum -> slept.max > 0.05.
  def test_capture_status_timeout_actually_kills_the_child
    out = run_in_script(<<~'RUBY')
      require "tmpdir"
      Dir.mktmpdir do |dir|
        marker = File.join(dir, "child-finished")
        slept = []
        ticks = [0.0, 0.01, 100.0] # seed the grace deadline, then jump past it: one poll, then KILL
        clock = -> { ticks.length > 1 ? ticks.shift : ticks.first }
        # `trap '' TERM` -> the child IGNORES SIGTERM; it writes the marker ONLY if it lives
        # through `sleep 6` to natural exit. Only the escalation KILL stops it first.
        ok, _out, err = capture_status("sh", "-c", "trap '' TERM; sleep 6; : > #{marker}", timeout: 1,
                                       clock: clock, sleeper: ->(s) { slept << s })
        print [ok, err.include?("timed out"), File.exist?(marker), (slept.max || 0) <= 0.05].inspect
      end
    RUBY
    assert_equal "[false, true, false, true]", out,
                 "a 1s bound around a TERM-ignoring child must KILL it before it can finish its sleep — the " \
                 "marker it writes only on natural exit is ABSENT — through the timeout branch, within the " \
                 "0.05s grace quantum, with no wall-clock assertion"
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
      noisy = "Warning: 1 uncommitted change\\nhttps://github.com/McRitchie-Studio/mcritchie-studio/pull/999\\n"
      print [pr_url_from_output(noisy), pr_url_from_output("no url here")].inspect
    RUBY
    assert_equal '["https://github.com/McRitchie-Studio/mcritchie-studio/pull/999", nil]', out
  end

  def test_open_draft_pr_stamps_the_created_pr_url_on_the_bound_task
    out = run_in_script(<<~RUBY)
      def capture_status(*_cmd, chdir: nil, env: {})
        [true, "https://github.com/McRitchie-Studio/mcritchie-studio/pull/999\\n", ""]
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
      'STAMPED=[["finish-stamps-pr-url", "https://github.com/McRitchie-Studio/mcritchie-studio/pull/999"]]',
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

  # --- sweep coverage: every worktree tree on disk, not just the registry ------
  #
  # The sweep enumerated desks from config/satellites.yml, which registers satellite
  # APPS (navbar, SSO role, ecosystem-build). Repos that carry worktrees but are not
  # satellites — the gem/library repos above all — were therefore invisible to it, and
  # `cleanup --reclaim studio-engine` answered "unknown app". Not a slow sweep: NO
  # sweep, silently. studio-engine had accumulated 64 unswept desks, more than any
  # registered app, while the registered ones looked tidy.
  #
  # The fix is NOT to add those slugs to satellites.yml — that file drives the navbar,
  # SSO roles and ecosystem-build, so registering a repo there is a product decision.
  # Coverage is derived from what has .worktrees/ ON DISK.
  def test_stack_records_covers_a_worktree_tree_missing_from_the_registry
    Dir.mktmpdir do |root|
      # studio-engine is deliberately NOT a satellite: it is a gem, with no port and
      # no stack. It still collects desks.
      FileUtils.mkdir_p(File.join(root, "studio-engine", ".worktrees", "some-desk"))
      FileUtils.mkdir_p(File.join(root, "mcritchie-studio", ".worktrees", "hub-desk"))

      out = run_in_script(<<~RUBY, env: { "PROJECTS_DIR" => root })
        # Only the enumeration is under test; stack_record reads .env files we have
        # not written, so collapse it to the one field the assertion needs.
        def stack_record(_app, dir); { dir: dir }; end
        print stack_records(nil).map { |r| r[:dir] }.sort.inspect
      RUBY

      assert_includes out, "studio-engine/.worktrees/some-desk",
                      "a repo with desks on disk must be swept even when it is not a registered app — " \
                      "this is the gap that let 64 studio-engine desks accumulate unswept"
      assert_includes out, "mcritchie-studio/.worktrees/hub-desk",
                      "control: the registered app is still enumerated"
    end
  end

  # --- sweep scale: board reads must not scale with desk count ----------------
  #
  # reclaim_evidence resolves the build claim per desk, and task_record_for_pr spawns
  # `bin/task show <slug> --json` — one subprocess AND one HTTPS round-trip EACH. At 141
  # desks the full-suite scan ran past ten minutes at 0% CPU and never emitted a single
  # candidate; the same sweep scoped to one repo finished in 1-3 minutes.
  #
  # Parallelising is the WRONG fix and the file already says why: the board 500s under
  # Postgres connection pressure during heavy parallel devops, and mass-reclaim is
  # CORRELATED with that pressure, not independent of it. So the reads are batched
  # instead — one board read for all bound slugs, then decide locally.
  #
  # The property asserted is the one that matters and survives a change of mechanism:
  # resolving N bound desks does not cost N board reads.
  # A payload shaped like the one the API SHOW serves — carrying the derived fields
  # every hold channel reads. Anything less must not reach the cache.
  def self.show_shaped(slug)
    { "slug" => slug, "stage" => "building", "metadata" => {}, "merged" => nil,
      "review_in_progress" => false, "gate_in_flight" => nil, "holder_gate_in_flight" => nil,
      "progress_seconds_ago" => 30, "holder_liveness_seconds_ago" => 30 }
  end

  def test_board_reads_do_not_scale_with_desk_count
    out = run_in_script(<<~RUBY)
      # Count at the SUBPROCESS boundary, not at any helper's name: every board round
      # trip is one capture_status spawn, so this stays true if the mechanism changes.
      #
      # The payload is SHOW-shaped on purpose. An earlier cut of this check stubbed
      # {slug, stage} and asserted only the spawn count — which passes just as
      # happily when the cached record cannot answer a single hold question. Proving
      # "one read" while the record is useless is how the blind-guard defect shipped.
      SPAWNS = []
      def capture_status(*cmd, **_kw)
        SPAWNS << cmd.last(2).join(" ")
        payload = (1..5).map do |i|
          { "slug" => "task-\#{i}", "stage" => "building", "metadata" => {}, "merged" => nil,
            "review_in_progress" => false, "gate_in_flight" => nil, "holder_gate_in_flight" => nil,
            "progress_seconds_ago" => 30, "holder_liveness_seconds_ago" => 30 }
        end
        [true, JSON.generate(payload), "", 0]
      end
      def command_env(_app, _env); {}; end
      def File.exist?(path); path.to_s.end_with?("bin/task") || super; end

      records = (1..5).map do |i|
        { env: { "TASK_RECORD_SLUG" => "task-\#{i}" }, dir: "/tmp/desk-\#{i}", app: { "slug" => "mcritchie-studio" } }
      end
      prefetch_task_records!(records)
      records.each { |record| task_record_for_pr(record) }
      print SPAWNS.size
    RUBY

    assert_equal "1", out,
                 "five bound desks must cost ONE board read, not five — the per-desk read is what " \
                 "made the full-suite sweep unusable at 141 desks"
  end

  # --- the batch must never blind a hold channel -------------------------------
  #
  # THE DEFECT THIS EXISTS FOR. The batch reads the API index; every consumer of
  # @task_record_cache was written against the API show. Those are different
  # serializers — show merges derived fields, the index keeps the raw column — so an
  # index row is a complete, well-formed Task with review_in_progress,
  # gate_in_flight, holder_gate_in_flight, progress_seconds_ago and
  # holder_liveness_seconds_ago simply ABSENT. Absent reads as nil, and each of
  # those guards treats nil as a negative, so three of the four hold channels went
  # quiet at once and a desk whose builder was mid-cert read as abandoned.
  #
  # Asserting "the batch caches something" would have passed on the broken code.
  # What has to be asserted is the WITHHOLDING: an incomplete record never enters
  # the cache, so the desk falls through to the per-slug show read and unknown
  # holds. Absence of a field must never be evidence of absence of a claim.
  def test_batch_refuses_to_cache_a_record_missing_a_guard_field
    out = run_in_script(<<~RUBY)
      # EXACTLY what the raw index returns: a real row, derived fields absent.
      RAW = (1..3).map { |i| { "slug" => "task-\#{i}", "stage" => "building", "metadata" => {}, "merged" => nil } }
      def capture_status(*_cmd, **_kw); [true, JSON.generate(RAW), "", 0]; end
      def command_env(_app, _env); {}; end
      def File.exist?(path); path.to_s.end_with?("bin/task") || super; end

      records = (1..3).map do |i|
        { env: { "TASK_RECORD_SLUG" => "task-\#{i}" }, dir: "/tmp/desk-\#{i}", app: { "slug" => "mcritchie-studio" } }
      end
      prefetch_task_records!(records)
      print (@task_record_cache || {}).keys.inspect
    RUBY

    assert_equal "[]", out,
                 "an index-shaped record must NEVER be cached: it cannot answer review_in_progress " \
                 "or gate_in_flight, and a guard reading those as nil frees a desk whose builder is live"
  end

  # The positive half — otherwise the check above is satisfied by a batch that
  # caches nothing at all, and the speed-up could quietly disappear.
  def test_batch_caches_a_record_that_carries_every_guard_field
    payload = JSON.generate((1..3).map { |i| self.class.show_shaped("task-#{i}") })

    out = run_in_script(<<~RUBY)
      FULL = #{payload.inspect}
      def capture_status(*_cmd, **_kw); [true, FULL, "", 0]; end
      def command_env(_app, _env); {}; end
      def File.exist?(path); path.to_s.end_with?("bin/task") || super; end

      records = (1..3).map do |i|
        { env: { "TASK_RECORD_SLUG" => "task-\#{i}" }, dir: "/tmp/desk-\#{i}", app: { "slug" => "mcritchie-studio" } }
      end
      prefetch_task_records!(records)
      print (@task_record_cache || {}).keys.sort.inspect
    RUBY

    assert_equal '["task-1", "task-2", "task-3"]', out,
                 "a show-shaped record carries every guard field, so it is safe to cache — this is " \
                 "what makes the batch self-activating once the board serves full=1"
  end

  # --- stackless teardown is a BRANCH, not a comment ---------------------------
  #
  # discovered_worktree_configs used to omit the keys teardown fetches, and
  # STACKLESS_STACK was set at its construction site and never read. So the generic
  # Rails teardown ran against a gem repo and died on `app.fetch("sidekiq")` —
  # inside with_worktree_lock, after earlier candidates were already destroyed,
  # leaving a half-finished sweep and a stale registry.
  # Builds the tree it inspects. An earlier cut read discovered_worktree_configs.first
  # from the real projects root — which passed on a laptop with desks on disk and
  # returned nil in a fresh CI checkout, so the check was green exactly where it was
  # not needed and NoMethodError where it was. A test for discovery must own the
  # thing being discovered.
  def test_a_discovered_config_carries_every_key_teardown_fetches
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "studio-engine", ".worktrees", "a-desk"))

      out = run_in_script(<<~RUBY, env: { "PROJECTS_DIR" => root })
        config = discovered_worktree_configs.first
        keys = %w[sidekiq stack ruby_path session_env session_key reserved_ports]
        print config.nil? ? "NO CONFIG DISCOVERED" : keys.reject { |k| config.key?(k) }.inspect
      RUBY

      assert_equal "[]", out,
                   "teardown reaches for these with fetch — a config that omits one raises KeyError " \
                   "mid-sweep, inside the lock, after earlier desks are already gone"
    end
  end

  # The skip needs BOTH halves. Discovery is per-repo but a stack is per-desk, and
  # moms-app / mcritchie-industries are discovered too — they are ordinary Rails apps
  # whose desks DO have servers to stop. Classifying the repo stackless must never
  # be enough on its own to skip a live stack.
  def test_stackless_skip_requires_a_quiet_desk_not_just_a_stackless_repo
    out = run_in_script(<<~RUBY)
      STOPPED = []
      def stop_generic_rails(dir, _port = nil); STOPPED << dir; end
      def stop_pidfile(*_a); end
      def local_email_values; {}; end
      def parse_env(_p); { "APP_PORT" => "3999" }; end

      app = { "stack" => STACKLESS_STACK, "sidekiq" => false }
      # A gem desk: stackless repo, no stack env -> nothing to stop.
      stop_stack_for_removal(app, "/tmp/gem-desk", { env_exists: false, port: nil })
      # A discovered RAILS desk: stackless classification, but a live stack env.
      stop_stack_for_removal(app, "/tmp/rails-desk", { env_exists: true, env_path: "/tmp/x", port: "3999" })
      print STOPPED.inspect
    RUBY

    assert_equal '["/tmp/rails-desk"]', out,
                 "the gem desk is skipped and the Rails desk is still stopped — skipping the latter " \
                 "would orphan its server and its Redis DB"
  end

  # THE WITHHOLD. Coverage alone moved ~12 real desks onto the destroy path where three of
  # the four hold channels are structurally dead — permanently, by construction. A discovered
  # repo's desk can never carry a bound task (bind-task routes through the registry), so
  # claim_hold took its documented unbound FAIL-OPEN, review_hold and pr_hold_reason answer
  # nil for want of the same record, and what was left was desk age plus mtimes over a tree
  # whose tmp/log/coverage/vendor/.bundle are pruned — exactly and only what a gem builder
  # writes while running a suite. Measured on the pre-split branch: `cleanup --reclaim
  # studio-engine` nominated 4 desks that way.
  #
  # Both halves matter. Widening the fail-open to every unbound desk would wedge cleanup
  # entirely (the fail-open exists for a reason), so this asserts the REGISTERED unbound desk
  # still reads free in the same breath.
  def test_a_discovered_desk_is_withheld_while_a_registered_unbound_desk_still_frees
    out = run_in_script(<<~RUBY)
      def worktree_label(_r) = "a-repo/a-desk"
      def cleanup_command(_r) = "bin/agent-worktree remove a-repo a-desk --yes"
      def ship_workspace_record?(_r) = false

      discovered = { "status" => "discovered", "slug" => "studio-engine", "stack" => STACKLESS_STACK }
      registered = { "status" => "active", "slug" => "mcritchie-studio", "stack" => "rails" }

      held = claim_hold({ app: discovered, env: {}, task: "a-desk" })
      free = claim_hold({ app: registered, env: {}, task: "a-desk" })

      print [held.nil? ? "FREE" : "HELD", free.nil? ? "FREE" : "HELD"].inspect
    RUBY

    assert_equal '["HELD", "FREE"]', out,
                 "a discovered repo's desk must WITHHOLD (its unbound state is permanent, so the " \
                 "fail-open would be a standing licence to destroy on mtime evidence alone), while a " \
                 "registered unbound desk must still fail open or cleanup wedges entirely"
  end

  # The hold has to survive the whole aggregator, not just its own channel — reclaim_hold
  # chains claim -> review -> desk -> pr, and only the first is taught about discovery.
  def test_the_discovered_hold_survives_the_full_reclaim_hold_chain
    out = run_in_script(<<~RUBY)
      def worktree_label(_r) = "studio-engine/a-desk"
      def cleanup_command(_r) = "bin/agent-worktree remove studio-engine a-desk --yes"
      def ship_workspace_record?(_r) = false

      app = { "status" => "discovered", "slug" => "studio-engine", "stack" => STACKLESS_STACK }
      print reclaim_hold({ app: app, env: {}, task: "a-desk" }).to_s
    RUBY

    assert_match(/discovered repo/, out,
                 "reclaim_hold is what the destroy path actually calls, and this must hold for the " \
                 "DISCOVERY reason. Asserting mere truthiness passed even with claim_hold deleted " \
                 "from the chain outright: the stub record has no :dir, so desk_hold held it for an " \
                 "unrelated reason and the tautology hid the removal of the only channel that " \
                 "knows about discovery.")
  end

  # doctor and snapshot --write both run doctor_issues, and snapshot --write runs at the END
  # of run_reclaim. `port < range_start` with a nil range_start raised `comparison of Integer
  # with nil failed`, so the sweep tore desks down and THEN died before refreshing the
  # registry. Discovered desks with a real port are not hypothetical: moms-app and
  # mcritchie-industries are discovered Rails apps with live servers.
  def test_doctor_survives_a_discovered_desk_that_carries_a_port
    out = run_in_script(<<~RUBY)
      discovered = { "range_start" => nil, "range_end" => nil }   # a discovered Rails desk with a live port
      registered = { "range_start" => 3000, "range_end" => 3099 }

      begin
        print [
          port_range_issue(discovered, 3999).nil? ? "NO ISSUE" : "ISSUE",
          port_range_issue(registered, 3999).nil? ? "NO ISSUE" : "ISSUE",
          port_range_issue(registered, 3050).nil? ? "NO ISSUE" : "ISSUE"
        ].inspect
      rescue ArgumentError => e
        print "RAISED: " + e.message
      end
    RUBY

    assert_equal '["NO ISSUE", "ISSUE", "NO ISSUE"]', out,
                 "a discovered repo is allocated no port band, so there is no range to be outside " \
                 "of — comparing anyway killed doctor AND snapshot --write at the end of " \
                 "run_reclaim. The registered cases must keep reporting, or the guard is just off."
  end

  # Every remediation line the sweep prints for a discovered desk goes into the delete-later
  # ledger as the archive record, so BOTH halves have to hold: the command must resolve, and
  # it must resolve into the tree the desk actually lives in.
  #
  # This drives the real `remove` DISPATCH. An earlier cut called sweep_app_for directly and
  # was worthless: reverting `remove` to app_for — the exact defect its own comment named —
  # left it green.
  #
  # The sibling tree is the sharp case. worktree_dir hard-coded ".worktrees", so
  # `remove <repo>.sibling <desk>` resolved into the MANAGED tree: an abort when the name is
  # unique, and a teardown of the WRONG DESK the moment the same name exists in both trees.
  def test_remove_resolves_a_sibling_tree_desk_into_the_sibling_tree
    Dir.mktmpdir do |root|
      managed = File.join(root, "studio-engine", ".worktrees", "shared-name")
      sibling = File.join(root, "studio-engine.worktrees", "shared-name")
      FileUtils.mkdir_p(managed)
      FileUtils.mkdir_p(sibling)
      env = SessionEnv.neutralized.merge("PROJECTS_DIR" => root)

      # A desk that exists in NEITHER tree: the abort names the path it resolved, which is the
      # resolution itself, observed — and it cannot destroy anything on the way to saying so.
      out, err, = Open3.capture3(env, "ruby", BIN, "remove", "studio-engine.sibling", "no-such-desk")
      resolved = "#{out}#{err}"

      assert_includes resolved, File.join(root, "studio-engine.worktrees", "no-such-desk"),
                      "remove must resolve a .sibling config into the SIBLING tree"
      refute_includes resolved, File.join(root, "studio-engine", ".worktrees", "no-such-desk"),
                      "resolving into the managed tree is what destroys the wrong desk on a " \
                      "name collision — and both trees hold a `shared-name` desk here"
      refute_includes resolved, "unknown app",
                      "the sweep prints this command and ledgers it; it must resolve at all"
    end
  end

  # The slug is printed INTO a shell command and written to the ledger, so it has to survive a
  # shell. "(sibling)" did not: unquoted, bash answers "syntax error near unexpected token `('".
  def test_the_sibling_disambiguator_is_shell_safe
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "studio-engine.worktrees", "a-desk"))

      out = run_in_script(<<~RUBY, env: { "PROJECTS_DIR" => root })
        slug = discovered_worktree_configs.map { |c| c["slug"] }.find { |c| c.include?("sibling") }
        print slug.to_s
      RUBY

      assert_equal "studio-engine.sibling", out
      refute_match(/[()\[\]{}*?$`!&;|<> ]/, out,
                   "the sweep pastes this slug into `bin/agent-worktree remove <slug> ...`; a shell " \
                   "metacharacter makes every remediation line it prints unrunnable")
    end
  end

  # A repo with BOTH tree conventions yields two configs, each seeing only its own tree. The
  # orphan reconciliation compares `git worktree list` — which returns every worktree for the
  # repo — against that per-config view, so each config reported the OTHER tree as untracked:
  # twelve "review then remove" advisories against desks including a DIRTY one and three
  # UNMERGED. Advising teardown of unlanded work is what this file's doctrine forbids.
  def test_a_two_tree_repo_reconciles_against_the_union_of_its_trees
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "studio-engine", ".worktrees", "managed-desk"))
      FileUtils.mkdir_p(File.join(root, "studio-engine.worktrees", "sibling-desk"))

      # Drives orphan_worktree_issues — the DEFECT SITE — not stack_dirs_for_repo. Asserting the
      # helper in isolation is worthless here: the blocker's own revert (managed = stack_dirs(app))
      # left the whole suite green, the exact trap the remove test above was rewritten to escape.
      out = run_in_script(<<~RUBY, env: { "PROJECTS_DIR" => root })
        DESKS = [File.join(PROJECTS_DIR, "studio-engine", ".worktrees", "managed-desk"),
                 File.join(PROJECTS_DIR, "studio-engine.worktrees", "sibling-desk")]
               .map { |dir| canonical_path(dir) }
        def git_worktree_dirs(_repo) = DESKS
        config = discovered_worktree_configs.find { |c| c["slug"] == "studio-engine.sibling" }
        print orphan_worktree_issues(config).size
      RUBY

      assert_equal "0", out,
                   "both trees belong to one repo, so the SCOPED config must reconcile against " \
                   "both — otherwise doctor advises removing the other tree's live desks"
    end
  end

  # "Discovered repos appear in doctor and snapshot" is not satisfied by the UNSCOPED sweep
  # alone. Naming one — `doctor studio-engine` — went through app_for and answered "unknown
  # app" about desks the very same command had just listed unscoped. The lifecycle commands
  # keep app_for deliberately (they need a port range and a stack), so this asserts the split
  # rather than a blanket swap.
  def test_the_inspection_commands_resolve_a_discovered_repo_and_lifecycle_ones_still_refuse
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "studio-engine", ".worktrees", "a-desk"))
      env = SessionEnv.neutralized.merge("PROJECTS_DIR" => root)

      inspection = %w[doctor snapshot list].to_h do |command|
        out, err, _status = Open3.capture3(env, "ruby", BIN, command, "studio-engine")
        [command, "#{out}#{err}".include?("unknown app")]
      end
      out, err, _status = Open3.capture3(env, "ruby", BIN, "up", "studio-engine", "a-desk")
      lifecycle_refused = "#{out}#{err}".include?("unknown app")

      assert_equal({ "doctor" => false, "snapshot" => false, "list" => false }, inspection,
                   "an inspection command must resolve a repo the sweep already covers, or it " \
                   "answers \"unknown app\" about desks it just listed")
      assert lifecycle_refused,
             "`up` must still refuse a discovered repo — it needs a port range and a stack the " \
             "registry is what hands out. That refusal is the same constraint that makes such a " \
             "desk permanently unbound, which is why the reclaim hold exists."
    end
  end

  # --- the desk ledger: recorded on the board, and recorded BEFORE anything is destroyed --
  #
  # `bin/agent-worktree remove` used to append its audit row to
  # docs/agents/maintenance/delete-later.md, resolved against HUB_DIR. A cleanup is normally
  # run from the PRIMARY checkout, and the primary sits on `main` — a branch nobody may
  # commit to — so the record was created in the one place it could never be saved from. Six
  # stashes of "restore later" ledger content piled up between 2026-07-02 and 2026-08-31 (98
  # rows); not one was ever restored, and a reclaim sweep stranded 25 more DURING the
  # conversation about the defect. The row goes to the board now (bin/lib/desk_ledger.rb).
  #
  # The episode semantics those rows carried — one row per TEARDOWN not per PATH, a teardown
  # closes its own pending row in place, a dated row is history — moved with them and are
  # asserted in test/models/desk_record_test.rb. What is asserted HERE is the property that
  # only this script can hold: the write happens FIRST, and a write it cannot make stops the
  # teardown instead of proceeding without a record.

  # The teardown fixture: every destructive helper replaced by a recorder, so the check can
  # read the ORDER things happened in rather than trusting a comment about it.
  TEARDOWN_HARNESS = <<~RUBY
    STEPS = []
    def stack_record_snapshot(record, _issues); { "worktree" => record[:dir], "label" => "hub/_ship" }; end
    def cleanup_reason(_record); "clean and contained in origin/accepted"; end
    def cleanup_safety_label(_record); "merged"; end
    def cleanup_command(_record); "bin/agent-worktree remove mcritchie-studio _ship --yes"; end
    def stop_stack_for_removal(*); STEPS << :stop; end
    def flush_redis_db(*); STEPS << :redis; end
    def drop_desk_databases(*); STEPS << :databases; end
    def delete_local_branch_if_safe(*); STEPS << :branch; end
    def sh(*args); STEPS << :"git-\#{args.last(2).first}"; end
    APP = { "slug" => "mcritchie-studio", "repo" => "/repo" }.freeze
    RECORD = { app: APP, task: "_ship", dir: "/repo/.worktrees/_ship", branch: "release" }.freeze
  RUBY

  # THE PROPERTY. The ledger write is the FIRST thing teardown_worktree does. It used to sit
  # in the middle, which was survivable while it was a local file append and is not while it
  # is a network call: a teardown that stopped the stack and only then failed to record would
  # be the original defect with extra steps.
  def test_the_desk_record_is_written_before_anything_is_destroyed
    out = run_in_script(<<~RUBY)
      #{TEARDOWN_HARNESS}
      module DeskLedger
        def self.file(**_kw); STEPS << :ledger; Result.new(ok: true); end
      end
      teardown_worktree(APP, RECORD[:dir], RECORD)
      print STEPS.inspect
    RUBY

    steps = eval(out) # rubocop:disable Security/Eval -- the child prints its own Array#inspect

    assert_equal :ledger, steps.first,
                 "the audit row must land BEFORE the stack is stopped, the Redis DB flushed, " \
                 "the databases dropped or the git worktree removed"
    assert_includes steps, :stop
    assert_includes steps, :"git-remove", "…and the git worktree still goes, after the record"
  end

  # FAIL CLOSED, and nothing half-done. A board this script cannot reach costs a retry, not
  # an unrecorded removal — which is only true because the write comes first.
  def test_a_failed_desk_record_aborts_the_teardown_with_nothing_destroyed
    out = run_in_script(<<~RUBY)
      #{TEARDOWN_HARNESS}
      module DeskLedger
        def self.file(**_kw); Result.new(ok: false, error: "POST /api/v1/desk_records -> 500"); end
      end
      begin
        teardown_worktree(APP, RECORD[:dir], RECORD)
      rescue SystemExit
        print [:aborted, STEPS].inspect
      end
    RUBY

    outcome = eval(out) # rubocop:disable Security/Eval -- the child prints its own Array#inspect

    assert_equal :aborted, outcome.first, "an unrecorded teardown must REFUSE, not proceed"
    assert_empty outcome.last,
                 "nothing may be stopped, flushed, dropped or removed when the record could not be filed"
  end

  # The abort has to be actionable. It names the failure, says nothing was destroyed, and
  # gives back the exact command to re-run — an operator reading it mid-sweep should not
  # have to go find out where the ledger lives now.
  def test_the_abort_explains_the_failure_and_hands_back_the_command
    out, err, = Open3.capture3(SessionEnv.neutralized, "ruby", "-e", <<~RUBY)
      load #{BIN.inspect}
      #{TEARDOWN_HARNESS}
      module DeskLedger
        def self.file(**_kw); Result.new(ok: false, error: "POST /api/v1/desk_records -> 500"); end
      end
      teardown_worktree(APP, RECORD[:dir], RECORD)
    RUBY
    text = "#{out}#{err}"

    assert_includes text, "REFUSING to tear down"
    assert_includes text, "-> 500", "the operator needs the board's own answer, not a summary of it"
    assert_includes text, "NOTHING has been destroyed"
    assert_includes text, "bin/agent-worktree remove mcritchie-studio _ship --yes"
  end

  # `cleanup --write` was the ledger's OTHER writer and shares the defect, so it moved too.
  # It destroys nothing, so it warns rather than aborting — the fail-closed rule is scoped
  # to the destroy path, which is where it buys something.
  def test_cleanup_write_files_candidates_on_the_board_and_survives_a_failure
    out = run_in_script(<<~RUBY)
      #{TEARDOWN_HARNESS}
      def refresh_origin_reachability!(*); end
      def report_withheld(*); end
      def print_cleanup_candidate(*); end
      def maybe_scale_in; end
      def cleanup_partition(_app = nil); [[RECORD], []]; end
      module DeskLedger
        def self.file(status:, source:, **_kw); STEPS << [status, source]; Result.new(ok: false, error: "boom"); end
      end
      # run_cleanup narrates to stdout; silence it so the child prints ONE parseable value.
      def puts(*); end
      run_cleanup(nil, write: true)
      $stdout.print STEPS.inspect
    RUBY

    assert_equal [["candidate", "cleanup"]], eval(out), # rubocop:disable Security/Eval
                 "a nomination is an OPEN candidate filed by `cleanup`, and a failed write " \
                 "must not take the sweep down with it"
  end

  # The "Safe-delete condition" cell the ledger has always carried. It is the one part of a
  # row that has no equivalent anywhere in the registry, so it is built here and posted.
  def test_the_safe_delete_condition_distinguishes_a_teardown_from_a_nomination
    out = run_in_script(<<~RUBY)
      def cleanup_command(_record); "bin/agent-worktree remove hub _ship --yes"; end
      print [cleanup_condition({}, status: "removed"), cleanup_condition({}, status: "candidate")].inspect
    RUBY

    removed, pending = eval(out) # rubocop:disable Security/Eval

    assert_includes removed, "Removed with"
    assert_includes pending, "after operator approval"
  end

  # THE SCRIPT NO LONGER WRITES THE FILE, and that is the whole fix. Asserting it by name
  # rather than by behaviour is deliberate: a reintroduced `ledger_path` would be a quiet
  # revert to writing a tree the primary cannot commit, and it would look correct locally.
  def test_the_script_no_longer_writes_the_markdown_ledger
    # CODE only. The header comment names the file it stopped writing — that is the record
    # of the fix, not a relapse — so the check strips comments before looking, or it would
    # be a test that can only pass by deleting its own explanation.
    code = File.readlines(BIN).reject { |line| line.strip.start_with?("#") }.join

    refute_includes code, "delete-later.md",
                    "the markdown ledger is tracked HISTORY now; a writer here lands rows on `main`"
    refute_includes code, "def write_cleanup_ledger_record"
    refute_includes code, "def ledger_path"
  end
end
