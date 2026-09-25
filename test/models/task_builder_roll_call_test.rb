# frozen_string_literal: true

# THE AUTHOR SET — Task#builder_roll_call, the memory devops.built_by cannot keep.
#
# `built_by` holds ONE soul and #builder_to_stamp rule 1 RE-POINTS it on an explicit
# re-claim, so a mid-build handoff (a session limit kills a builder, another soul
# finishes the job) OVERWRITES the first author. Measured 2026-08-30 on two tasks in
# one sitting: credential-prose-tells-truth reads built_by=avi and
# agent-flag-silently-drops reads built_by=steffon, yet ALEX wrote the tests on the
# first and the whole rework on the second. `bin/reviewer-select` then seated Xan as
# the LIGHT on Xan's own diff (PR #1081).
#
# `builders` accumulates instead — append-only, SERVER-OWNED (absent from
# DEVOPS_KEYS, so no client can write or shrink it). A claim that names NOBODY adds
# nobody: the UNNAMED marker (devops.builders_unattributed) was deleted in devops-v3
# 4b-ii-b, because authors are also derived from git (Task#derived_authors).
require "test_helper"

class TaskBuilderRollCallTest < ActiveSupport::TestCase
  # UUID-shaped, like a real session id — Task#disowned? branches on SOUL_SLUG, so a
  # soul-shaped stand-in would quietly take a different path (see
  # test/models/task_build_claim_invariant_test.rb).
  STEFFON_SESSION = "s1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  ALEX_SESSION    = "s2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"

  # A build claim as the API delivers it: `stage: building` with the claiming
  # session on the event (Current.task_build_claim + task_event_session).
  def claim!(task, actor: nil, session: STEFFON_SESSION, devops: {})
    Current.task_event_actor = actor
    Current.task_build_claim = true
    Current.task_event_session = session
    task.update!(stage: "building", metadata: { "devops" => task.devops.merge(devops) })
  ensure
    Current.reset
  end

  # The HANDOFF moment. `bin/task move <slug> submitted` defaults the event actor to
  # the MOVER's session (bin/task: `event["actor"] = mover_session`), so a bare
  # submit carries the shipping session and `--actor <soul>` overrides it — exactly
  # the two shapes claim! models one stage earlier.
  def submit!(task, actor: nil)
    Current.task_event_actor = actor
    task.update!(stage: "submitted")
  ensure
    Current.reset
  end

  def new_task
    Task.create!(title: "Author Roll Call Task", stage: "designed", metadata: { "devops" => {} })
  end

  def authors(task) = task.reload.devops["builders"]
  def unattributed(task) = task.reload.devops["builders_unattributed"]

  # --- ACCUMULATE: a handoff appends, it does not overwrite -------------------

  test "a handoff to a second soul records BOTH authors" do
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    assert_equal %w[steffon], authors(task)

    claim!(task, actor: "xan", session: ALEX_SESSION)

    assert_equal "xan", task.reload.devops["built_by"], "built_by still names the CURRENT builder"
    assert_equal %w[steffon xan], authors(task), "and the set remembers the one it replaced"
  end

  test "the set is seeded from a built_by stamped before the accumulator existed" do
    task = new_task
    task.update_columns(metadata: { "devops" => { "built_by" => "shannon" } })

    claim!(task.reload, actor: "xan", session: ALEX_SESSION)

    assert_equal %w[shannon xan], authors(task), "the legacy author is not lost on the next claim"
  end

  test "a client cannot shrink the author set through a raw whole-column metadata write" do
    # This drives the raw whole-column write directly — the shape a --checks update
    # that echoes none of these keys leaves at the model. If that erased the set, the
    # record could be laundered clean between the handoff and the review.
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: "xan", session: ALEX_SESSION)

    task.update!(metadata: { "devops" => { "checks_run" => ["[unit] something"] } })

    assert_equal %w[steffon xan], authors(task), "the server rebuilds the set on every save"
  end

  test "a re-claim by an author already on record adds nobody twice" do
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: "steffon", session: STEFFON_SESSION)

    assert_equal %w[steffon], authors(task)
  end

  # --- THE UNNAMED MARKER IS GONE -------------------------------------------

  test "an anonymous claim by a DIFFERENT session adds nobody and marks nothing" do
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)

    claim!(task, actor: nil, session: ALEX_SESSION)

    assert_equal %w[steffon], authors(task), "steffon is still the only name we have"
    assert_nil unattributed(task), "the UNNAMED marker is deleted — nothing records the session"
  end

  test "a FIRST claim that names nobody stamps no author" do
    task = new_task
    claim!(task, actor: nil, session: STEFFON_SESSION)

    assert_nil authors(task)
    assert_nil task.reload.devops["built_by"]
  end

  # --- THE ROSTER: an unrecognised soul is never stamped ----------------------

  test "a typo'd actor is not stamped as the builder" do
    # `--actor stefon` (one f) matched Task::SOUL_SLUG, so it was STAMPED, read as a
    # KNOWN builder, and excluded nobody — the fail-closed refusal lifted by a value
    # identifying no one. It must do no better than silence.
    task = new_task
    claim!(task, actor: "stefon", session: STEFFON_SESSION)

    assert_nil task.reload.devops["built_by"], "a phantom must never reach the record"
    assert_nil authors(task)
  end

  test "a typo'd actor falls through to the assigned agent rather than winning" do
    task = Task.create!(title: "Typo Actor Falls Through", stage: "designed",
                        agent_slug: "shannon", metadata: { "devops" => {} })

    claim!(task, actor: "stefon", session: STEFFON_SESSION)

    assert_equal "shannon", task.reload.devops["built_by"], "rule 1 no longer fires on a non-soul"
    assert_equal %w[shannon], authors(task)
  end

  test "a typo'd persona does not fill a blank builder" do
    task = new_task
    claim!(task, actor: nil, session: STEFFON_SESSION, devops: { "persona" => "jaspar" })

    assert_nil task.reload.devops["built_by"]
  end

  test "Task.soul? accepts every seeded soul and rejects near-misses" do
    Task::SOUL_ROSTER.each { |soul| assert Task.soul?(soul), "#{soul} is a real soul" }
    %w[stefon shanon jaspar carll alexx sess none].each do |typo|
      refute Task.soul?(typo), "#{typo} is not on the roster"
    end
  end

  test "Task.soul? keeps its static floor when the Agent table is unreadable" do
    Agent.stub(:pluck, ->(*) { raise ActiveRecord::StatementInvalid, "no such table" }) do
      assert Task.soul?("carl"), "a real soul survives a DB outage"
      refute Task.soul?("stefon"), "and a typo is still not a soul"
    end
  end

  # --- the exclusion this all exists to feed ---------------------------------

  test "end to end: a handoff leaves NEITHER author in the reviewer pool" do
    task = new_task
    task.update!(metadata: { "devops" => task.devops.merge("shape" => "backend") })
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: "xan", session: ALEX_SESSION)

    seated = ReviewerSelector.select(task.reload).map { |r| r["slug"] }

    refute_includes seated, "xan", "the co-author whose tests are in the diff"
    refute_includes seated, "steffon", "the soul who opened the desk"
    assert_equal 2, seated.uniq.size, "a pair still forms"
  end

  test "end to end: an unnamed handoff still selects, excluding the named author" do
    task = new_task
    task.update!(metadata: { "devops" => task.devops.merge("shape" => "backend") })
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: nil, session: ALEX_SESSION)

    decision = ReviewerSelector.explain(task.reload)

    assert_equal true, decision["builder_known"], "a named author on record is a known set"
    refute_includes ReviewerSelector.select(task.reload).map { |r| r["slug"] }, "steffon"
  end

  # --- THE AUTHOR WHO NEVER CLAIMED (the submit half) -------------------------
  #
  # Everything above keys on the CLAIM. PR #1094 was the shape it cannot see:
  # shannon's agent claimed the task and died to a session limit with NOTHING
  # committed; ALEX wrote the whole diff and both test files, and shipped it. The
  # set held only shannon, so the selector excluded a soul who wrote nothing and
  # left the real author in the pool at xan:0.9968, ranked 3rd.

  test "shipping from a session that never claimed adds nobody" do
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)

    submit!(task, actor: ALEX_SESSION)

    assert_equal %w[shannon], authors(task), "a bare session names nobody"
    assert_nil unattributed(task), "and the UNNAMED marker is not written"
  end

  test "an author who names themselves at submit joins the set" do
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)

    submit!(task, actor: "xan")

    assert_equal %w[shannon xan], authors(task), "the soul who shipped it is an author too"
    assert_equal "shannon", task.reload.devops["built_by"],
      "and built_by keeps its meaning: the soul who CLAIMED the desk"
  end

  test "a later write to an ALREADY submitted task is not an authorship moment" do
    # Keyed on the TRANSITION. `bin/task update --checks`, a pr_url stamp, and the
    # review's own writes all touch a submitted task; a soul actor on one of them
    # must not join the author set.
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)
    submit!(task, actor: STEFFON_SESSION)

    Current.task_event_actor = "xan"
    task.reload.update!(metadata: { "devops" => task.reload.devops.merge("pr_url" => "https://example.test/pr/1") })
    Current.reset

    assert_equal %w[shannon], authors(task), "a stamp on a submitted task is not a handover"
  end

  test "end to end: an author named at submit is kept OUT of the pool" do
    # The other half: naming the shipper does not merely lift the refusal, it
    # actually excludes them — the property the refusal exists to protect.
    task = new_task
    task.update!(metadata: { "devops" => task.devops.merge("shape" => "backend") })
    claim!(task, actor: "shannon", session: STEFFON_SESSION)
    submit!(task, actor: "xan")

    seated = ReviewerSelector.select(task.reload).map { |r| r["slug"] }

    refute_includes seated, "xan", "the soul who wrote and shipped the diff"
    refute_includes seated, "shannon", "the soul who opened the desk"
    assert_equal 2, seated.uniq.size, "a pair still forms"
  end
end
