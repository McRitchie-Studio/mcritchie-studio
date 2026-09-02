# frozen_string_literal: true

# [unit] DeskContext — the session half of the desk marker, and the join it enables.
#
# Pure and script-free. Every decision under test here is IO-free by construction:
# `claiming?` takes its pwd, `stamp` takes what is on disk, and `grade` takes a
# process TABLE rather than reading one. So the whole occupancy rule and the whole
# grader are provable without a desk, a worktree, or a spawned process — which is
# what lets the integration tier spend its time on the round trip instead.
#
# Run directly:  ruby -Itest test/lib/desk_context_test.rb
require "minitest/autorun"
require_relative "../../bin/lib/desk_context"

class DeskContextTest < Minitest::Test
  DESK = "/projects/mcritchie-studio/.worktrees/agent-presence"

  # --- the occupancy rule ----------------------------------------------------------

  def test_a_session_working_inside_the_desk_may_claim_it
    assert DeskContext.claiming?(DESK, pwd: DESK),
           "the session standing at the desk is the one entitled to speak for it"
    assert DeskContext.claiming?(DESK, pwd: "#{DESK}/app/models"),
           "bin/ commands run from subdirectories — occupancy is not depth-sensitive"
  end

  def test_an_inspection_from_outside_never_claims
    refute DeskContext.claiming?(DESK, pwd: "/projects/mcritchie-studio"),
           "`status <app> <task>` from the primary is an INSPECTION, not an occupancy"
    refute DeskContext.claiming?(DESK, pwd: "/projects/turf-monster/.worktrees/other"),
           "one agent inspecting another's desk must not overwrite whose desk it is"
  end

  # THE CASE A PREFIX TEST GETS WRONG, and it is not hypothetical: `agent-presence`
  # and `agent-presence-reader` are both live desks on this machine right now. Under
  # a `start_with?` containment test the shorter desk would claim the longer one's
  # marker every time its occupant ran a command.
  def test_a_desk_whose_slug_prefixes_another_does_not_claim_it
    refute DeskContext.claiming?(DESK, pwd: "#{DESK}-reader"),
           "containment is by PATH SEGMENT, never by string prefix"
    assert DeskContext.claiming?("#{DESK}-reader", pwd: "#{DESK}-reader"),
           "control: the longer desk still claims itself"
  end

  def test_creating_the_desk_is_the_one_claim_from_outside
    assert DeskContext.claiming?(DESK, pwd: "/projects/mcritchie-studio", creating: true),
           "`new` runs from the primary and the desk did not exist — nobody else can be at it"
  end

  # --- the stamp decision ----------------------------------------------------------

  def test_an_occupant_records_session_provider_parent_and_anchor
    fields = DeskContext.stamp(
      existing: nil, session: %w[sess-a claude],
      anchor: { pid: 4242, start: "Mon Sep  1 09:00:00 2026" },
      parent: "root-1", claiming: true
    )

    assert_equal "sess-a", fields["session_id"]
    assert_equal "claude", fields["session_provider"]
    assert_equal "root-1", fields["parent_session_id"]
    assert_equal 4242, fields["anchor_pid"]
    assert_equal "Mon Sep  1 09:00:00 2026", fields["anchor_started_at"],
                 "the raw ps lstart string is what makes the pid PROOF rather than a guess"
  end

  # THE REGRESSION THIS FILE EXISTS FOR. A conductor sweeping every desk with
  # `status` would otherwise write its own session id onto all of them, and each row
  # would then grade `live` because the conductor IS alive. That is a wrong answer
  # delivered with full confidence — strictly worse than the silence it replaced.
  def test_a_non_occupant_carries_the_existing_claim_forward_untouched
    existing = {
      "session_id" => "occupant", "session_provider" => "codex",
      "parent_session_id" => "root-9", "anchor_pid" => 77, "anchor_started_at" => "Mon Sep  1 08:00:00 2026"
    }

    fields = DeskContext.stamp(
      existing: existing, session: %w[conductor claude],
      anchor: { pid: 999, start: "Mon Sep  1 10:00:00 2026" }, claiming: false
    )

    assert_equal "occupant", fields["session_id"], "the occupant's claim survives a peer's refresh"
    assert_equal 77, fields["anchor_pid"]
    assert_equal "codex", fields["session_provider"]
    refute_includes fields.values, "conductor", "the inspecting session appears nowhere in the marker"
  end

  # Nobody must not erase somebody. A plain shell or CI run names no session, and a
  # refresh from one is not evidence the desk was vacated.
  def test_a_session_less_run_preserves_rather_than_blanks
    existing = { "session_id" => "occupant", "anchor_pid" => 77 }
    fields = DeskContext.stamp(existing: existing, session: [nil, nil], claiming: true)

    assert_equal "occupant", fields["session_id"], "CI refreshing a marker does not vacate the desk"
    assert_equal 77, fields["anchor_pid"]
  end

  def test_a_fresh_desk_with_no_session_stamps_nothing
    assert_empty DeskContext.stamp(existing: nil, session: [nil, nil], claiming: true),
                 "no session and no prior marker means there is nothing honest to write"
  end

  # An unresolvable anchor is recorded as a claim WITHOUT proof rather than dropped —
  # the reader grades it `unverifiable` and says so, which is the honest report.
  def test_a_session_with_no_anchor_is_still_a_claim
    fields = DeskContext.stamp(existing: nil, session: %w[sess-a claude], anchor: nil, claiming: true)

    assert_equal "sess-a", fields["session_id"]
    assert_nil fields["anchor_pid"], "we did not find the anchor, so we do not invent one"
  end

  # THE FABRICATED-PROOF CASE. A new occupant that could not resolve its own anchor
  # must not INHERIT the previous occupant's. The caller merges these fields over the
  # existing marker, so leaving the anchor keys out would leave a stale pid and start
  # time sitting beside a NEW session id — a claim that grades `live` on somebody
  # else's process. Nulling them is what makes the resulting claim honestly
  # ungradeable instead of falsely proven.
  def test_a_new_occupant_without_an_anchor_does_not_inherit_the_old_one
    existing = {
      "session_id" => "sess-old", "anchor_pid" => 4242,
      "anchor_started_at" => "Mon Sep  1 09:00:00 2026"
    }
    fields = DeskContext.stamp(existing: existing, session: %w[sess-new claude], anchor: nil, claiming: true)

    assert_equal "sess-new", fields["session_id"], "the desk changed hands"
    assert_nil fields["anchor_pid"], "and the old occupant's proof did not come with it"
    assert_nil fields["anchor_started_at"]
    assert_includes fields.keys, "anchor_pid",
                    "the key must be SENT as nil — omitting it lets the stale value survive the merge"
  end

  def test_stamp_returns_only_the_session_fields_so_the_caller_merges
    fields = DeskContext.stamp(
      existing: nil, session: %w[sess-a claude],
      anchor: { pid: 1, start: "x" }, parent: nil, claiming: true
    )

    assert_empty fields.keys - DeskContext::SESSION_FIELDS,
                 "a whole-hash write here would drop app_color, mascot and every other marker field"
  end

  # --- the grader ------------------------------------------------------------------

  def table(*rows)
    rows.map { |pid, started| { pid: pid, pgid: pid, state: "S", started_at: started, command: "claude" } }
  end

  def context(**over)
    {
      "schema_version" => DeskContext::SCHEMA_VERSION, "session_id" => "sess-a",
      "session_provider" => "claude", "anchor_pid" => 4242,
      "anchor_started_at" => "Mon Sep  1 09:00:00 2026"
    }.merge(over.transform_keys(&:to_s))
  end

  def test_a_matching_anchor_grades_live
    verdict, = DeskContext.grade(context: context, table: table([4242, "Mon Sep  1 09:00:00 2026"]))
    assert_equal :live, verdict
  end

  def test_a_missing_anchor_process_grades_dead
    verdict, = DeskContext.grade(context: context, table: table([77, "Mon Sep  1 09:00:00 2026"]))
    assert_equal :dead, verdict, "nothing alive at that pid — a corpse, graded on the very next read"
  end

  # The pid was reused. This desk's holder is gone, and we say so WITHOUT ever
  # treating the stranger as ours.
  def test_a_reused_pid_grades_recycled
    verdict, = DeskContext.grade(context: context, table: table([4242, "Mon Sep  1 11:11:11 2026"]))
    assert_equal :recycled, verdict
  end

  def test_a_claim_with_no_recorded_start_grades_unverifiable
    verdict, = DeskContext.grade(
      context: context("anchor_started_at" => nil), table: table([4242, "Mon Sep  1 09:00:00 2026"])
    )
    assert_equal :unverifiable, verdict, "alive but unprovable is NAMED, never silently trusted or discarded"
    assert DeskContext.live?(:unverifiable), "and it counts as held — ties break toward protecting live work"
  end

  def test_a_claim_naming_no_pid_grades_unverifiable_not_dead
    verdict, = DeskContext.grade(context: context("anchor_pid" => nil), table: table)
    assert_equal :unverifiable, verdict,
                 "a session id with no anchor is a claim we cannot grade — it is still a claim"
  end

  # THE DISTINCTION THE WHOLE DIAGNOSIS TURNS ON. Half of all sessions genuinely hold
  # no task, so a desk nobody sat down at is honest silence — not a corpse, and not a
  # failed write.
  def test_a_desk_with_no_session_grades_unclaimed_not_dead
    verdict, detail = DeskContext.grade(context: context("session_id" => nil), table: table)

    assert_equal :unclaimed, verdict
    refute DeskContext.live?(verdict)
    refute detail[:stale_schema], "a session-aware writer recorded this silence on purpose"
  end

  # And the case a reader would otherwise report identically while meaning something
  # completely different: a marker whose writer predated the join could never have
  # answered. Same grade, different remedy — refresh the desk.
  def test_a_pre_join_marker_is_flagged_as_stale_schema
    _, detail = DeskContext.grade(
      context: { "schema_version" => 1, "app" => "mcritchie-studio" }, table: table
    )

    assert detail[:stale_schema], "schema 1 predates the session fields — no answer was ever recorded"
    assert_equal 1, detail[:schema_version]
  end

  # --- the join --------------------------------------------------------------------

  def desks_fixture
    [
      { desk: "a", task_slug: "task-one", grade: :live,
        detail: { session_id: "sess-a", parent_session_id: "root-1" } },
      { desk: "b", task_slug: "task-two", grade: :live,
        detail: { session_id: "sess-a", parent_session_id: "root-1" } },
      { desk: "c", task_slug: "task-one", grade: :dead, detail: { session_id: "sess-b" } },
      { desk: "d", task_slug: "task-three", grade: :live, detail: { session_id: "sess-c" } }
    ]
  end

  def test_reverse_lookup_finds_every_desk_holding_the_task
    found = DeskContext.holders_of("task-one", desks: desks_fixture)

    assert_equal %w[a c], found.map { |d| d[:desk] }
    assert_equal 1, found.count { |d| DeskContext.live?(d[:grade]) },
                 "one live holder and one corpse — the caller needs them told apart"
  end

  # MEASURED 2026-09-01: one `claude` CLI process hosts MANY concurrent sessions —
  # pid 60790 anchored four at once, three of them mid-`bin/ship` on unrelated tasks.
  # So the anchor is one-to-MANY with sessions, and `session_id` is the only unique
  # key here. This pins that: two DIFFERENT sessions sharing one anchor stay two
  # holders, and neither the grade nor the join collapses them.
  def test_two_sessions_sharing_one_anchor_stay_two_holders
    shared = { "anchor_pid" => 4242, "anchor_started_at" => "Mon Sep  1 09:00:00 2026" }
    live = table([4242, "Mon Sep  1 09:00:00 2026"])

    a, = DeskContext.grade(context: context(**shared, "session_id" => "sess-a"), table: live)
    b, = DeskContext.grade(context: context(**shared, "session_id" => "sess-b"), table: live)
    assert_equal %i[live live], [a, b], "a shared host is alive for every session it hosts"

    desks = [
      { desk: "a", task_slug: "task-one", grade: :live, detail: { session_id: "sess-a" } },
      { desk: "b", task_slug: "task-two", grade: :live, detail: { session_id: "sess-b" } }
    ]
    assert_equal ["a"], DeskContext.desks_of_session("sess-a", desks: desks).map { |d| d[:desk] },
                 "the join is on session_id — a shared anchor must never merge two sessions into one"
  end

  def test_reverse_lookup_of_an_unheld_task_is_empty_not_an_error
    assert_empty DeskContext.holders_of("nobody-holds-this", desks: desks_fixture)
    assert_empty DeskContext.holders_of(nil, desks: desks_fixture)
  end

  # An orchestrator legitimately holds several desks at once. A rule demanding
  # exactly one would recreate the very lie a backfill would have told.
  def test_a_session_holds_its_tasks_as_a_set
    found = DeskContext.desks_of_session("sess-a", desks: desks_fixture)

    assert_equal %w[task-one task-two], found.map { |d| d[:task_slug] },
                 "holding two tasks is legitimate, not a conflict to resolve"
  end

  # So five subagent desks read as ONE operator's fan-out rather than five
  # independent claimants competing for the machine.
  def test_a_fan_out_root_finds_its_children
    found = DeskContext.desks_of_session("root-1", desks: desks_fixture)

    assert_equal %w[a b], found.map { |d| d[:desk] }
    refute_includes found.map { |d| d[:desk] }, "d", "an unrelated session is not swept into the fan-out"
  end
end
