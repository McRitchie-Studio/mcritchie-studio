# frozen_string_literal: true

# THE AUTHOR SET — Task#builder_roll_call, the memory devops.built_by cannot keep.
#
# `built_by` holds ONE soul and #builder_to_stamp rule 1 RE-POINTS it on an explicit
# re-claim, so a mid-build handoff (a session limit kills a builder, another soul
# finishes the job) OVERWRITES the first author. Measured 2026-08-30 on two tasks in
# one sitting: credential-prose-tells-truth reads built_by=avi and
# agent-flag-silently-drops reads built_by=steffon, yet ALEX wrote the tests on the
# first and the whole rework on the second. `bin/reviewer-select` then seated Alex as
# the LIGHT on Alex's own diff (PR #1081).
#
# `builders` accumulates instead — append-only, SERVER-OWNED (absent from
# DEVOPS_KEYS, so no client can write or shrink it). `builders_unattributed` is the
# half that keeps it fail-CLOSED: accumulating only helps while every claim names a
# soul, so the claim that named NOBODY has to be able to say so.
require "test_helper"

class TaskBuilderRollCallTest < ActiveSupport::TestCase
  # UUID-shaped, like a real session id — Task#disowned? branches on SOUL_SLUG, so a
  # soul-shaped stand-in would quietly take a different path (see
  # test/models/task_build_claim_invariant_test.rb).
  STEFFON_SESSION = "s1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  ALEX_SESSION    = "s2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"

  # Each claim advances a per-test clock. Two claims minted inside the same second
  # produce a BYTE-IDENTICAL lease, which #claim_lease_rewritten? correctly reads as
  # "no claim happened" — so without the clock a re-claim silently tests nothing.
  def claim!(task, actor: nil, session: STEFFON_SESSION, nonce: "inst-A", devops: {})
    @clock = (@clock || Time.current) + 30.seconds
    Current.task_event_actor = actor
    task.update!(stage: "building",
                 metadata: { "devops" => task.devops.merge(devops).merge(
                   ClaimLease.renewed(session: session, nonce: nonce, now: @clock)
                 ) })
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

    claim!(task, actor: "alex", session: ALEX_SESSION, nonce: "inst-B")

    assert_equal "alex", task.reload.devops["built_by"], "built_by still names the CURRENT builder"
    assert_equal %w[steffon alex], authors(task), "and the set remembers the one it replaced"
    assert_nil unattributed(task), "both claims named a soul — nothing is missing"
  end

  test "the set is seeded from a built_by stamped before the accumulator existed" do
    task = new_task
    task.update_columns(metadata: { "devops" => { "built_by" => "shannon" } })

    claim!(task.reload, actor: "alex", session: ALEX_SESSION)

    assert_equal %w[shannon alex], authors(task), "the legacy author is not lost on the next claim"
  end

  test "a client cannot shrink the author set through a wholesale devops replace" do
    # The API assigns devops WHOLESALE, so a --checks update echoes none of these
    # keys. If that erased the set, the record could be laundered clean between the
    # handoff and the review.
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: "alex", session: ALEX_SESSION, nonce: "inst-B")

    task.update!(metadata: { "devops" => { "checks_run" => ["[unit] something"] } })

    assert_equal %w[steffon alex], authors(task), "the server rebuilds the set on every save"
  end

  test "a re-claim by an author already on record adds nobody twice" do
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: "steffon", session: STEFFON_SESSION, nonce: "inst-B")

    assert_equal %w[steffon], authors(task)
  end

  # --- FAIL CLOSED: the handoff that named nobody -----------------------------

  test "an anonymous claim by a DIFFERENT session marks the set incomplete" do
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)

    claim!(task, actor: nil, session: ALEX_SESSION, nonce: "inst-B")

    assert_equal %w[steffon], authors(task), "steffon is still the only name we have"
    assert_equal ALEX_SESSION, unattributed(task),
      "but the record now says another session worked this and went unnamed"
  end

  test "a statusline lease RENEWAL is not a handoff" do
    # The heartbeat renews every few seconds with no actor. Treating that as an
    # anonymous handoff would refuse every task in the fleet, and a guard that cries
    # wolf gets routed around — which is worse than the bug.
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)

    5.times { claim!(task, actor: nil, session: STEFFON_SESSION, nonce: "inst-A") }

    assert_nil unattributed(task), "the same party heartbeating is not a change of hands"
    assert_equal %w[steffon], authors(task)
  end

  test "a second PROCESS of the same session is not a handoff either" do
    # `claude --resume <id>` in a second terminal: same party, new nonce.
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION, nonce: "inst-A")

    claim!(task, actor: nil, session: STEFFON_SESSION, nonce: "inst-B")

    assert_nil unattributed(task), "the nonce distinguishes processes, not parties"
  end

  test "the unnamed session clears the gap by naming itself" do
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: nil, session: ALEX_SESSION, nonce: "inst-B")
    assert_equal ALEX_SESSION, unattributed(task)

    claim!(task, actor: "alex", session: ALEX_SESSION, nonce: "inst-B")

    assert_nil unattributed(task), "the session we could not name has named itself"
    assert_equal %w[steffon alex], authors(task)
  end

  test "a THIRD soul claiming by name does NOT clear another session's gap" do
    # Clearing on any named claim would hand the fail-open straight back: jasper
    # saying who HE is says nothing about who the unnamed session was.
    task = new_task
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: nil, session: ALEX_SESSION, nonce: "inst-B")

    claim!(task, actor: "jasper", session: "s3f2a4c5-6d7e-4f80-9b12-c3d4e5f6a7b8", nonce: "inst-C")

    assert_equal ALEX_SESSION, unattributed(task), "the gap is still open"
    assert_equal %w[steffon jasper], authors(task)
  end

  test "a FIRST claim that names nobody leaves no gap — a blank builder already refuses" do
    task = new_task
    claim!(task, actor: nil, session: STEFFON_SESSION)

    assert_nil unattributed(task), "there was no author to mask"
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
    claim!(task, actor: "alex", session: ALEX_SESSION, nonce: "inst-B")

    seated = ReviewerSelector.select(task.reload).map { |r| r["slug"] }

    refute_includes seated, "alex", "the co-author whose tests are in the diff"
    refute_includes seated, "steffon", "the soul who opened the desk"
    assert_equal 2, seated.uniq.size, "a pair still forms"
  end

  test "end to end: an unnamed handoff makes the reviewer selection REFUSE" do
    task = new_task
    task.update!(metadata: { "devops" => task.devops.merge("shape" => "backend") })
    claim!(task, actor: "steffon", session: STEFFON_SESSION)
    claim!(task, actor: nil, session: ALEX_SESSION, nonce: "inst-B")

    decision = ReviewerSelector.explain(task.reload)

    assert_equal false, decision["builder_known"],
      "an author we cannot name is not an author we can exclude"
    assert_equal ALEX_SESSION, decision["builders_unattributed"]
  end
end
