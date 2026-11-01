# frozen_string_literal: true

# bin/release.rb's DISPATCH → RUN window: the gap between `gh workflow run` returning 0 and
# GitHub creating a run. A dispatch whose run never registers ABORTS, naming the workflow, the
# SHA and the dispatch command, instead of degrading into a boot-timeout diagnosis. Emphatically
# NOT a longer boot poll: that polls the same stale tree for longer. A suite covering only
# successful dispatches certifies nothing here. A FILE OF ITS OWN: the release CLI files are
# frozen by config/test_health.yml; this harness is deliberately the small one (load, stub `sh`,
# drive one method).
# History: release rel-20260907-14cff2.
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils" # lock_dir cleanup (Minitest.after_run remove_entry)
require "rbconfig"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

# The PURE half of the fix, loaded in-process so the assertions below can compare
# the CLI's output against what the source BUILDS rather than a hand-copied string.
# bin/release.rb require_relatives this same file, so there is one message, not two.
require_relative "../../app/models/release/ship_sequence"

class ReleaseCliDispatchRunTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  WORKFLOW = "qa-deploy.yml"
  INPUTS   = { "sha" => "0a0cc23" }.freeze

  # Lazy + memoized so forked test workers each get their own dir, and REMOVED after
  # the run — the same shape the release CLI harness uses. A per-run tmpdir that
  # nobody deletes is how a machine accumulates hundreds of them silently.
  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("release-dispatch-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  # Drive bin/release.rb in a sealed subprocess: OutboundSeams puts stub binaries in
  # front of PATH (so a missed stub cannot reach the real `gh`), and the conductor
  # lock dir is pinned away from the operator's live one.
  def run_release(setup, call)
    env = OutboundSeams.env(
      "MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir,
      "TASK_API_BASE" => "http://127.0.0.1:1"
    )
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; #{call})
    out, status = Open3.capture2e(env, RbConfig.ruby, "-e", script)
    assert status.success?, "the subprocess must catch its own abort in-process: #{out}"
    out
  end

  # THE MEASURED SHAPE, exactly: the pre-dispatch snapshot ANSWERS (100), `gh
  # workflow run` is ACCEPTED and exits 0 — and the newest run id then never moves
  # past 100, because no run was ever created. Every `gh` call succeeds; that is the
  # whole trap. `sleep` is a no-op so the registration poll costs no wall-clock.
  NO_RUN_CREATED = <<~RUBY
    def sleep(*) = nil
    $watched = false
    $dispatched = nil
    def sh(*cmd, capture: false, chdir: nil, env: nil)
      return ["100", true] if cmd[0, 3] == ["gh", "run", "list"]
      if cmd[0, 3] == ["gh", "run", "watch"]
        $watched = true
        return ["", true]
      end
      $dispatched = cmd if cmd[0, 3] == ["gh", "workflow", "run"]
      ["", true]
    end
  RUBY

  # THE SECOND CAUSE OF A NIL RUN ID, which NO_RUN_CREATED above cannot express: the
  # pre-dispatch snapshot ANSWERS (100), `gh workflow run` is accepted — and then
  # EVERY post-dispatch `gh run list` FAILS. correlated_run_id returns nil on a failed
  # list, new_run_id returns nil on a nil argument, so the poll ends on the identical
  # `run_id.nil?` branch as a genuinely-never-created run while having observed
  # NOTHING. The count is what makes the two stubs different: this one fails reads
  # 2..N, NO_RUN_CREATED succeeds at all of them.
  LIST_UNREADABLE = <<~RUBY
    def sleep(*) = nil
    $watched = false
    $list_calls = 0
    def sh(*cmd, capture: false, chdir: nil, env: nil)
      if cmd[0, 3] == ["gh", "run", "list"]
        $list_calls += 1
        return $list_calls == 1 ? ["100", true] : ["", false]
      end
      if cmd[0, 3] == ["gh", "run", "watch"]
        $watched = true
        return ["", true]
      end
      ["", true]
    end
  RUBY

  # THE THIRD SHAPE separates "did ANY read answer" from "did the LAST read answer". The
  # snapshot answers (call 1), the dispatch is accepted, the FIRST post-dispatch read answers
  # 100 (the same id, run not registered YET), and reads 3..N FAIL: the token-expiry window. WHY
  # THE COUNT: LIST_UNREADABLE fails reads 2..N; this lets exactly one answer FIRST. That read
  # carries NO evidence that no run exists, yet can flip an ACCUMULATING discriminator onto "the
  # deploy NEVER RAN" and a re-dispatch command, which on prod-deploy.yml orders a SECOND
  # PRODUCTION DEPLOY.
  # History: task abort-trusts-stale-read.
  READ_THEN_UNREADABLE = <<~RUBY
    def sleep(*) = nil
    $watched = false
    $list_calls = 0
    def sh(*cmd, capture: false, chdir: nil, env: nil)
      if cmd[0, 3] == ["gh", "run", "list"]
        $list_calls += 1
        return $list_calls <= 2 ? ["100", true] : ["", false]
      end
      if cmd[0, 3] == ["gh", "run", "watch"]
        $watched = true
        return ["", true]
      end
      ["", true]
    end
  RUBY

  # The snapshot itself never answers: `gh run list` fails from the very first call,
  # so there is no baseline and the method returns WITHOUT dispatching.
  SNAPSHOT_NEVER_ANSWERS = <<~RUBY
    def sleep(*) = nil
    $dispatched = false
    def sh(*cmd, capture: false, chdir: nil, env: nil)
      return ["", false] if cmd[0, 3] == ["gh", "run", "list"]
      $dispatched = true if cmd[0, 3] == ["gh", "workflow", "run"]
      ["", true]
    end
  RUBY

  # `gh workflow run` itself is REFUSED — gh reports the failure and nothing is
  # dispatched. Also a `false` return, also downstream of prepare's `qa_ok &&=`.
  DISPATCH_REFUSED = <<~RUBY
    def sleep(*) = nil
    def sh(*cmd, capture: false, chdir: nil, env: nil)
      return ["100", true] if cmd[0, 3] == ["gh", "run", "list"]
      return ["", false] if cmd[0, 3] == ["gh", "workflow", "run"]
      ["", true]
    end
  RUBY

  # A run that DOES register: 100 before the dispatch, 101 after. `conclusion` drives
  # what that run turns out to be, so the same stub covers the green and failed halves.
  def run_registered(conclusion)
    <<~RUBY
      def sleep(*) = nil
      $list_calls = 0
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          $list_calls += 1
          return [($list_calls == 1 ? "100" : "101"), true]
        end
        return ["", #{conclusion == 'success'}] if cmd[0, 3] == ["gh", "run", "watch"]
        return ["completed\\t#{conclusion}", true] if cmd[0, 3] == ["gh", "run", "view"]
        ["", true]
      end
    RUBY
  end

  DISPATCH = %(dispatch_and_watch(#{WORKFLOW.inspect}, #{INPUTS.inspect}))

  # Wrap the call so an abort is CAPTURED and printed rather than killing the child —
  # `abort` raises SystemExit carrying its message, which is what makes the wording
  # assertable at all.
  def guarded(call)
    %(begin; r = #{call}; puts("NO-ABORT RESULT=\#{r}"); ) +
      %(rescue SystemExit => e; puts("ABORTED"); puts(e.message); end)
  end

  # ── [integration] the regression: a dispatch that creates no run ─────────────

  def test_a_dispatch_that_creates_no_run_aborts_instead_of_returning
    out = run_release(NO_RUN_CREATED, guarded(DISPATCH) + %(; puts("WATCHED \#{$watched}")))

    assert_includes out, "ABORTED",
                    "a dispatch whose run never registered must ABORT — the silent `return false` " \
                    "let prepare fold it into the boot-failure bucket and blame a healthy app"
    refute_includes out, "NO-ABORT",
                    "it must never hand its caller a deploy verdict for a deploy that never ran"
    assert_includes out, "WATCHED false",
                    "and must not watch some other run in place of the one that was never created"
  end

  # THE CONTENT of the abort, asserted against what the SOURCE emits. A test carrying
  # its own copy of the prose cannot see the source change: it stays green while the
  # operator-facing message — the entire deliverable here — rots underneath it.
  def test_the_abort_carries_the_workflow_the_sha_and_the_dispatch_command
    out = run_release(NO_RUN_CREATED, guarded(DISPATCH))

    assert_includes out, Release::ShipSequence.undispatched_run_abort(WORKFLOW, INPUTS),
                    "the CLI must abort with the message the source builds, not a paraphrase of it"
    # Each fact in its OWN labelled field, asserted separately. `assert_includes out,
    # sha` alone is satisfied by the sha appearing inside the quoted command — measured:
    # deleting the entire `sha:` line left that assertion green.
    assert_match(/^\s*workflow:\s+#{Regexp.escape(WORKFLOW)}\s*$/, out, "the workflow is named")
    assert_match(/^\s*sha:\s+#{Regexp.escape(INPUTS['sha'])}\s*$/, out,
                 "the SHA that was never deployed is named — that is which tree the app is still serving")
    assert_match(/^\s*command:\s+gh workflow run #{Regexp.escape(WORKFLOW)} -f sha=#{Regexp.escape(INPUTS['sha'])}\s*$/,
                 out, "the dispatch command is named, so the operator can reproduce it by hand")
  end

  # THE LOOP CLOSED: the command the message hands the operator is the command the shell
  # ACTUALLY RAN. Both come from Release::ShipSequence.dispatch_argv; this drives the real
  # dispatch through the stub. THE ONE DIFFERENCE IS THE CORRELATION PAIR: the conductor appends
  # `-f correlation_id=<id>`, so the dispatched argv is the quoted command plus exactly that
  # trailing pair. Nothing else may differ.
  # History: task prepare-drops-qa-dispatch.
  def test_the_quoted_command_is_the_command_the_shell_dispatched
    pinned = %(def dispatch_correlation_id = "dw-pinned")
    out = run_release("#{NO_RUN_CREATED}\n#{pinned}", guarded(DISPATCH) + %(; p($dispatched)))

    quoted = Release::ShipSequence.dispatch_argv(WORKFLOW, INPUTS)
    assert_includes out, (quoted + ["-f", "correlation_id=dw-pinned"]).inspect,
                    "the argv `gh workflow run` was called with must be the quoted one plus the correlation pair"
    assert_includes out, "command:  #{quoted.join(' ')}\n", "the abort quotes the hand-runnable command"
  end

  # THE WRONG DIAGNOSIS IS THE COST. An hour went into a healthy app because the
  # message said boot timeout and pointed at `bin/qa-server deploy`. The abort has to
  # rule both out in the operator's own words.
  def test_the_abort_rules_out_the_boot_timeout_diagnosis
    out = run_release(NO_RUN_CREATED, guarded(DISPATCH))

    assert_includes out, "NOT a boot timeout", "the misdiagnosis is refused explicitly"
    assert_includes out, "the deploy NEVER RAN", "…and the real fact is stated first"
    assert_includes out, "bin/qa-server deploy", "the remedy NOT to reach for is named"
    assert_includes out, "do NOT lengthen the boot poll",
                    "…as is the other tempting non-fix: the app booted fine"
  end

  # ── [integration] the other half: a run that DOES appear ─────────────────────
  #
  # Without these, "abort whenever anything goes wrong" would satisfy every assertion
  # above while destroying the ship's real failure handling. The abort is scoped to a
  # MISSING run; a run that registered keeps its ordinary verdict.

  def test_a_registered_run_that_goes_green_returns_true_and_never_aborts
    out = run_release(run_registered("success"), guarded(DISPATCH))

    assert_includes out, "NO-ABORT RESULT=true", "a green run is still a plain successful deploy"
    refute_includes out, "ABORTED", "nothing about a run that ran and passed is a dispatch failure"
  end

  # ── [integration] the SECOND cause: nil run id because nothing could be READ ──
  #
  # THE DEFECT. Both causes land on the same `run_id.nil?`, and the abort above
  # asserts one of them as fact: "the deploy NEVER RAN", "the app is still serving
  # its OLD tree", "Re-run the dispatch by hand". Printed over an unreadable `gh`
  # that is a false report AND an instruction to fire a SECOND deploy — on
  # prod-deploy.yml, while the first may be in flight. The message here has to
  # report the observation instead, and the observation is that there was none.

  def test_an_unreadable_run_list_aborts_with_the_honest_unknown_not_the_never_ran_claim
    out = run_release(LIST_UNREADABLE, guarded(DISPATCH) + %(; puts("WATCHED \#{$watched}")))

    assert_includes out, "ABORTED", "a poll that never read GitHub still must not return a deploy verdict"
    assert_includes out, Release::ShipSequence.unreadable_run_list_abort(WORKFLOW, INPUTS),
                    "the CLI must abort with the UNREADABLE message the source builds"
    refute_includes out, "NEVER RAN",
                    "nothing was observed — reporting the deploy as not having run is the defect"
    refute_includes out, "still serving its OLD tree",
                    "…and so is describing the app's tree, which was never read either"
    assert_includes out, "WATCHED false", "and it must not watch a run it never identified"
  end

  # THE SAFETY PROPERTY, stated as the operator reads it: the remedy on this path is
  # a CHECK. The other message's remedy — re-run the dispatch — is the one act that
  # can double a live production deploy, so it must not appear here.
  def test_the_unreadable_abort_orders_a_check_not_a_second_dispatch
    out = run_release(LIST_UNREADABLE, guarded(DISPATCH))

    assert_includes out, "Do NOT re-dispatch", "a blind re-dispatch is the harm this message prevents"
    assert_includes out, "CHECK FIRST"
    assert_includes out, "UNKNOWN", "the state of the deploy is stated as unknown, not as a fact"
    refute_includes out, "Re-run the dispatch by hand",
                     "the never-created message's remedy must not leak onto the unreadable path"
  end

  # THE PAIR, from the other side. Splitting one branch into two is only worth
  # anything if each side keeps its own message; a collapse in EITHER direction has
  # to fail, so the never-created case asserts the absence of the unreadable wording
  # exactly as the test above asserts the reverse.
  def test_a_never_created_run_keeps_its_own_message_and_does_not_report_unknown
    out = run_release(NO_RUN_CREATED, guarded(DISPATCH))

    assert_includes out, Release::ShipSequence.undispatched_run_abort(WORKFLOW, INPUTS),
                    "a poll whose LAST read ANSWERED and showed no new run does establish that " \
                    "no run exists — this is the path entitled to say so"
    refute_includes out, "UNKNOWN",
                    "…so this path must not hedge: it is the one that legitimately hands over the command"
    refute_includes out, "Do NOT re-dispatch",
                     "the unreadable path's refusal must not leak onto the path where re-dispatching is the fix"
  end

  # ── [integration] the discriminator must read the LAST observation ───────────
  # The predicate choosing between the two messages must not ACCUMULATE (`saw_a_read = true
  # unless latest_id.nil?`). "GitHub registered NO run" is a claim about the run list NOW; only
  # the most recent read supports it, and one read before registration cannot. A token expiring
  # mid-poll produces exactly this.
  # History: task abort-trusts-stale-read.
  def test_a_read_that_succeeds_before_the_list_goes_unreadable_does_not_claim_never_ran
    out = run_release(READ_THEN_UNREADABLE, guarded(DISPATCH) + %(; puts("WATCHED \#{$watched}")))

    assert_includes out, "ABORTED", "a nil run id is a hard abort on this path too"
    refute_includes out, "NEVER RAN",
                    "the LAST read FAILED, so nothing observed supports asserting that no run " \
                    "exists — and that message hands over a re-dispatch that can double a live deploy"
    refute_includes out, "Re-run the dispatch by hand",
                     "an early read that answered before registration must not buy the remedy " \
                     "that is safe only once you KNOW no run exists"
    assert_includes out, Release::ShipSequence.unreadable_run_list_abort(WORKFLOW, INPUTS),
                    "the abort must report the observation as UNKNOWN and order a CHECK"
    assert_includes out, "WATCHED false", "and it must not watch a run it never identified"
  end

  # ── [integration] the two dispatch failures that stay `false` ────────────────
  #
  # These do NOT abort — they are ordinary gh failures on a dispatch that provably
  # did not happen — but prepare's `qa_ok &&=` short-circuits the /up poll, so they
  # arrive at the operator as "never returned /up 200": a boot verdict for a request
  # nobody made. They cannot say it in the summary, so they say it here, and the
  # runbook's boot-failure row sends the reader up the log to find this line.

  def test_a_snapshot_that_never_answers_says_nothing_was_deployed
    out = run_release(SNAPSHOT_NEVER_ANSWERS, guarded(DISPATCH) + %(; puts("DISPATCHED \#{$dispatched}")))

    assert_includes out, "NO-ABORT RESULT=false", "no baseline is still a return, not an abort"
    assert_includes out, "DISPATCHED false", "and it must not dispatch without one"
    assert_includes out, "NOTHING WAS DEPLOYED",
                    "the fact the /up summary will otherwise contradict has to be on the log"
    assert_includes out, "not a boot failure",
                    "…named as such, because the summary downstream calls it exactly that"
  end

  def test_a_refused_dispatch_says_nothing_was_deployed
    out = run_release(DISPATCH_REFUSED, guarded(DISPATCH))

    assert_includes out, "NO-ABORT RESULT=false", "a gh-refused dispatch is an ordinary failed command"
    assert_includes out, "NOTHING WAS DEPLOYED",
                    "the app was never deployed to, so the boot diagnosis downstream is wrong about it"
  end

  def test_a_registered_run_that_failed_is_a_verdict_not_a_dispatch_abort
    out = run_release(run_registered("failure"), guarded(DISPATCH))

    assert_includes out, "NO-ABORT RESULT=false",
                    "a run that appeared and concluded FAILURE is a deploy verdict its caller handles"
    refute_includes out, "ABORTED",
                    "the abort must not swallow the ship's own failure path"
    refute_includes out, "NEVER RAN", "…and must not accuse a run that plainly ran"
  end
end
