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

  # --- THE AUTHOR WHO NEVER CLAIMED (the submit half) -------------------------
  #
  # Everything above keys on the CLAIM. PR #1094 was the shape it cannot see:
  # shannon's agent claimed the task and died to a session limit with NOTHING
  # committed; ALEX wrote the whole diff and both test files, and shipped it. The
  # set held only shannon, so the selector excluded a soul who wrote nothing and
  # left the real author in the pool at alex:0.9968, ranked 3rd.

  test "shipping from a session that never claimed marks the set incomplete" do
    # THE ACCEPTANCE CASE. Claim by soul A, ship from soul B's session. Before this
    # change the record read complete and named only A.
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)
    assert_nil unattributed(task), "one named claim leaves no gap"

    submit!(task, actor: ALEX_SESSION)

    assert_equal %w[shannon], authors(task), "shannon is still the only NAME we have"
    assert_equal ALEX_SESSION, unattributed(task),
      "but another session shipped this, so the author set is INCOMPLETE"
  end

  test "an author who names themselves at submit joins the set" do
    # Option 1's escape hatch, riding the flag that already exists — no new one to
    # forget, and forgetting it fails CLOSED via the case above.
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)

    submit!(task, actor: "alex")

    assert_equal %w[shannon alex], authors(task), "the soul who shipped it is an author too"
    assert_nil unattributed(task), "nobody is missing — both are named"
    assert_equal "shannon", task.reload.devops["built_by"],
      "and built_by keeps its meaning: the soul who CLAIMED the desk"
  end

  test "the claimer shipping their OWN work raises no flag" do
    # The overwhelmingly common case. A guard that cries wolf here gets routed
    # around, so the ordinary ship must be byte-identical to before.
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)

    submit!(task, actor: STEFFON_SESSION)

    assert_equal %w[shannon], authors(task)
    assert_nil unattributed(task), "same session claimed and shipped — no handover happened"
  end

  test "an operator moving the card on the board is not a shipping session" do
    # TasksController sets the actor to current_user.email for a web move. Dragging
    # a card to `submitted` says nothing about who wrote the diff, and refusing the
    # review over it would be the wolf-crying that gets a guard disabled.
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)

    submit!(task, actor: "alex@mcritchie.studio")

    assert_equal %w[shannon], authors(task)
    assert_nil unattributed(task), "a board action carries no authorship claim"
  end

  test "a submit with no claim session on record leaves no gap" do
    # Nothing to differ FROM. A claim that recorded no session (plain shell / CI) is
    # already the degraded path; inferring a handover from its ABSENCE would flag
    # every such task.
    task = new_task
    Current.task_event_actor = "shannon"
    task.update!(stage: "building", metadata: { "devops" => {} })
    Current.reset
    assert_equal %w[shannon], authors(task)
    assert_equal "", task.reload.devops["claimed_session"].to_s

    submit!(task, actor: ALEX_SESSION)

    assert_nil unattributed(task), "no claimed session means no handover to detect"
  end

  test "a later write to an ALREADY submitted task is not an authorship moment" do
    # Keyed on the TRANSITION. `bin/task update --checks`, a pr_url stamp, and the
    # review's own writes all touch a submitted task; treating those as handoffs
    # would let any passing session stamp one.
    #
    # The claim lease is PUT BACK with update_columns on purpose, and without it this
    # test proves nothing about the guard it names: #enforce_build_claim_invariant
    # strips every claim key on any non-`building` save, so after the submit the
    # BLANK-claim guard already refuses and `submit_save?` is never consulted.
    # Verified by mutation — dropping `will_save_change_to_stage?` left the original
    # version of this test green. The coupling is exactly why submit_save? asks about
    # the TRANSITION and not the stage: the day that invariant changes, a `--checks`
    # write must still not stamp a handoff.
    task = new_task
    claim!(task, actor: "shannon", session: STEFFON_SESSION)
    submit!(task, actor: STEFFON_SESSION)
    assert_nil unattributed(task)
    task.update_columns(metadata: { "devops" => task.reload.devops.merge("claimed_session" => STEFFON_SESSION) })

    Current.task_event_actor = ALEX_SESSION
    task.reload.update!(metadata: { "devops" => task.reload.devops.merge("pr_url" => "https://example.test/pr/1") })
    Current.reset

    assert_nil unattributed(task), "a stamp on a submitted task is not a handover"
  end

  test "end to end: the unnamed shipper makes the reviewer selection REFUSE" do
    # PR #1094 replayed. Today the selector ran happily, excluded shannon, and left
    # alex a live light candidate.
    task = new_task
    task.update!(metadata: { "devops" => task.devops.merge("shape" => "backend") })
    claim!(task, actor: "shannon", session: STEFFON_SESSION)
    submit!(task, actor: ALEX_SESSION)

    decision = ReviewerSelector.explain(task.reload)

    assert_equal false, decision["builder_known"],
      "an author we cannot name is not an author we can exclude"
    assert_equal ALEX_SESSION, decision["builders_unattributed"]
  end

  test "end to end: an author named at submit is kept OUT of the pool" do
    # The other half: naming the shipper does not merely lift the refusal, it
    # actually excludes them — the property the refusal exists to protect.
    task = new_task
    task.update!(metadata: { "devops" => task.devops.merge("shape" => "backend") })
    claim!(task, actor: "shannon", session: STEFFON_SESSION)
    submit!(task, actor: "alex")

    seated = ReviewerSelector.select(task.reload).map { |r| r["slug"] }

    refute_includes seated, "alex", "the soul who wrote and shipped the diff"
    refute_includes seated, "shannon", "the soul who opened the desk"
    assert_equal 2, seated.uniq.size, "a pair still forms"
  end
end
