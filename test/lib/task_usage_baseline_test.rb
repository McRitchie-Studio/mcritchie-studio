# frozen_string_literal: true

# Unit test for TaskUsageBaseline — the per-(session, slug) baseline storage +
# delta math shared by bin/task, bin/release, and bin/reviewer-select. Plain Ruby
# (no Rails); also picked up by the normal `bin/rails test` sweep.
#
#   ruby -Itest test/lib/task_usage_baseline_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/task_usage_baseline"

class TaskUsageBaselineTest < Minitest::Test
  SESSION = "aaaa1111-bbbb-2222-cccc-333344445555"
  SLUG = "demo-task"

  def assistant_line(input:, output:, cc:, cr:)
    JSON.generate("type" => "assistant", "message" => {
      "model" => "claude-opus-4-8",
      "usage" => {
        "input_tokens" => input, "output_tokens" => output,
        "cache_creation_input_tokens" => cc, "cache_read_input_tokens" => cr
      }
    })
  end

  # Write (overwrite) the session transcript with the given assistant lines under
  # a project dir AgentSessionUsage's glob can find.
  def write_transcript(root, lines)
    dir = File.join(root, "-Users-alex-projects")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{SESSION}.jsonl"), "#{lines.join("\n")}\n")
  end

  def baseline(dir:, root:)
    TaskUsageBaseline.new(session: SESSION, dir: dir, transcript_root: root)
  end

  def test_seed_writes_the_current_totals_when_absent_and_is_idempotent
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |state|
        write_transcript(root, [assistant_line(input: 100, output: 200, cc: 10, cr: 1000)])
        b = baseline(dir: state, root: root)

        assert b.seed(SLUG), "seeds a fresh baseline from the session's current totals"
        assert_equal({ "input" => 100, "output" => 200, "cache_creation" => 10, "cache_read" => 1000 }, b.read(SLUG))

        # More tokens land, but a second seed must NOT reset the in-progress baseline.
        write_transcript(root, [
          assistant_line(input: 100, output: 200, cc: 10, cr: 1000),
          assistant_line(input: 50, output: 80, cc: 5, cr: 2000)
        ])
        refute b.seed(SLUG), "idempotent — never resets an existing baseline"
        assert_equal({ "input" => 100, "output" => 200, "cache_creation" => 10, "cache_read" => 1000 }, b.read(SLUG))
      end
    end
  end

  def test_capture_delta_against_a_seeded_baseline_isolates_the_new_work
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |state|
        write_transcript(root, [assistant_line(input: 1000, output: 2000, cc: 0, cr: 5000)])
        b = baseline(dir: state, root: root)
        b.seed(SLUG)

        # The work transition: a second turn lands, then we capture the delta.
        write_transcript(root, [
          assistant_line(input: 1000, output: 2000, cc: 0, cr: 5000),
          assistant_line(input: 100, output: 4000, cc: 50, cr: 6000)
        ])
        result = b.capture_delta(SLUG)

        assert result.usage?
        assert_equal 6150, result.tokens_in   # turn 2 only: 100 + 50 + 6000
        assert_equal 4000, result.tokens_out
        # The baseline ADVANCES to the new cumulative totals, so the next move
        # measures from here (not from the seed).
        assert_equal({ "input" => 1100, "output" => 6000, "cache_creation" => 50, "cache_read" => 11_000 }, b.read(SLUG))
      end
    end
  end

  def test_first_capture_with_no_baseline_reports_model_only_then_advances
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |state|
        write_transcript(root, [assistant_line(input: 1000, output: 2000, cc: 0, cr: 5000)])
        b = baseline(dir: state, root: root)

        result = b.capture_delta(SLUG)
        assert_equal "claude-opus-4-8", result.model
        refute result.usage?, "no baseline yet → no token delta (the zeroed first-move case)"
        refute_nil b.read(SLUG), "but the baseline IS advanced, so the next capture has a delta"
      end
    end
  end

  def test_blank_session_is_a_safe_noop
    Dir.mktmpdir do |state|
      b = TaskUsageBaseline.new(session: "", dir: state)
      refute b.seed(SLUG)
      assert_nil b.capture_delta(SLUG)
      assert_nil b.read(SLUG)
    end
  end

  def test_missing_transcript_seed_and_capture_degrade_to_nil
    Dir.mktmpdir do |root|
      Dir.mktmpdir do |state|
        b = baseline(dir: state, root: root) # no transcript written
        refute b.seed(SLUG)
        assert_nil b.capture_delta(SLUG)
      end
    end
  end
end
