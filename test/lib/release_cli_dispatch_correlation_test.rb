# frozen_string_literal: true

# bin/release.rb's dispatch_and_watch finds ITS OWN run by a correlation id in the
# run name, not by "newest run after the baseline". Standalone:
#   ruby -Itest test/lib/release_cli_dispatch_correlation_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# THE GAP (guard-catalog row 7.4). `gh workflow run` names no run, so the method
# snapshotted the newest run id and watched the first one strictly greater. That is
# ours only while nobody else dispatches the same workflow in the window: a second
# conductor, a hand dispatch or a rollback each register a run that is ALSO newer,
# and `--limit 1` returns whichever is newest. On prod-deploy.yml the conductor would
# report another deploy's verdict as its own.
#
# THE FIX THIS PINS. Each dispatch carries a fresh `correlation_id`; both workflows
# stamp it into `run-name`; the poll selects the run whose title carries `[<id>]`.
#
# HOW IT IS DRIVEN. The `sh` stub below is a small GitHub: it holds a run list and
# answers every `gh run list --jq <filter>` by running THE SCRIPT'S OWN FILTER through
# the real `jq` over that list. So the test proves the filter the shell sends, not a
# stub's idea of it — a filter that selected the wrong run would watch the wrong run.
#
# A FILE OF ITS OWN: the release CLI files are frozen by config/test_health.yml.
require "minitest/autorun"
require "open3"
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../app/models/release/ship_sequence"

class ReleaseCliDispatchCorrelationTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN  = File.join(ROOT, "bin/release.rb")
  S    = Release::ShipSequence

  WORKFLOW = "qa-deploy.yml"
  INPUTS   = { "sha" => "0a0cc23" }.freeze
  DISPATCH = %(dispatch_and_watch(#{WORKFLOW.inspect}, #{INPUTS.inspect}))
  JQ       = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |d| File.join(d, "jq") }
                 .find { |p| File.executable?(p) }

  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("release-correlation-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  def run_release(setup, call)
    env = OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir, "TASK_API_BASE" => "http://127.0.0.1:1")
    script = %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; #{call})
    out, status = Open3.capture2e(env, RbConfig.ruby, "-e", script)
    assert status.success?, "the subprocess must catch its own abort in-process: #{out}"
    out
  end

  def guarded(call)
    %(begin; r = #{call}; puts("NO-ABORT RESULT=\#{r}"); ) +
      %(rescue SystemExit => e; puts("ABORTED"); puts(e.message); end)
  end

  # A GitHub with one prior run (100). `on_dispatch` is Ruby run inside the stub when
  # `gh workflow run` is called: `cid` is the correlation id the dispatch carried (nil
  # when none), and it returns the [out, ok] gh would.
  def github(on_dispatch)
    flunk("jq is required on PATH: the stub answers with the script's own --jq filter") unless JQ
    <<~RUBY
      def sleep(*) = nil
      $runs = [{ "databaseId" => 100, "displayTitle" => "QA Deploy prior [dw-prior]" }] # newest first, as gh lists
      $dispatches = []
      $watched = nil
      def register(id, title) = $runs.unshift({ "databaseId" => id, "displayTitle" => title })
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        if cmd[0, 3] == ["gh", "run", "list"]
          out, st = Open3.capture2(#{JQ.inspect}, "-r", cmd[cmd.index("--jq") + 1], stdin_data: JSON.generate($runs))
          return [out, st.success?]
        end
        if cmd[0, 3] == ["gh", "workflow", "run"]
          $dispatches << cmd
          pair = cmd.find { |a| a.start_with?("correlation_id=") }
          cid = pair && pair.split("=", 2).last
          #{on_dispatch}
        end
        if cmd[0, 3] == ["gh", "run", "watch"]
          $watched = cmd[3]
          return ["", true]
        end
        ["", true]
      end
    RUBY
  end

  REPORT = %(; puts("WATCHED \#{$watched}"); puts("DISPATCHES \#{$dispatches.size}"); p($dispatches))

  # ── [unit] the pure half ────────────────────────────────────────────────────

  def jq(filter, runs)
    flunk("jq is required on PATH") unless JQ
    out, st = Open3.capture2(JQ, "-r", filter, stdin_data: JSON.generate(runs))
    assert st.success?, "jq must accept the filter #{filter}"
    out.strip
  end

  def test_correlation_ids_are_fresh_and_bracketed_in_the_marker
    a = S.correlation_id
    b = S.correlation_id
    assert_match(/\Adw-\h{16}\z/, a, "hex only, so the marker needs no escaping in the jq string")
    refute_equal a, b, "every dispatch mints its own id"
    assert_equal "[#{a}]", S.run_name_marker(a)
  end

  def test_the_filter_picks_its_own_run_and_ignores_a_newer_concurrent_one
    runs = [
      { "databaseId" => 102, "displayTitle" => "QA Deploy abc [dw-concurrent]" },
      { "databaseId" => 101, "displayTitle" => "QA Deploy abc [dw-ours]" },
      { "databaseId" => 100, "displayTitle" => "QA Deploy old [dw-prior]" }
    ]
    assert_equal "101", jq(S.correlated_run_jq("dw-ours"), runs),
                 "the newest run is someone else's; ours is the one carrying our marker"
    assert_equal "", jq(S.correlated_run_jq("dw-absent"), runs), "no run yet reads EMPTY (the shell's 0)"
    assert_equal "", jq(S.correlated_run_jq("dw-our"), runs),
                 "the brackets stop a shorter id matching inside a longer one"
  end

  def test_the_filter_survives_a_run_with_no_title
    runs = [{ "databaseId" => 9, "displayTitle" => nil }, { "databaseId" => 8, "displayTitle" => "x [dw-a]" }]
    assert_equal "8", jq(S.correlated_run_jq("dw-a"), runs)
  end

  def test_only_the_correlation_input_refusal_is_recognised
    assert S.correlation_input_rejected?(
      %(could not create workflow dispatch event: HTTP 422: Unexpected inputs provided: ["correlation_id"])
    )
    refute S.correlation_input_rejected?(%(HTTP 422: Unexpected inputs provided: ["release_pr"]))
    refute S.correlation_input_rejected?("HTTP 403: Resource not accessible by integration")
    refute S.correlation_input_rejected?("")
    refute S.correlation_input_rejected?(nil)
  end

  # ── [integration] dispatch_and_watch against a GitHub with a concurrent dispatcher ──

  def test_dispatch_and_watch_watches_its_own_run_not_a_newer_concurrent_one
    # Ours registers as 101, then a concurrent dispatch registers 102. Both are newer
    # than the baseline (100), so baseline selection watches 102.
    gh = github(%(register(101, "QA Deploy 0a0cc23 [\#{cid}]"); register(102, "QA Deploy 0a0cc23 [dw-concurrent]"); return ["", true]))
    out = run_release(gh, guarded(DISPATCH) + REPORT + %(; puts("BASELINE-NEWEST \#{run_list_read(#{WORKFLOW.inspect}).first.strip}")))

    assert_includes out, "NO-ABORT RESULT=true", out
    assert_includes out, "WATCHED 101", "the run carrying our correlation id is the one watched"
    assert_includes out, "BASELINE-NEWEST 102",
                    "control: the unfiltered newest-run read would have latched the concurrent run"
    assert_match(/"-f", "correlation_id=dw-\h{16}"/, out, "the dispatch carries the correlation id")
  end

  def test_a_dispatch_whose_only_new_run_is_someone_elses_aborts_as_never_created
    # GitHub registers NO run for us, but a concurrent dispatch lands 102 — newer than
    # the baseline. Baseline selection would watch 102 and report its verdict as ours.
    gh = github(%(register(102, "QA Deploy 0a0cc23 [dw-concurrent]"); return ["", true]))
    out = run_release(gh, guarded(DISPATCH) + REPORT)

    assert_includes out, "ABORTED", out
    assert_match(/^WATCHED $/, out, "nothing was watched: another dispatcher's run is never adopted as ours")
    assert_includes out, S.undispatched_run_abort(WORKFLOW, INPUTS),
                    "the answered poll found no run carrying our marker: the never-created abort"
  end

  # A workflow that lacks the input is refused: release_dispatch_correlation_test.rb.

  def test_any_other_dispatch_refusal_is_not_retried
    gh = github(%(return ["HTTP 403: Resource not accessible by integration\n", false]))
    out = run_release(gh, guarded(DISPATCH) + REPORT)

    assert_includes out, "NO-ABORT RESULT=false", out
    assert_includes out, "DISPATCHES 1", "a refused dispatch is never sent again"
    assert_includes out, "HTTP 403: Resource not accessible", "gh's own error is printed"
    assert_includes out, "NOTHING WAS DEPLOYED"
  end

  # ── [unit] every workflow dispatch_and_watch drives declares the run-name ───

  # The set is read from where the dispatches come from: the literal workflow names
  # bin/release.rb hands dispatch_and_watch, plus every github_actions adapter in the
  # repo registry (ship and rollback dispatch `adapter["workflow"]`). The registry is
  # read through the script's own RELEASE_REPOS rather than by path: spelling the
  # config's path here would widen its fast-check mapped lane (FastCertSubjectTest).
  def driven_workflows
    literals = File.read(BIN).scan(/dispatch_and_watch\("([\w.-]+\.ya?ml)"/).flatten
    call = <<~'RUBY'
      (RELEASE_REPOS["apps"] || {}).each_value do |app|
        deploy = app.is_a?(Hash) ? app["prod_deploy"] : nil
        puts("ADAPTER #{deploy['workflow']}") if deploy.is_a?(Hash) && deploy["strategy"] == "github_actions"
      end
    RUBY
    adapters = run_release("", call).scan(/^ADAPTER (\S+)$/).flatten
    (literals + adapters).uniq
  end

  def test_every_driven_workflow_declares_the_correlation_input_and_run_name
    workflows = driven_workflows
    assert_includes workflows, "qa-deploy.yml"
    assert_includes workflows, "prod-deploy.yml"

    workflows.each do |wf|
      doc = YAML.load_file(File.join(ROOT, ".github/workflows", wf))
      input = doc.dig(true, "workflow_dispatch", "inputs", S::CORRELATION_INPUT) ||
              doc.dig("on", "workflow_dispatch", "inputs", S::CORRELATION_INPUT)
      assert input, "#{wf} declares the #{S::CORRELATION_INPUT} input"
      refute input["required"], "#{wf}: the id is optional, so a hand dispatch needs none"
      assert_includes doc["run-name"].to_s, "[${{ inputs.#{S::CORRELATION_INPUT} }}]",
                      "#{wf}'s run-name stamps the id in the bracketed marker the poll matches"
    end
  end
end
