# frozen_string_literal: true

require "test_helper"
require "open3"
require "json"
require "tmpdir"
require "fileutils"

# [integration] The session ↔ task join, driven through the REAL bin/agent-worktree
# on REAL files — both halves, in the order they actually happen.
#
# The unit tier proves the occupancy rule and the grader as pure decisions. What it
# cannot prove is that the two halves ever meet: that the writer's fields land in the
# marker the script actually writes, and that the reader's glob actually finds that
# marker on disk and grades it. Those are precisely the seams the defect lived in —
# two files that each held half the answer and never named each other — so they are
# what this tier spends its time on.
#
# ANCHOR PORTABILITY. `SessionIdentity.agent_process` walks the process ancestry for a
# long-lived `claude`/`codex` CLI. Run by an agent it finds one; run in CI it finds
# nothing. A test asserting on the real ancestry would therefore pass in one world and
# fail in the other. So the writer checks stub the anchor to the TEST'S OWN process —
# which is genuinely alive and genuinely gradeable — and the reader checks build their
# own process table entries the same way.
class DeskContextJoinTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin", "agent-worktree").to_s

  # Load the script (its `if $PROGRAM_NAME == __FILE__` guard suppresses dispatch),
  # stub the shelling-out helpers, run `body`, return what it printed.
  def in_script(body, env: {})
    script = <<~RUBY
      load #{BIN.inspect}
      # The mascot/color resolvers reach the board and git; none of them is what is
      # under test here, and all of them are slow. The SESSION fields are computed by
      # session_fields_for, which is left entirely real.
      def resolve_mascot(*) = "omanyte"
      def resolve_mascot_color(*) = "#B6A136"
      def resolve_mascot_emoji(*) = "🗿"
      def resolve_mascot_shiny(*) = false
      def resolve_app_color(*) = "#B57EDC"
      def git_branch(*) = "feat/demo"
      def git_head(*) = "abc1234"
      module SessionIdentity
        def self.agent_process(*)
          { pid: Process.pid, start: `ps -o lstart= -p \#{Process.pid}`.to_s.strip }
        end
      end
      #{body}
    RUBY
    out, err, status = Open3.capture3(SessionEnv.neutralized.merge(env), "ruby", "-e", script)
    assert status.success?, "bin/agent-worktree subprocess failed: #{status.inspect}\n#{err}"
    out
  end

  def payload_in(dir, session:, creating: false, env: {})
    body = <<~RUBY
      app = { "slug" => "mcritchie-studio", "display_name" => "McRitchie Studio", "repo" => #{dir.inspect} }
      values = { "APP_PORT" => "3007", "TASK_RECORD_SLUG" => "demo-task" }
      print JSON.generate(
        context_payload(app, "demo-task", values, #{dir.inspect}, creating: #{creating})
      )
    RUBY
    JSON.parse(in_script(body, env: SessionEnv.neutralized("CLAUDE_CODE_SESSION_ID" => session).merge(env)))
  end

  # --- the writer ------------------------------------------------------------------

  test "an occupant's session and anchor land in the marker the script writes" do
    Dir.mktmpdir do |dir|
      payload = payload_in(dir, session: "sess-occupant", creating: true)

      assert_equal "sess-occupant", payload["session_id"],
                   "the desk marker can finally say WHOSE desk it is"
      assert_equal "claude", payload["session_provider"]
      assert_operator payload["anchor_pid"].to_i, :>, 0, "the anchor pid rides with the session"
      refute_empty payload["anchor_started_at"].to_s,
                   "and its start time, which is what makes the pid proof rather than a guess"
      assert_equal 2, payload["schema_version"],
                   "schema 2 is what lets a reader tell honest silence from a pre-join marker"
      assert_equal "demo-task", payload["task_record_slug"],
                   "control: the task half of the join is still recorded exactly as before"
    end
  end

  # THE REGRESSION THAT WOULD BE WORSE THAN THE DEFECT. `status`/`whereami`/`bind-task`
  # all take an explicit <app> <task-slug> and run from anywhere, so an unconditional
  # stamp would let one conductor sweep write its own id onto every desk in the tree —
  # and every one of those rows would grade LIVE, because the conductor is alive.
  test "a peer refreshing the desk from outside never overwrites the occupant" do
    Dir.mktmpdir do |dir|
      occupant = payload_in(dir, session: "sess-occupant", creating: true)
      File.write(File.join(dir, ".agent-context.json"), JSON.pretty_generate(occupant))

      # A different session, not inside the desk, and NOT creating it.
      refreshed = payload_in(dir, session: "sess-conductor", creating: false)

      assert_equal "sess-occupant", refreshed["session_id"],
                   "the occupant's claim survived a peer's refresh"
      assert_equal occupant["anchor_pid"], refreshed["anchor_pid"]
      refute_equal "sess-conductor", refreshed["session_id"]
    end
  end

  test "re-running new over an existing marker is not a fresh claim" do
    Dir.mktmpdir do |dir|
      occupant = payload_in(dir, session: "sess-occupant", creating: true)
      File.write(File.join(dir, ".agent-context.json"), JSON.pretty_generate(occupant))

      # `new` passes creating: !marker_pre_existing — so a re-run over a live desk
      # arrives here as creating: false and must not take the desk from its holder.
      assert_equal "sess-occupant", payload_in(dir, session: "sess-newcomer", creating: false)["session_id"]
    end
  end

  test "a run naming no session leaves the marker's holder alone" do
    Dir.mktmpdir do |dir|
      occupant = payload_in(dir, session: "sess-occupant", creating: true)
      File.write(File.join(dir, ".agent-context.json"), JSON.pretty_generate(occupant))

      # No CLAUDE_CODE_SESSION_ID at all — a plain shell or CI run.
      body = <<~RUBY
        app = { "slug" => "mcritchie-studio", "display_name" => "MS", "repo" => #{dir.inspect} }
        print JSON.generate(context_payload(app, "demo-task", { "APP_PORT" => "3007" }, #{dir.inspect}))
      RUBY
      refreshed = JSON.parse(in_script(body))

      assert_equal "sess-occupant", refreshed["session_id"], "nobody must not erase somebody"
    end
  end

  # --- the reader ------------------------------------------------------------------

  def live_anchor
    { pid: Process.pid, started_at: `ps -o lstart= -p #{Process.pid}`.to_s.strip.squeeze(" ") }
  end

  # A projects root shaped like the real one, holding the markers the checks describe.
  def with_desks(markers)
    Dir.mktmpdir do |root|
      markers.each do |desk, marker|
        dir = File.join(root, "mcritchie-studio", ".worktrees", desk)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, ".agent-context.json"), JSON.pretty_generate(marker))
      end
      yield root
    end
  end

  def holder(root, *args)
    out, _err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => root), "ruby", BIN, "holder", *args
    )
    [out, status.exitstatus]
  end

  def marker(task:, session:, pid: nil, started_at: nil, schema: 2)
    {
      "schema_version" => schema, "app" => "mcritchie-studio", "task_record_slug" => task,
      "session_id" => session, "session_provider" => "claude",
      "anchor_pid" => pid, "anchor_started_at" => started_at
    }.compact
  end

  test "reverse lookup names the live session holding a task" do
    anchor = live_anchor
    with_desks(
      "held" => marker(task: "blocked-task", session: "sess-holder", **anchor.transform_keys { |k| k }),
      "other" => marker(task: "unrelated", session: "sess-other", pid: anchor[:pid], started_at: anchor[:started_at])
    ) do |root|
      out, code = holder(root, "blocked-task")

      assert_equal 0, code, "exit 0 means a LIVE holder was found — the answer a blocked ship needs"
      assert_includes out, "sess-holder", "the session id the operator can now message directly"
      assert_includes out, "LIVE"
      refute_includes out, "sess-other", "an unrelated desk is not swept in"
    end
  end

  # ACCEPTANCE: a dead session anchor grades as a corpse. pid 2 is launchd's
  # neighbourhood on macOS and is never this test's anchor; the start time cannot
  # match, so the claim is provably not ours either way.
  test "a dead session anchor grades as a corpse and does not block the caller" do
    with_desks(
      "stale" => marker(task: "abandoned-task", session: "sess-gone", pid: 2,
                        started_at: "Mon Jan  1 00:00:00 2001")
    ) do |root|
      out, code = holder(root, "abandoned-task")

      assert_equal 1, code, "exit 1: a desk was found, but nobody is holding it"
      refute_includes out, "LIVE", "a corpse is never reported as a live holder"
      assert_match(/RECYCLED|DEAD/, out)
      assert_includes out, "holder is gone", "and the reader is told what that means for its next move"
    end
  end

  # The forward direction — the second wall hit on 2026-09-01. An agent could name the
  # holding session id and still could not learn whether it was a builder or a reviewer
  # without messaging two peers.
  test "a session's desks are reported as a set" do
    anchor = live_anchor
    with_desks(
      "one" => marker(task: "task-one", session: "sess-multi", pid: anchor[:pid], started_at: anchor[:started_at]),
      "two" => marker(task: "task-two", session: "sess-multi", pid: anchor[:pid], started_at: anchor[:started_at])
    ) do |root|
      out, code = holder(root, "--session", "sess-multi", "--json")

      assert_equal 0, code
      parsed = JSON.parse(out)
      assert_equal %w[task-one task-two], parsed["matches"].map { |m| m["task_slug"] }.sort,
                   "an orchestrator legitimately holds several desks — reported, not resolved away"
    end
  end

  # THE DISTINCTION A BACKFILL WOULD HAVE DESTROYED, now visible at the surface: a desk
  # nobody sat at, versus a marker whose writer could never have said.
  test "an unclaimed desk and a pre-join marker are told apart" do
    with_desks(
      "quiet" => marker(task: "quiet-task", session: nil),
      "old" => marker(task: "old-task", session: nil, schema: 1)
    ) do |root|
      quiet, = holder(root, "quiet-task")
      old, = holder(root, "old-task")

      assert_includes quiet, "honest silence", "no session here is a fact, not a failed write"
      assert_includes old, "PREDATES", "and a pre-join marker says so, with a remedy"
      assert_includes old, "refresh the desk"
    end
  end

  test "a task nobody holds answers plainly rather than erroring" do
    with_desks("held" => marker(task: "other-task", session: "sess-x")) do |root|
      out, code = holder(root, "nobody-holds-this")

      assert_equal 1, code
      assert_includes out, "no desk holds"
      assert_includes out, "1 desk(s) scanned", "the scan's size is reported, so an empty answer is checkable"
    end
  end

  test "the holder arm accounts for its arguments like every other" do
    _out, _err, status = Open3.capture3(
      SessionEnv.neutralized, "ruby", BIN, "holder", "some-task", "--nonsense"
    )
    assert_equal 2, status.exitstatus, "an argument the arm cannot account for REFUSES, exit 2"
  end
end
