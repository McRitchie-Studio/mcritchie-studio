# frozen_string_literal: true

# Unit test for AgentFanoutUsage — the fan-out reconciler that reads a session's
# CHILD subagent transcripts and partitions their spend across the activities that
# authored it. Plain Ruby (no Rails); also picked up by `bin/rails test`.
#
#   ruby -Itest test/lib/agent_fanout_usage_test.rb
#
# The fixture mirrors the real pr-review shape that exposed the bug (prod session
# 84293426): a quiet PARENT + an AVI supervisor child that narrates the nil lane +
# a CARL reviewer child that narrates its own soul lane.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../lib/agent_fanout_usage"

class AgentFanoutUsageTest < Minitest::Test
  SID = "84293426-59c9-4874-a812-1dc88024e68b"
  PROJ = "-Users-alex-projects"

  def assistant_line(id:, ts:, out:, input: 0, cc: 0, cr: 0, model: "claude-opus-4-8")
    {
      "type" => "assistant", "uuid" => "u-#{id}-#{ts}", "timestamp" => ts,
      "message" => {
        "id" => id, "model" => model,
        "usage" => {
          "input_tokens" => input, "output_tokens" => out,
          "cache_creation_input_tokens" => cc, "cache_read_input_tokens" => cr
        }
      }
    }.to_json
  end

  # Build the parent + two children fixture tree. Returns the transcript_root.
  def build_tree(root, include_children: true, orphan: false)
    proj = File.join(root, PROJ)
    FileUtils.mkdir_p(proj)

    parent = []
    # P1 @ 03:09:10 — serialized TWICE (same message.id) → must count ONCE.
    parent << assistant_line(id: "msg_p1", ts: "2026-07-11T03:09:10.000Z", input: 100, out: 50, cc: 10, cr: 1000)
    parent << assistant_line(id: "msg_p1", ts: "2026-07-11T03:09:10.500Z", input: 100, out: 50, cc: 10, cr: 1000)
    parent << %({"type":"user","message":{"role":"user"}})           # noise
    parent << "not json — skip me"                                    # noise
    parent << assistant_line(id: "msg_p2", ts: "2026-07-11T03:11:58.000Z", input: 200, out: 80, cc: 20, cr: 2000)
    # P3 @ 03:20:00 — AFTER the last nil-lane activity closed → orphan, dropped.
    parent << assistant_line(id: "msg_p3", ts: "2026-07-11T03:20:00.000Z", input: 999, out: 999, cc: 999, cr: 999) if orphan
    File.write(File.join(proj, "#{SID}.jsonl"), parent.join("\n") + "\n")

    return root unless include_children

    subs = File.join(proj, SID, "subagents")
    FileUtils.mkdir_p(subs)

    # Avi supervisor child — narrates the NIL lane (no avi-lane activity exists).
    File.write(File.join(subs, "agent-avi1.meta.json"),
               { "agentType" => "avi", "description" => "summon Avi supervisor", "spawnDepth" => 1 }.to_json)
    File.write(File.join(subs, "agent-avi1.jsonl"),
               [assistant_line(id: "msg_a1", ts: "2026-07-11T03:12:30.000Z", input: 300, out: 90, cc: 30, cr: 3000),
                assistant_line(id: "msg_a2", ts: "2026-07-11T03:14:00.000Z", input: 400, out: 100, cc: 40, cr: 4000)].join("\n") + "\n")

    # Carl reviewer child — narrates its OWN soul lane (--agent carl).
    File.write(File.join(subs, "agent-carl1.meta.json"),
               { "agentType" => "carl", "description" => "summon light review: carl", "spawnDepth" => 2, "parentAgentId" => "avi1" }.to_json)
    File.write(File.join(subs, "agent-carl1.jsonl"),
               [assistant_line(id: "msg_c1", ts: "2026-07-11T03:16:45.000Z", input: 500, out: 110, cc: 50, cr: 5000),
                assistant_line(id: "msg_c2", ts: "2026-07-11T03:16:50.000Z", input: 600, out: 120, cc: 60, cr: 6000)].join("\n") + "\n")

    root
  end

  # The board's activity windows (string keys + ISO strings, as the API delivers).
  def windows
    [
      { "id" => 1, "agent" => nil,    "opened_at" => "2026-07-11T03:09:07Z", "closed_at" => "2026-07-11T03:11:56Z" },
      { "id" => 2, "agent" => "",     "opened_at" => "2026-07-11T03:11:56Z", "closed_at" => "2026-07-11T03:13:00Z" },
      { "id" => 3, "agent" => nil,    "opened_at" => "2026-07-11T03:13:00Z", "closed_at" => "2026-07-11T03:15:00Z" },
      { "id" => 4, "agent" => "carl", "opened_at" => "2026-07-11T03:16:43Z", "closed_at" => nil } # never closed
    ]
  end

  def patches_by_id(patches)
    patches.each_with_object({}) { |p, h| h[p["activity_id"]] = p }
  end

  def test_partitions_spend_per_authoring_transcript
    Dir.mktmpdir do |root|
      build_tree(root)
      patches = AgentFanoutUsage.reconcile(session_id: SID, activities: windows, transcript_root: root)
      by = patches_by_id(patches)

      # act1: parent P1 only, counted ONCE despite the duplicate line.
      assert_equal 110, by[1]["tokens_in"], "P1 input+cc, deduped by message.id"
      assert_equal 50,  by[1]["tokens_out"]
      assert_equal 1000, by[1]["cache_read_tokens"]

      # act2: parent P2 (03:11:58) + Avi A1 (03:12:30) — the supervisor's nil-lane spend
      # merges with the parent's in the same window.
      assert_equal 220 + 330, by[2]["tokens_in"]
      assert_equal 80 + 90,   by[2]["tokens_out"]
      assert_equal 2000 + 3000, by[2]["cache_read_tokens"]

      # act3: Avi A2 only (parent is quiet here — the whole point of the bug).
      assert_equal 440, by[3]["tokens_in"]
      assert_equal 100, by[3]["tokens_out"]

      # act4 (carl lane, never closed): both Carl turns.
      assert_equal 550 + 660, by[4]["tokens_in"]
      assert_equal 110 + 120, by[4]["tokens_out"]
      assert_equal 5000 + 6000, by[4]["cache_read_tokens"]
    end
  end

  def test_rows_reconcile_to_the_total_distinct_spend
    Dir.mktmpdir do |root|
      build_tree(root)
      patches = AgentFanoutUsage.reconcile(session_id: SID, activities: windows, transcript_root: root)

      # Every distinct turn's fresh spend, counted once: P1 110, P2 220, A1 330,
      # A2 440, C1 550, C2 660 = 2310.
      assert_equal 2310, patches.sum { |p| p["tokens_in"] }
      assert_equal 50 + 80 + 90 + 100 + 110 + 120, patches.sum { |p| p["tokens_out"] }
    end
  end

  def test_cost_priced_for_the_dominant_model
    Dir.mktmpdir do |root|
      build_tree(root)
      patches = AgentFanoutUsage.reconcile(session_id: SID, activities: windows, transcript_root: root)
      by = patches_by_id(patches)

      by.each_value { |p| assert_equal "claude-opus-4-8", p["model"] }
      # act4 opus: (1100 in *5 + 230 out *25 + 110 cc *2*5 + 11000 cr *0.1*5)/1e6
      # = 0.01785, stored at the cost column's 4-decimal precision → 0.0179.
      expected = (1100 * 5 + 230 * 25 + 110 * 2 * 5 + 11_000 * 0.1 * 5) / 1e6
      assert_in_delta expected, by[4]["cost"], 0.0001
      assert by.values.all? { |p| p["cost"].to_f.positive? }
    end
  end

  def test_no_children_returns_no_patches
    Dir.mktmpdir do |root|
      build_tree(root, include_children: false)
      patches = AgentFanoutUsage.reconcile(session_id: SID, activities: windows, transcript_root: root)
      assert_empty patches, "a plain (non-fan-out) session must not disturb live measurements"
    end
  end

  def test_turn_after_final_lane_activity_close_is_dropped_as_orphan
    Dir.mktmpdir do |root|
      build_tree(root, orphan: true) # adds P3 @ 03:20:00, after act3 closed 03:15:00
      patches = AgentFanoutUsage.reconcile(session_id: SID, activities: windows, transcript_root: root)
      by = patches_by_id(patches)

      assert_equal 440, by[3]["tokens_in"], "the orphan turn must not inflate the last activity"
      # The orphan's 999 fresh spend is dropped, so the partition total is unchanged.
      assert_equal 2310, patches.sum { |p| p["tokens_in"] }, "an unnarrated orphan turn is not attributed to any row"
    end
  end

  def test_accepts_symbol_keys_and_time_objects
    Dir.mktmpdir do |root|
      build_tree(root)
      sym_windows = windows.map do |w|
        { id: w["id"], agent: w["agent"],
          opened_at: (w["opened_at"] && Time.parse(w["opened_at"])),
          closed_at: (w["closed_at"] && Time.parse(w["closed_at"])) }
      end
      patches = AgentFanoutUsage.reconcile(session_id: SID, activities: sym_windows, transcript_root: root)
      assert_equal 2310, patches.sum { |p| p["tokens_in"] }
    end
  end
end
