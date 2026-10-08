# frozen_string_literal: true

# bin/release.rb's dispatch_and_watch selects its run by correlation id ONLY.
# Standalone:
#   ruby -Itest test/lib/release_dispatch_correlation_test.rb
#
# A run is watched when its title carries the `[<id>]` this dispatch sent, and never
# because it is the newest run after the pre-dispatch read. A workflow that lacks the
# `correlation_id` input is refused with one dispatch and no re-dispatch. The
# pre-dispatch read stays, as the credential probe.
#
# The `sh` stub is a small GitHub: it answers each `gh run list --jq <filter>` by
# running the script's own filter through the real `jq`. No test mints a token,
# dispatches or pushes.
require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "fileutils"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../app/models/release/ship_sequence"

class ReleaseDispatchCorrelationTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)
  S   = Release::ShipSequence

  WORKFLOW = "qa-deploy.yml"
  INPUTS   = { "sha" => "0a0cc23" }.freeze
  JQ       = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |d| File.join(d, "jq") }
                 .find { |p| File.executable?(p) }
  REJECTED = %(could not create workflow dispatch event: HTTP 422: Unexpected inputs provided: ["correlation_id"])

  def self.lock_dir
    @lock_dir ||= begin
      dir = Dir.mktmpdir("release-dispatch-correlation-locks")
      Minitest.after_run do
        FileUtils.remove_entry(dir)
      rescue StandardError
        nil
      end
      dir
    end
  end

  # Runs dispatch_and_watch against a GitHub holding one prior run (100).
  # `on_dispatch` is Ruby run inside the stub at `gh workflow run`: `cid` is the
  # correlation id the dispatch carried, nil when it carried none.
  def dispatch(on_dispatch)
    flunk("jq is required on PATH: the stub answers with the script's own --jq filter") unless JQ
    setup = <<~RUBY
      def sleep(*) = nil
      $runs = [{ "databaseId" => 100, "displayTitle" => "QA Deploy prior [dw-prior]" }]
      $calls = []
      $watched = nil
      def register(id, title) = $runs.unshift({ "databaseId" => id, "displayTitle" => title })
      def sh(*cmd, capture: false, chdir: nil, env: nil)
        $calls << cmd[0, 3].join(" ")
        if cmd[0, 3] == ["gh", "run", "list"]
          out, st = Open3.capture2(#{JQ.inspect}, "-r", cmd[cmd.index("--jq") + 1], stdin_data: JSON.generate($runs))
          return [out, st.success?]
        end
        if cmd[0, 3] == ["gh", "workflow", "run"]
          pair = cmd.find { |a| a.start_with?("correlation_id=") }
          cid = pair && pair.split("=", 2).last
          #{on_dispatch}
        end
        $watched = cmd[3] if cmd[0, 3] == ["gh", "run", "watch"]
        ["", true]
      end
    RUBY
    call = %(begin; r = dispatch_and_watch(#{WORKFLOW.inspect}, #{INPUTS.inspect}); puts("RESULT=\#{r}"); ) +
           %(rescue SystemExit => e; puts("ABORTED"); puts(e.message); end; ) +
           %(puts("WATCHED \#{$watched}"); puts("DISPATCHES \#{$calls.count("gh workflow run")}"); ) +
           %(puts("FIRST-CALL \#{$calls.first}"))
    env = OutboundSeams.env("MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir, "TASK_API_BASE" => "http://127.0.0.1:1")
    out, status = Open3.capture2e(env, RbConfig.ruby, "-e",
                                  %(ARGV.replace(["--yes"]); load #{BIN.inspect}; #{setup}; #{call}))
    assert status.success?, "the subprocess must catch its own abort in-process: #{out}"
    out
  end

  def test_matches_run_by_run_name_not_baseline
    # Ours registers as 101, then another dispatcher's 102. Both are newer than the
    # pre-dispatch read (100), and 102 is the newest.
    out = dispatch(%(register(101, "QA Deploy 0a0cc23 [\#{cid}]"); register(102, "QA Deploy 0a0cc23 [dw-other]"); return ["", true]))

    assert_includes out, "RESULT=true", out
    assert_includes out, "WATCHED 101", "the run carrying this dispatch's id is the one watched"
    assert_includes out, "DISPATCHES 1"
  end

  # THE CONTROL: the only run newer than the pre-dispatch read carries another id.
  def test_CONTROL_a_newer_run_with_another_correlation_id_is_never_adopted
    out = dispatch(%(register(102, "QA Deploy 0a0cc23 [dw-other]"); return ["", true]))

    assert_includes out, "ABORTED", out
    assert_match(/^WATCHED $/, out, "another dispatcher's run is never watched as ours")
    assert_includes out, S.undispatched_run_abort(WORKFLOW, INPUTS)
  end

  def test_a_workflow_without_the_correlation_input_is_refused_with_a_reason
    out = dispatch(%(return [#{(REJECTED + "\n").inspect}, false]))

    assert_includes out, "RESULT=false", out
    assert_includes out, "DISPATCHES 1", "the refused dispatch is not sent again without the id"
    assert_match(/^WATCHED $/, out)
    assert_includes out, REJECTED, "gh's own words are printed"
    assert_includes out, "does not declare the `correlation_id` input"
    assert_includes out, "NOTHING WAS DEPLOYED; this is not a boot failure"
    assert_includes out, "[${{ inputs.correlation_id }}]", "the reason names the run-name the workflow needs"
  end

  # THE CONTROL for the refusal: GitHub would accept a dispatch without the id and
  # register a run newer than the pre-dispatch read. Nothing sends one, so nothing
  # is watched.
  def test_CONTROL_a_run_an_uncorrelated_dispatch_would_create_is_never_watched
    out = dispatch(<<~RUBY)
      return [#{(REJECTED + "\n").inspect}, false] if cid
      register(101, "QA Deploy")
      return ["", true]
    RUBY

    assert_includes out, "RESULT=false", out
    assert_includes out, "DISPATCHES 1"
    assert_match(/^WATCHED $/, out, "no run is selected by being newer than the pre-dispatch read")
  end

  def test_one_read_precedes_the_dispatch
    out = dispatch(%(register(101, "QA Deploy 0a0cc23 [\#{cid}]"); return ["", true]))

    assert_includes out, "FIRST-CALL gh run list", "the pre-dispatch read is the credential probe"
  end

  def test_the_script_holds_no_uncorrelated_run_read_in_the_poll
    source = File.read(BIN)

    refute source.include?("def newest_run_id"), "the newest-run read has no caller left to select a run"
    assert_equal 1, source.scan("correlated_run_id(workflow, cid, chdir: chdir)").size
  end
end
