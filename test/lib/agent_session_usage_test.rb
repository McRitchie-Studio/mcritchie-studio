# frozen_string_literal: true

# Unit test for AgentSessionUsage — transcript parsing, cumulative sums, the
# per-move delta, and pricing. Plain Ruby (no Rails); also picked up by the
# normal `bin/rails test` sweep.
#
#   ruby -Itest test/lib/agent_session_usage_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/agent_session_usage"

class AgentSessionUsageTest < Minitest::Test
  SESSION = "11111111-2222-3333-4444-555555555555"

  # Two assistant turns plus noise (a user line and a malformed line) the parser
  # must skip. Cumulative totals: input 150, output 280, cache_creation 15,
  # cache_read 3000.
  def write_transcript(root)
    dir = File.join(root, "-Users-alex-projects")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{SESSION}.jsonl"), <<~JSONL)
      {"type":"user","message":{"role":"user","content":"hi"}}
      {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":10,"cache_read_input_tokens":1000}}}
      not valid json — must be skipped
      {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":80,"cache_creation_input_tokens":5,"cache_read_input_tokens":2000}}}
    JSONL
  end

  def test_sums_usage_across_assistant_lines_and_reads_model
    Dir.mktmpdir do |root|
      write_transcript(root)
      result = AgentSessionUsage.capture(session_id: SESSION, transcript_root: root)

      refute_nil result
      assert_equal "claude-opus-4-8", result.model
      assert_equal({ "input" => 150, "output" => 280, "cache_creation" => 15, "cache_read" => 3000 }, result.totals)
      assert_nil result.delta, "no baseline → no delta"
      refute result.usage?, "the first capture (no baseline) reports no usage"
    end
  end

  # A transcript can hold valid-JSON-but-NON-OBJECT lines (a bare number, array,
  # null, or boolean). sum_usage must skip them, not crash with a TypeError when
  # it reaches obj["type"] — otherwise the whole capture (and the move that calls
  # it) aborts. Regression for the rework on PR #121: `42` once raised mid-parse.
  def write_transcript_with_non_object_lines(root)
    dir = File.join(root, "-Users-alex-projects")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{SESSION}.jsonl"), <<~JSONL)
      42
      {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":200,"cache_creation_input_tokens":10,"cache_read_input_tokens":1000}}}
      [1,2,3]
      null
      true
      "a bare string is valid JSON too"
      {"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":80,"cache_creation_input_tokens":5,"cache_read_input_tokens":2000}}}
    JSONL
  end

  def test_non_object_json_lines_are_skipped_not_fatal
    Dir.mktmpdir do |root|
      write_transcript_with_non_object_lines(root)
      result =
        begin
          AgentSessionUsage.capture(session_id: SESSION, transcript_root: root)
        rescue StandardError => e
          flunk "a non-object JSON line must not raise, got #{e.class}: #{e.message}"
        end

      refute_nil result, "a non-object line must not crash the capture"
      assert_equal "claude-opus-4-8", result.model
      # Still sums the two valid assistant turns, the garbage lines skipped.
      assert_equal({ "input" => 150, "output" => 280, "cache_creation" => 15, "cache_read" => 3000 }, result.totals)
    end
  end

  def test_delta_against_a_baseline_yields_tokens_and_cost
    Dir.mktmpdir do |root|
      write_transcript(root)
      baseline = { "input" => 100, "output" => 200, "cache_creation" => 10, "cache_read" => 1000 }
      result = AgentSessionUsage.capture(session_id: SESSION, baseline: baseline, transcript_root: root)

      assert result.usage?
      # delta = second assistant turn only: input 50, output 80, cc 5, cr 2000
      assert_equal 2055, result.tokens_in   # 50 + 5 + 2000
      assert_equal 80, result.tokens_out
      # (50*5 + 80*25 + 5*5*2.0 + 2000*5*0.10) / 1e6 = 3300 / 1e6
      # cache-write now = 1h list rate (2.0x input), via the shared UsagePricing SoT.
      assert_in_delta 0.0033, result.cost, 0.00005
    end
  end

  def test_baseline_above_totals_floors_delta_at_zero
    Dir.mktmpdir do |root|
      write_transcript(root)
      huge = { "input" => 9_999, "output" => 9_999, "cache_creation" => 9_999, "cache_read" => 9_999 }
      result = AgentSessionUsage.capture(session_id: SESSION, baseline: huge, transcript_root: root)

      refute result.usage?, "a baseline above current totals must not report negative usage"
      assert_equal 0, result.tokens_out
    end
  end

  def test_missing_transcript_returns_nil
    Dir.mktmpdir do |root|
      assert_nil AgentSessionUsage.capture(session_id: SESSION, transcript_root: root)
      assert_nil AgentSessionUsage.capture(session_id: "", transcript_root: root)
    end
  end

  def test_price_uses_the_per_model_table
    buckets = { "input" => 1_000_000, "output" => 0, "cache_creation" => 0, "cache_read" => 0 }
    assert_in_delta 5.0, AgentSessionUsage.price(buckets, "claude-opus-4-8"), 0.0001
    assert_in_delta 3.0, AgentSessionUsage.price(buckets, "claude-sonnet-4-6"), 0.0001
    assert_in_delta 10.0, AgentSessionUsage.price(buckets, "claude-fable-5"), 0.0001
    assert_nil AgentSessionUsage.price(buckets, "some-unknown-model"), "an unpriced model yields nil cost"
  end

  def test_model_tier_suffix_is_normalized_for_pricing
    assert_equal "claude-opus-4-8", AgentSessionUsage.normalize_model("claude-opus-4-8[1m]")
    buckets = { "input" => 1_000_000, "output" => 0, "cache_creation" => 0, "cache_read" => 0 }
    assert_in_delta 5.0, AgentSessionUsage.price(buckets, "claude-opus-4-8[1m]"), 0.0001
  end

  def test_codex_transcript_uses_latest_cumulative_usage
    Dir.mktmpdir do |root|
      dir = File.join(root, "2026", "06", "26")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "rollout-2026-06-26T13-04-23-#{SESSION}.jsonl"), <<~JSONL)
        {"type":"turn_context","payload":{"model":"gpt-5.5"}}
        {"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":300,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200}}}}
        {"type":"event_msg","payload":{"info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":500,"output_tokens":280,"reasoning_output_tokens":80,"total_tokens":1780}}}}
      JSONL

      baseline = { "input" => 700, "output" => 200, "cache_creation" => 0, "cache_read" => 300 }
      result = AgentSessionUsage.capture(session_id: SESSION, provider: "codex", baseline: baseline, transcript_root: root)

      assert result.usage?
      assert_equal "gpt-5.5", result.model
      assert_equal({ "input" => 1000, "output" => 280, "cache_creation" => 0, "cache_read" => 500 }, result.totals)
      assert_equal 500, result.tokens_in
      assert_equal 80, result.tokens_out
      assert_equal 0.004, result.cost
    end
  end
end
