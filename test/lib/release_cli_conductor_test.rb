# frozen_string_literal: true

# The conductor seam: the shell-safe payload, the session prefix, deploy-span
# narration, run_test_scope telemetry and the crew-ticker intent writes.
#
# Part of the bin/release CLI suite, one file per subcommand. The
# shared subprocess harness, fixtures and stub constants live in
# test/lib/release_cli_harness.rb. Run directly:
#   ruby -Itest test/lib/release_cli_conductor_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require_relative "release_cli_harness"

class ReleaseCliConductorTest < ReleaseCliHarness
  # --- conductor_payload: the shell-safe rails-runner bootstrap (the blocker) --
  # record_post_deploy_check interpolated a post_deploy_cmd via cmd.inspect; a
  # seed-54-style `bin/rails runner "load Rails.root.join(%q(...)).to_s"` arrived
  # as escaped quotes + parens, heroku's remote re-quoting ATE the \"-escaping, and
  # the exposed `(` triggered `bash: syntax error near unexpected token '('` —
  # conductor then hit "record op returned no JSON" and aborted prepare BEFORE
  # assemble!. conductor_payload base64-wraps the WHOLE snippet at the shared seam
  # so EVERY conductor caller rides shell-safe.

  def test_conductor_payload_is_a_shell_safe_base64_bootstrap_for_paren_quote_snippets
    require "base64"
    # The exact shape record_post_deploy_check builds: the cmd interpolated via
    # .inspect — escaped quotes + parens, the bytes that broke `heroku run`.
    cmd = %q{bin/rails runner "load Rails.root.join(%q(db/seeds/54_demo.rb)).to_s"}
    snippet = %{c = Release::Conductor.record_post_deploy_check(cmd: #{cmd.inspect}, ok: true); puts({ checks: c.size }.to_json)}
    out = eval_helper(%(conductor_payload(#{snippet.inspect}))).strip

    # The command line carries ONLY a url-safe Base64 eval bootstrap — between the
    # quotes is nothing but [A-Za-z0-9_-]=, so heroku's re-quoting can't mangle it.
    assert_match(/\Aeval\(Base64\.urlsafe_decode64\("[A-Za-z0-9_\-=]+"\)\)\z/, out,
                 "the payload is a single shell-safe Base64 eval bootstrap: #{out}")
    refute_includes out, "Rails.root.join", "the raw paren/quote snippet must not reach the command line"
    refute_includes out, "%q(", "no payload parens reach the command line (remote bash syntax error)"

    # And it round-trips byte-for-byte: the blob decodes to the wrapped snippet
    # (the cmd rides inside via .inspect, so the seed path survives intact).
    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    decoded = Base64.urlsafe_decode64(b64).force_encoding("UTF-8")
    assert_equal "require 'json'; #{snippet}", decoded,
                 "the wrapped snippet round-trips byte-for-byte through the payload encoding"
    assert_includes decoded, "db/seeds/54_demo.rb", "the seed path survives in the payload"
  end

  def test_conductor_payload_round_trips_an_ordinary_snippet
    require "base64"
    out = eval_helper(%(conductor_payload("puts({ok: true}.to_json)"))).strip
    b64 = out[/urlsafe_decode64\("([A-Za-z0-9_\-=]+)"\)/, 1]
    refute_nil b64, out
    assert_equal "require 'json'; puts({ok: true}.to_json)", Base64.urlsafe_decode64(b64),
                 "an ordinary snippet round-trips unchanged through the payload encoding"
  end

  # --- with_conductor_session: tag the deployment with the running session -----
  # The conductor's local session id lives in THIS shell's env and does NOT cross
  # the `heroku run` boundary, so conductor() passes it in-band ahead of the
  # snippet. The prod runner drains Current.conductor_session_id onto the release
  # so the board shows which agent worked the deploy. `Current.try(:…=)` so an
  # older prod (pre-attribute) ignores it instead of erroring mid-ship.

  def test_with_conductor_session_prefixes_the_session_id_when_present
    out = eval_helper(%{(ENV['CLAUDE_CODE_SESSION_ID']='sess-z'; with_conductor_session("puts :ok"))}).strip
    assert_equal %(Current.try(:conductor_session_id=, "sess-z"); puts :ok), out,
                 "the snippet is prefixed with the in-band session id so prod can stamp the mascot"
  end

  def test_with_conductor_session_falls_back_to_codex_thread_id
    expr = %{(ENV.delete('CLAUDE_CODE_SESSION_ID'); ENV['CODEX_THREAD_ID']='codex-1'; with_conductor_session("puts :ok"))}
    assert_equal %(Current.try(:conductor_session_id=, "codex-1"); puts :ok), eval_helper(expr).strip
  end

  def test_with_conductor_session_is_a_no_op_without_a_session
    expr = %{(ENV.delete('CLAUDE_CODE_SESSION_ID'); ENV.delete('CODEX_THREAD_ID'); with_conductor_session("puts :ok"))}
    assert_equal "puts :ok", eval_helper(expr).strip,
                 "a session-less run passes the snippet through untouched"
  end
  def test_narration_helpers_stamp_the_role_agent_and_close_with_an_outcome
    setup = <<~RUBY
      $events = []
      def agent_activity(*a) = ($events << a)
      def conductor_session_id = "sess-x"
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %(open_role_span("steffon", "assemble → deploy RC to QA"); ) +
                        %(close_role_span("assembled rel-x → QA"); print($events.inspect)))

    assert_includes out, %(["start", "--category", "Remote", "--reason", "assemble → deploy RC to QA", "--agent", "steffon"]),
                     "open_role_span opens a Remote span stamped with the role soul"
    assert_includes out, %(["end", "--outcome", "assembled rel-x → QA"]),
                     "close_role_span closes it with an outcome"
  end

  def test_agent_activity_is_a_noop_under_dry_run
    setup = %(def conductor_session_id = "sess-x")
    out = run_cli(["--dry-run"], setup: setup,
                  call: %(print(agent_activity("start", "--category", "Remote", "--reason", "x").inspect)))
    assert_equal "nil", out, "a dry-run narrates nothing (best-effort no-op)"
  end

  def test_agent_activity_is_a_noop_without_a_conductor_session
    # SessionEnv nulls the session vars → conductor_session_id is nil → no-op;
    # telemetry must never shell out (or fail) when there's no session to attribute.
    out = run_cli(["--yes"], setup: "",
                  call: %(print(agent_activity("start", "--category", "Remote", "--reason", "x").inspect)))
    assert_equal "nil", out, "no conductor session → nothing to narrate"
  end

  # [integration] prepare records an Avi deploy span end-to-end (the paren
  # post_deploy stub reaches assemble under --yes; narration is captured, not shelled).
  def test_prepare_narrates_an_avi_deploy_span
    out = run_cli(["--yes"], call: "prepare", setup: PAREN_POST_DEPLOY_PREP_STUB + NARRATION_CAPTURE)

    assert_includes out, "ATOMIC start --category Remote --reason sweep → deploy RC to QA --agent avi",
                     "prepare opens an Avi span"
    assert_match(/ATOMIC end --outcome assembled/, out, "and closes it once the RC is assembled")
  end

  # [integration] ship records a Steffon deploy span end-to-end (the publish-decision
  # stub runs the real ship flow under --yes with only the git/gem/heroku I/O stubbed).
  def test_ship_narrates_a_steffon_deploy_span
    out = run_cli(["--yes"], call: "ship", setup: PUBLISH_DECISION_STUB + NARRATION_CAPTURE)

    assert_includes out, "ATOMIC start --category Remote --reason ship → prod --agent steffon",
                     "ship opens a Steffon span after ship authority"
    assert_match(/ATOMIC end --outcome shipped/, out, "and closes it once shipped to prod")
  end

  # bin/release's real work (git / gh / heroku run) runs as SUBPROCESSES of one Bash
  # tool call, invisible to the PostToolUse capture hook — so its Remote deploy span
  # read "No raw actions attributed". step() now self-reports each in-span operation
  # as an AgentAction (bin/agent-activity action) so the span carries genuine rows.

  def test_step_self_reports_an_action_only_inside_a_role_span
    setup = <<~RUBY
      $events = []
      def agent_activity(*a) = ($events << a)
      def conductor_session_id = "sess-x"
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %(step("before span"); ) +
                        %(open_role_span("steffon", "sweep → deploy RC to QA"); ) +
                        %(step("qa deploy: bin/qa-server deploy foo"); ) +
                        %(close_role_span("assembled rel-x → QA"); ) +
                        %(step("after span"); print($events.inspect)))

    assert_includes out, %(["action", "--summary", "qa deploy: bin/qa-server deploy foo"]),
                     "a step INSIDE the role span self-reports an AgentAction"
    refute_includes out, %(["action", "--summary", "before span"]),
                     "a step BEFORE the span opens does not (nothing to attribute to)"
    refute_includes out, %(["action", "--summary", "after span"]),
                     "a step AFTER the span closes does not"
  end

  def test_agent_action_is_a_noop_under_dry_run
    # agent_action rides agent_activity, which no-ops under --dry-run — a preview
    # narrates and self-reports nothing.
    setup = %(def conductor_session_id = "sess-x")
    out = run_cli(["--dry-run"], setup: setup,
                  call: %(print(agent_action("qa deploy: foo").inspect)))
    assert_equal "nil", out, "a dry-run self-reports no action"
  end

  # [integration] prepare's in-span steps self-report actions end-to-end (the paren
  # post_deploy stub reaches assemble under --yes; narration is captured, not shelled).
  def test_prepare_self_reports_step_actions_into_the_span
    out = run_cli(["--yes"], call: "prepare", setup: PAREN_POST_DEPLOY_PREP_STUB + NARRATION_CAPTURE)

    assert_match(/ATOMIC action --summary /, out,
                 "prepare's steps self-report actions into the open Remote span")
  end
  def test_run_test_scope_emits_start_and_completed_with_counts_on_success
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["141 runs, 320 assertions, 0 failures, 0 errors", true])
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("ship_test_gate", "bin/rails", "test", repo: "mcritchie-studio"); print($events.inspect)))

    assert_includes out, "test scope ship_test_gate START", "the wrapper emits a START action"
    assert_includes out, "test scope ship_test_gate COMPLETED", "…and a COMPLETED action on success"
    assert_includes out, "mcritchie-studio", "the emitted action carries the repo/host"
    assert_includes out, "141 runs, 320 assertions, 0 failures, 0 errors", "…the parsed minitest counts"
    assert_includes out, "pass", "…and the pass verdict"
  end

  def test_run_test_scope_emits_failed_and_returns_false_when_the_command_fails
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["3 runs, 3 assertions, 1 failures, 0 errors", false])
    out = run_cli(["--yes"], setup: setup,
                  call: %(_o, ok = run_test_scope("qa_post_deploy", "heroku", "run", repo: "turf-monster-qa"); ) +
                        %(print("OK=" + ok.inspect + " " + $events.inspect)))

    assert_includes out, "OK=false", "the wrapper returns the command's ok flag (false) unchanged"
    assert_includes out, "test scope qa_post_deploy FAILED", "a failed command emits a FAILED action"
    assert_includes out, "fail", "…with the fail verdict"
    assert_includes out, "1 failures", "…and the parsed counts"
  end

  def test_run_test_scope_emits_failed_then_reraises_when_the_command_raises
    # A raised SystemCallError (Open3 ENOENT on a bad path) must RE-RAISE so the
    # caller's rescue still fires — production_smoke_seal degrades it to a red
    # seal — but a FAILED action is emitted first.
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k); raise Errno::ENOENT, "bin/prod-smoke"; end)
    out = run_cli(["--yes"], setup: setup,
                  call: %(begin; run_test_scope("prod_smoke_seal", "bin/prod-smoke", "mcritchie-studio", repo: "mcritchie-studio"); ) +
                        %(puts("NO-RAISE"); rescue SystemCallError => e; puts("RAISED " + e.class.name); end; print($events.inspect)))

    assert_includes out, "RAISED Errno::ENOENT", "a raising command re-raises (the seal degradation depends on it)"
    refute_includes out, "NO-RAISE", "the wrapper does not swallow the raise"
    assert_includes out, "test scope prod_smoke_seal FAILED", "…but a FAILED action is emitted first"
    assert_includes out, "Errno::ENOENT", "…naming the error class"
  end

  def test_run_test_scope_emits_nothing_outside_a_role_span
    setup = <<~RUBY
      $events = []
      def agent_activity(*a) = ($events << a)
      def conductor_session_id = "sess-x"
      $role_span_open = false
      def sh(*_a, **_k) = ["7 runs, 7 assertions, 0 failures, 0 errors", true]
    RUBY
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("pre_qa_gate", "bin/rails", "test", repo: "mcritchie-studio"); print($events.inspect)))

    assert_equal "[]", out, "no open role span → nothing to attribute → no telemetry (the step() gate)"
  end

  def test_run_test_scope_is_inert_under_dry_run
    # A dry-run executes NOTHING: sh short-circuits before its `system`, and the
    # telemetry rides agent_activity which is DRY-gated before its `system`. So
    # no shell-out fires at all — neither the command nor the narration.
    setup = <<~RUBY
      $syscalls = []
      def system(*a, **_k); $syscalls << a; true; end
      def conductor_session_id = "sess-x"
      $role_span_open = true
    RUBY
    out = run_cli(["--dry-run"], setup: setup,
                  call: %(run_test_scope("ship_test_gate", "bin/rails", "test", repo: "mcritchie-studio"); ) +
                        %(print("SYSCALLS-EMPTY=" + $syscalls.empty?.to_s)))

    assert_includes out, "SYSCALLS-EMPTY=true",
                     "a dry-run wraps but executes nothing — command + telemetry both inert (no shell-out)"
  end

  # --- verdict tagging: the COMPLETED/FAILED emit is a GRADEABLE test_scope -----
  # A2: run_test_scope tags ONLY the verdict emit with the fields that make the run
  # a first-class gradeable unit in /xan/pipeline — kind=test_scope, event_slug=the
  # scope key, result_slug=pass|fail, duration_ms — while the START emit stays plain
  # (so the pipeline's `kind:test_scope AND result_slug present` filter skips it).

  def test_run_test_scope_tags_only_the_verdict_action_as_a_gradeable_test_scope
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["141 runs, 320 assertions, 0 failures, 0 errors", true])
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("ship_test_gate", "bin/rails", "test", repo: "mcritchie-studio"); ) +
                        %(start = $events.find { |e| e.join(" ").include?("START") }; ) +
                        %(done  = $events.find { |e| e.join(" ").include?("COMPLETED") }; ) +
                        %(print("START=" + start.inspect + "\\nDONE=" + done.inspect)))

    start_line, done_line = out.split("\nDONE=", 2)

    # The verdict emit carries every gradeable tag field.
    assert_includes done_line, "--kind",        "the verdict action is tagged with a kind"
    assert_includes done_line, "test_scope",    "…kind=test_scope so the pipeline can select it"
    assert_includes done_line, "--event-slug",  "…tagged with the scope key"
    assert_includes done_line, "ship_test_gate"
    assert_includes done_line, "--result-slug", "…tagged with the pass|fail verdict"
    assert_includes done_line, "pass"
    assert_includes done_line, "--duration-ms", "…and the wall-clock duration"

    # START stays plain — no tag fields — so it never lands in the pipeline band.
    refute_includes start_line, "--kind",        "the START emit stays untagged"
    refute_includes start_line, "test_scope"
    refute_includes start_line, "--result-slug"
  end

  def test_run_test_scope_tags_a_failed_verdict_with_result_slug_fail
    setup = SCOPE_EMIT_STUB +
            %(def sh(*_a, **_k) = ["3 runs, 3 assertions, 1 failures, 0 errors", false])
    out = run_cli(["--yes"], setup: setup,
                  call: %(run_test_scope("qa_post_deploy", "heroku", "run", repo: "turf-monster-qa"); ) +
                        %(done = $events.find { |e| e.join(" ").include?("FAILED") }; print(done.inspect)))

    assert_includes out, "--kind",        "a failed run is still a tagged, gradeable verdict"
    assert_includes out, "test_scope"
    assert_includes out, "--event-slug"
    assert_includes out, "qa_post_deploy"
    assert_includes out, "--result-slug"
    assert_includes out, "fail", "…with result_slug fail"
  end

  # --- parse_test_counts: lenient, nil when nothing recognizable --------------

  def test_parse_test_counts_sums_minitest_summary_lines
    assert_equal %("141 runs, 320 assertions, 0 failures, 0 errors"),
                 eval_helper(%q{parse_test_counts("141 runs, 320 assertions, 0 failures, 0 errors").inspect}),
                 "a single minitest summary line parses verbatim"
    # `rails test test:system` prints one summary line PER lane — they sum.
    assert_equal %("15 runs, 28 assertions, 1 failures, 2 errors"),
                 eval_helper(%q{parse_test_counts("10 runs, 20 assertions, 1 failures, 0 errors\n5 runs, 8 assertions, 0 failures, 2 errors").inspect}),
                 "multiple minitest summary lines are summed across lanes"
  end

  def test_parse_test_counts_reads_playwright_and_up_code_and_returns_nil_otherwise
    assert_equal %("12 passed"),
                 eval_helper(%q{parse_test_counts("Running 12 tests\n12 passed (3.2s)").inspect}),
                 "playwright's 'N passed' parses"
    assert_equal %("12 passed, 2 failed"),
                 eval_helper(%q{parse_test_counts("12 passed\n2 failed").inspect}),
                 "…with a failed count when present"
    assert_equal %("http 200"),
                 eval_helper(%q{parse_test_counts("200").inspect}),
                 "a bare 3-digit /up probe body parses as an http code"
    assert_equal "nil",
                 eval_helper(%q{parse_test_counts("some unrecognizable output").inspect}),
                 "nothing recognizable → nil (the summary just omits counts)"
  end

  def test_gem_release_check_runs_through_the_telemetry_wrapper
    with_release_check_repo do |dir|
      setup = SCOPE_EMIT_STUB + <<~RUBY
        def repo_path(_repo) = #{dir.inspect}
        def sh(*a, **_k)
          $stdout.puts("SH " + a.inspect)
          ["3 runs, 3 assertions, 0 failures, 0 errors", true]  # release-check green (and gem build/push/tag)
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %(publish_gem("studio-engine", "0.9.0"); print($events.inspect)))

      assert_includes out, %(SH ["bin/release-check", "--build"]),
                       "the release-check still executes with --build"
      assert_includes out, "test scope gem_release_check START", "…now wrapped: a START action is emitted"
      assert_includes out, "test scope gem_release_check COMPLETED", "…and a COMPLETED action on a green check"
      assert_includes out, "studio-engine", "the emitted action carries the gem repo/host"
    end
  end

  def test_gem_release_check_failure_emits_failed_and_aborts_before_publish
    with_release_check_repo do |dir|
      setup = SCOPE_EMIT_STUB + <<~RUBY
        def repo_path(_repo) = #{dir.inspect}
        def sh(*a, **_k)
          $stdout.puts("SH " + a.inspect)
          return ["1 runs, 1 assertions, 1 failures, 0 errors", false] if a[0] == "bin/release-check"
          ["", true]
        end
      RUBY
      out = run_cli(["--yes"], setup: setup,
                    call: %(begin; publish_gem("studio-engine", "0.9.0"); puts("NO-ABORT"); ) +
                          %(rescue SystemExit => e; puts("ABORTED: " + e.message); end; print($events.inspect)))

      assert_includes out, "test scope gem_release_check FAILED", "a red release-check emits a FAILED action"
      assert_includes out, "ABORTED", "…and still aborts before publishing (existing gate behavior preserved)"
      assert_includes out, "release-check failed"
      refute_includes out, "NO-ABORT", "the gem must not publish past a red release-check"
      refute_includes out, %(SH ["gem", "push"), "nothing is pushed after the red check aborts"
    end
  end
  def test_prepare_continues_when_the_crew_ticker_intent_write_fails
    out = run_cli(["--dry-run"], call: "prepare", setup: INTENT_FAIL_PREPARE_STUB)

    assert_includes out, "crew-ticker board write failed",
                     "the cosmetic intent write WARNS on a transient prod-board failure (it does not abort)"
    assert_includes out, "deploy continues",
                     "the warning states the deploy is not aborted"
    assert_includes out, "bin/qa-server deploy mcritchie-studio origin/release",
                     "prepare PROCEEDS to the QA deploy — the failed cosmetic intent's SystemExit did NOT abort it"
  end
  def test_ship_continues_when_the_crew_ticker_intent_write_fails
    out = run_cli(["--dry-run"], call: "ship", setup: INTENT_FAIL_SHIP_STUB)

    assert_includes out, "crew-ticker board write failed",
                     "the cosmetic ship-slot intent write WARNS on a transient prod-board failure"
    assert_includes out, "deploy continues",
                     "the warning states the production deploy is not aborted"
    assert_includes out, "push heroku bbbbbbb:refs/heads/main",
                     "ship PROCEEDS to the production deploy — the failed cosmetic intent's SystemExit did NOT abort it"
  end

  # Guard against over-broadening: making the COSMETIC intent best-effort must NOT swallow
  # real deploy errors. A non-intent conductor failure (here the deploy-critical repo-plan
  # read) is FATAL and must STILL abort — record_deploy_intent's rescue is scoped to the
  # intent write alone, never the deploy path.
  def test_real_deploy_conductor_failures_still_abort_prepare
    setup = %(def conductor(ruby, read_only: false); abort!("record op failed: prod board down"); end)
    out = run_cli(["--dry-run"], setup: setup,
                  call: "begin; prepare; puts('NO-ABORT'); rescue SystemExit => e; puts('ABORTED: ' + e.message); end")

    assert_includes out, "ABORTED", "a real (non-intent) conductor failure still aborts the deploy"
    assert_includes out, "prod board down", "the abort surfaces the real failure cause"
    refute_includes out, "NO-ABORT", "the best-effort rescue must not swallow a deploy-critical conductor failure"
  end
end
