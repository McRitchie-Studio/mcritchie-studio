# frozen_string_literal: true

require "test_helper"

# [unit] THE REVIEWER FIX-FORWARD IS AN AUTHORSHIP ACT — the third moment
# Task#builder_roll_call had to grow, and the exclusion ReviewerSelector had to honour.
#
# THE DEFECT. A reviewer who fixes forward (a "zap") puts his own commit in the merged
# diff, so he is an author of that PR. But the author set (devops.built_by +
# devops.builders) is stamped ONLY by the build CLAIM, and a zap makes none — he
# pushes onto someone else's branch and claims nothing. So the exclusion set never
# grew, and `bin/reviewer-select` went on seating souls onto PRs carrying their own
# commits.
#
# MEASURED TWICE IN ONE NIGHT, on MERGED PRs (2026-09-09):
#   · #1321 — builder alex; steffon zapped be5579a5 while holding the light seat;
#     reviewer-select then seated STEFFON on a PR containing steffon's own commit.
#     A human caught it only because the orchestrator happened to mention the zap.
#   · #1322 — builder avi; the reviewer pushed 7113af85 to resolve a conflict, then
#     DISCLOSED it himself and asked that the set be read as {avi, jasper}. Nothing
#     on the record said so.
#
# WHY IT IS WORSE THAN A MISSING STAMP, and why every assertion below is about the
# SELECTOR rather than about the stamp. A blank built_by makes the selector fail
# CLOSED — it refuses and a human chooses. This fails OPEN: the set is populated and
# confident, just short by one. Nothing looks wrong. So a test that asserted only
# "the stamp was written" would pass against a selector that ignored the stamp
# entirely — which is the state this file exists to make impossible.
#
# THE HALF THAT MUST NOT MOVE. `built_by` must NOT re-point onto the zapper. A
# reviewer recorded as the CURRENT builder of the PR he reviewed is the same defect
# fully inverted, and a confidently-wrong author set is worse than a refusing one —
# the same rule Task#reviewer_taking_the_build? already enforces for a reviewer who
# takes the build. #test_built_by_still_names_the_builder is that half.
class ReviewerFixForwardAuthorTest < ActiveSupport::TestCase
  BUILDER_SESSION = "b1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"

  # A submitted task with ONE recorded author, exactly as the pipeline leaves it:
  # a named build claim, then a submit by that same session.
  def submitted_task(builder: "shannon")
    task = Task.create!(title: "Fix Forward Author Task", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend",
                                                  "repositories" => ["mcritchie-studio"] } })
    Current.task_event_actor = builder
    task.update!(stage: "building",
                 metadata: { "devops" => task.devops.merge(
                   ClaimLease.renewed(session: BUILDER_SESSION, nonce: "inst-B")
                 ) })
    Current.reset
    Current.task_event_actor = BUILDER_SESSION
    task.update!(stage: "submitted")
    task.reload
  ensure
    Current.reset
  end

  # What `bin/task fix-forward` PATCHes: one devops key, no stage move, no claim.
  def fix_forward!(task, *entries)
    task.update!(metadata: task.metadata.deep_merge("devops" => { "fix_forward" => entries }))
    task.reload
  end

  def decide(task, **kwargs)
    ReviewerSelector.new(task, **kwargs).decision
  end

  def seated(decision)
    Array(decision["reviewers"]).map { |reviewer| reviewer["slug"] }
  end

  # --- THE CONTROL: the state the bug leaves behind ---------------------------

  # Before anything is recorded, the zapper is a FREE reviewer of a PR he has
  # committed to. This is the measured #1321 shape, and it is asserted first so the
  # tests below cannot pass vacuously: if steffon were already excluded here for some
  # unrelated reason, everything after it would prove nothing.
  def test_control_unrecorded_zapper_is_still_a_free_reviewer
    decision = decide(submitted_task(builder: "shannon"))

    assert_includes decision["candidates"], "steffon",
                    "control: with no fix-forward on record steffon must still be a light candidate"
    refute_includes Array(decision["excluded_builders"]), "steffon"
    refute_includes Array(decision["builders"]), "steffon"
    assert decision["builder_known"], "control: one named builder is a settled author set"
  end

  # --- THE PROPERTY ------------------------------------------------------------

  # The whole point, stated as the selector states it. Recording the fix-forward must
  # change what the SELECTOR does, not merely what the record says.
  def test_recorded_fix_forward_author_is_excluded_from_the_light_seat
    task = fix_forward!(submitted_task(builder: "shannon"), "steffon")
    decision = decide(task)

    assert_includes Array(decision["builders"]), "steffon",
                    "a soul who pushed to the PR is an author of it"
    assert_includes Array(decision["excluded_builders"]), "steffon",
                    "and an author is dropped from the light pool"
    refute_includes seated(decision), "steffon",
                    "a soul never reviews a PR carrying his own commit"
    assert decision["builder_known"], "a NAMED fix-forward leaves the set complete"
  end

  # The accumulator half: the author already on record survives, and a second zapper
  # joins rather than replacing the first.
  def test_fix_forward_accumulates_without_dropping_the_builder
    task = fix_forward!(submitted_task(builder: "shannon"), "steffon")
    task = fix_forward!(task, "steffon", "jasper")
    decision = decide(task)

    assert_equal %w[shannon steffon jasper].sort, Array(decision["builders"]).sort
    assert_equal %w[jasper steffon].sort, (Array(decision["excluded_builders"]) & %w[jasper steffon]).sort
    refute_includes seated(decision), "steffon"
    refute_includes seated(decision), "jasper"
  end

  # THE HALF THAT MUST NOT MOVE. The zapper is an AUTHOR, never the CURRENT builder.
  def test_built_by_still_names_the_builder
    task = fix_forward!(submitted_task(builder: "shannon"), "steffon")

    assert_equal "shannon", task.devops["built_by"],
                 "a fix-forward must never re-point built_by onto the reviewer"
    assert_includes task.devops_builders, "steffon"
  end

  # The fold is SERVER-SIDE and idempotent: an unrelated later save neither drops the
  # zap author nor duplicates him.
  def test_a_later_unrelated_save_keeps_the_zap_author
    task = fix_forward!(submitted_task(builder: "shannon"), "steffon")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "pr_url" => "https://github.com/o/r/pull/7" }))
    task.reload

    assert_equal %w[shannon steffon], task.devops_builders
  end

  # --- THE FAIL-CLOSED HALF ----------------------------------------------------

  # A fix-forward nobody can attribute must REFUSE, not pass. "No fix-forward
  # happened" and "one happened and we cannot name who" are opposite facts, and only
  # the second has a commit in the diff whose author is somewhere in the pool.
  def test_unnamed_fix_forward_makes_the_author_set_incomplete
    task = fix_forward!(submitted_task(builder: "shannon"), "unattributed")
    decision = decide(task)

    refute decision["builder_known"],
           "an unattributable fix-forward leaves the author set INCOMPLETE — the CLI must refuse"
    assert_includes Array(decision["fix_forward_unnamed"]), "unattributed"
    refute_includes Array(decision["builders"]), "unattributed",
                    "a marker is not a soul and must never render as an author"
  end

  # And it CLEARS when the pusher is finally named — otherwise the refusal is a dead
  # end and the only way past it is the lever that lifts the guard entirely.
  def test_naming_the_pusher_clears_the_refusal
    task = fix_forward!(submitted_task(builder: "shannon"), "unattributed")
    refute decide(task)["builder_known"]

    decision = decide(fix_forward!(task, "steffon"))

    assert decision["builder_known"], "naming who pushed settles the question"
    assert_includes Array(decision["excluded_builders"]), "steffon"
  end

  # The caller's explicit override stays authoritative over the record, exactly as it
  # is for every other author source — the documented escape hatch out of a refusal.
  def test_builder_override_outranks_an_unnamed_fix_forward
    task = fix_forward!(submitted_task(builder: "shannon"), "unattributed")
    decision = decide(task, builder: "shannon,steffon")

    assert decision["builder_known"]
    assert_equal %w[shannon steffon].sort, Array(decision["builders"]).sort
  end

  # A typo'd handle is not a soul, so it must not read as an author — it reads as the
  # unnamed marker does, and refuses. An unrecognised slug must never do better than
  # silence (the rule Task.soul? already enforces for --builder).
  def test_a_non_soul_entry_never_becomes_an_author
    task = fix_forward!(submitted_task(builder: "shannon"), "stefon")

    refute_includes task.devops_builders, "stefon"
    refute decide(task)["builder_known"], "a fix-forward naming nobody is still a fix-forward"
  end
end
