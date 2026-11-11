# frozen_string_literal: true

# bin/release prints and records its per-step durations (task release-sub-hour-pipeline).
#   ruby -Itest test/lib/release_cli_step_timings_test.rb

require_relative "release_cli_harness"

class ReleaseCliStepTimingsTest < ReleaseCliHarness
  def test_an_act_prints_both_timing_lines_and_records_them_under_the_results_dir
    out = run_cli(["--yes"], call: <<~RUBY)
      time_step("sweep")
      time_step("ci_gate", release: "rel-t")
      report_step_timings
      puts("FILE " + File.read(File.join(release_results_dir, "steps.jsonl")))
    RUBY

    assert_match(/^⏱ step durations: sweep \d+s · ci gate \d+s$/, out)
    assert_match(/^RELEASE_STEP_TIMINGS \{"sweep":\d+,"ci_gate":\d+\}$/, out)
    # The results dir is shared by every act in the run: read this act's own line.
    lines = out.split("FILE ", 2).last.lines.map { |l| JSON.parse(l) rescue nil }.compact
    record = lines.reverse.find { |r| r["release"] == "rel-t" }
    refute_nil record, "no steps.jsonl line for rel-t: #{out}"
    assert_equal "rel-t", record["release"]
    assert_equal %w[sweep ci_gate], record["steps"].keys
  end

  # task devops-sub-hour-follow-ups: the same durations land on the board as one
  # `step_timings` ReleaseEvent on the act's release.
  def test_an_act_records_its_timings_as_one_release_event
    out = run_cli(["--yes"], call: <<~RUBY)
      def record_release_event(release_slug, step_name, status, attrs = {})
        puts("EVENT " + JSON.generate([release_slug, step_name, status, attrs]))
      end
      $release_act = "prepare"
      time_step("sweep")
      time_step("ci_gate", release: "rel-t")
      report_step_timings
    RUBY

    line = out.lines.find { |l| l.start_with?("EVENT ") }
    refute_nil line, "no step_timings event: #{out}"
    rel, step, status, attrs = JSON.parse(line.delete_prefix("EVENT "))
    assert_equal ["rel-t", "step_timings", "completed"], [rel, step, status]
    assert_equal "prepare", attrs.dig("metadata", "act")
    assert_equal %w[sweep ci_gate], attrs.dig("metadata", "steps").keys
    assert_match(/\A⏱ step durations: sweep \d+s · ci gate \d+s\z/, attrs["message"])
    assert_match(/\Arel-t:step_timings:prepare:/, attrs["idempotency_key"])
  end

  def test_the_event_snippet_carries_the_metadata_as_ruby
    out = run_cli(["--yes"], call: <<~RUBY)
      print(release_event_ruby("rel-t", "step_timings", "completed",
                               metadata: { "act" => "ship", "steps" => { "deploy" => 61 } }, idempotency_key: "k"))
    RUBY
    assert_includes out, %(step: "step_timings", status: "completed")
    assert_match(/metadata: \{"act"\s*=>\s*"ship", "steps"\s*=>\s*\{"deploy"\s*=>\s*61\}\}/, out)
    RubyVM::InstructionSequence.compile(out) # the runner snippet is Ruby the board can run
  end

  def test_an_act_with_no_release_records_no_event
    out = run_cli(["--yes"], call: <<~RUBY)
      def record_release_event(*args, **kw) = puts("EVENT")
      time_step("sweep")
      report_step_timings
    RUBY
    refute_includes out, "EVENT", "a prepare that named no release has nothing to hang the event on"
  end

  def test_a_dry_run_times_nothing
    out = run_cli(["--dry-run"], call: %(time_step("sweep"); print($step_clock.inspect)))
    assert_equal "nil", out
  end
end
