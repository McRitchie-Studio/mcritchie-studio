require "test_helper"

class AtomicEventTest < ActiveSupport::TestCase
  # ---- [unit] defaults + validations ----------------------------------------

  test "[unit] a new record carries the column defaults" do
    event = AtomicEvent.new

    assert_equal 0, event.seq
    assert_nil event.closed_at
    assert event.open?, "a fresh span with no closed_at is open"
  end

  test "[unit] valid with the required attributes present" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Explore",
                            reason_slug: "find issue with api", opened_at: Time.current)

    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "[unit] session_id is required" do
    event = AtomicEvent.new(category: "Explore", reason_slug: "x", opened_at: Time.current)

    assert_not event.valid?
    assert_includes event.errors[:session_id], "can't be blank"
  end

  test "[unit] reason_slug is required" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Explore", opened_at: Time.current)

    assert_not event.valid?
    assert_includes event.errors[:reason_slug], "can't be blank"
  end

  test "[unit] opened_at is required" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Explore", reason_slug: "x")

    assert_not event.valid?
    assert_includes event.errors[:opened_at], "can't be blank"
  end

  test "[unit] seq must be a non-negative integer" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Explore", reason_slug: "x",
                            opened_at: Time.current, seq: -1)

    assert_not event.valid?
    assert_includes event.errors[:seq], "must be greater than or equal to 0"
  end

  # ---- [unit] category vocabulary -------------------------------------------

  test "[unit] category accepts every declared category" do
    AtomicEvent::CATEGORIES.each do |category|
      event = AtomicEvent.new(session_id: "sess-1", category: category,
                              reason_slug: "x", opened_at: Time.current)
      assert event.valid?, "#{category} should be a valid category"
    end
  end

  test "[unit] the category vocabulary is exactly the ten declared spans" do
    assert_equal %w[Explore Edit Verify Version Workflow Delegate Clarify Remote Research Plan],
                 AtomicEvent::CATEGORIES
  end

  test "[unit] category is required" do
    event = AtomicEvent.new(session_id: "sess-1", reason_slug: "x", opened_at: Time.current)

    assert_not event.valid?
    assert_includes event.errors[:category], "can't be blank"
  end

  test "[unit] category rejects a value outside the vocabulary" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Vibe",
                            reason_slug: "x", opened_at: Time.current)

    assert_not event.valid?
    assert_includes event.errors[:category], "is not included in the list"
  end

  # ---- [unit] open/closed predicates ----------------------------------------

  test "[unit] open? and closed? reflect closed_at" do
    assert AtomicEvent.new(closed_at: nil).open?
    assert_not AtomicEvent.new(closed_at: nil).closed?
    assert AtomicEvent.new(closed_at: Time.current).closed?
    assert_not AtomicEvent.new(closed_at: Time.current).open?
  end

  # ---- [unit] scopes ---------------------------------------------------------

  test "[unit] scopes filter by session open closed and chronological order" do
    t0 = Time.zone.local(2026, 6, 30, 9, 0, 0)
    open_a  = AtomicEvent.create!(session_id: "scope-sess", category: "Explore", reason_slug: "a",
                                  seq: 0, opened_at: t0)
    closed  = AtomicEvent.create!(session_id: "scope-sess", category: "Edit", reason_slug: "b",
                                  seq: 1, opened_at: t0 + 60, closed_at: t0 + 120)
    AtomicEvent.create!(session_id: "other-sess", category: "Plan", reason_slug: "c",
                        seq: 0, opened_at: t0)

    assert_equal 2, AtomicEvent.for_session("scope-sess").count
    assert_equal [open_a.id], AtomicEvent.for_session("scope-sess").open.pluck(:id)
    assert_equal [closed.id], AtomicEvent.for_session("scope-sess").closed.pluck(:id)
    assert_equal [open_a.id, closed.id],
                 AtomicEvent.for_session("scope-sess").chronological.pluck(:id)
  end

  test "[unit] next_seq_for is zero for a blank or unseen session and max+1 otherwise" do
    assert_equal 0, AtomicEvent.next_seq_for(nil)
    assert_equal 0, AtomicEvent.next_seq_for("never-seen")

    AtomicEvent.create!(session_id: "seq-sess", category: "Explore", reason_slug: "a",
                        seq: 4, opened_at: Time.current)
    assert_equal 5, AtomicEvent.next_seq_for("seq-sess")
  end

  # ---- [integration] open_event! --------------------------------------------

  test "[integration] open_event! opens a span at seq 0 with the given fields" do
    event = AtomicEvent.open_event!(
      session_id: "open-sess", category: "Explore", reason_slug: "find issue with api",
      task_slug: nil, mascot: "caterpie", stage: "building"
    )

    assert event.persisted?
    assert event.open?
    assert_equal 0, event.seq
    assert_equal "Explore", event.category
    assert_equal "find issue with api", event.reason_slug
    assert_equal "caterpie", event.mascot
    assert_equal "building", event.stage
    assert_nil event.outcome_slug
    assert event.opened_at.present?
  end

  test "[integration] opening a new span auto-closes the prior open span" do
    first = AtomicEvent.open_event!(session_id: "auto-sess", category: "Explore", reason_slug: "look")
    second = AtomicEvent.open_event!(session_id: "auto-sess", category: "Edit", reason_slug: "change")

    assert first.reload.closed?, "the prior open span is auto-closed"
    assert_nil first.outcome_slug, "an auto-closed span has no narrated outcome"
    assert second.open?
    assert_equal 1, second.seq
    assert_equal 1, AtomicEvent.for_session("auto-sess").open.count,
                 "exactly one span stays open per session"
  end

  test "[integration] open_event! validates BEFORE auto-closing the prior span" do
    open = AtomicEvent.open_event!(session_id: "guard-sess", category: "Explore", reason_slug: "keep me")

    assert_raises(ActiveRecord::RecordInvalid) do
      AtomicEvent.open_event!(session_id: "guard-sess", category: "Nonsense", reason_slug: "bad")
    end

    assert open.reload.open?, "a rejected open must NOT strand the session with everything closed"
    assert_equal 1, AtomicEvent.for_session("guard-sess").open.count
  end

  # ---- [unit] BOUNDARY transition: open_event! prior_outcome ----------------

  test "[unit] open_event! stamps the auto-closed prior span's outcome when given" do
    AtomicEvent.open_event!(session_id: "boundary-sess", category: "Explore", reason_slug: "look")
    second = AtomicEvent.open_event!(session_id: "boundary-sess", category: "Edit",
                                     reason_slug: "change", prior_outcome_slug: "found the bug")

    prior = AtomicEvent.for_session("boundary-sess").order(:seq).first
    assert prior.closed?, "the prior span is closed at the boundary"
    assert_equal "found the bug", prior.outcome_slug, "and stamped with the narrated outcome"
    assert second.open?
    assert_nil second.outcome_slug, "the newly opened span carries no outcome yet"
    assert_equal 1, AtomicEvent.for_session("boundary-sess").open.count
  end

  test "[unit] open_event! without a prior_outcome auto-closes prior with a NULL outcome" do
    AtomicEvent.open_event!(session_id: "nullout-sess", category: "Explore", reason_slug: "look")
    AtomicEvent.open_event!(session_id: "nullout-sess", category: "Edit", reason_slug: "change")

    prior = AtomicEvent.for_session("nullout-sess").order(:seq).first
    assert prior.closed?
    assert_nil prior.outcome_slug, "legacy behavior: a bare open leaves the prior outcome NULL"
  end

  test "[unit] a blank prior_outcome never blanks an outcome a prior close already set" do
    AtomicEvent.open_event!(session_id: "keep-sess", category: "Verify", reason_slug: "run tests")
    AtomicEvent.close_event!(session_id: "keep-sess", outcome_slug: "already green")
    # There is no open span now; opening the next with a blank prior_outcome must
    # not touch the already-closed span's outcome.
    AtomicEvent.open_event!(session_id: "keep-sess", category: "Edit", reason_slug: "next",
                            prior_outcome_slug: "")

    assert_equal "already green", AtomicEvent.for_session("keep-sess").order(:seq).first.outcome_slug
  end

  # ---- [integration] session-end teardown: close_all_open! ------------------

  test "[integration] close_all_open! closes the open span with a shared outcome" do
    AtomicEvent.open_event!(session_id: "end-sess", category: "Edit", reason_slug: "mid-edit")

    count = AtomicEvent.close_all_open!(session_id: "end-sess", outcome_slug: "session ended")

    assert_equal 1, count
    span = AtomicEvent.for_session("end-sess").order(:seq).last
    assert span.closed?
    assert_equal "session ended", span.outcome_slug
    assert_equal 0, AtomicEvent.for_session("end-sess").open.count
  end

  test "[integration] close_all_open! closes EVERY open span, not just the latest" do
    # Defensive: even if the single-open invariant were somehow broken, teardown
    # must leave nothing open. Force two open spans by inserting directly.
    AtomicEvent.create!(session_id: "multi-end", category: "Explore", reason_slug: "a",
                        seq: 0, opened_at: Time.current)
    AtomicEvent.create!(session_id: "multi-end", category: "Edit", reason_slug: "b",
                        seq: 1, opened_at: Time.current)

    count = AtomicEvent.close_all_open!(session_id: "multi-end", outcome_slug: "session ended")

    assert_equal 2, count
    assert_equal 0, AtomicEvent.for_session("multi-end").open.count
  end

  test "[integration] close_all_open! is a no-op returning 0 when nothing is open" do
    assert_equal 0, AtomicEvent.close_all_open!(session_id: "never-open-end", outcome_slug: "x")
  end

  test "[integration] open_event! links to a task via the slug FK" do
    task = Task.create!(title: "atomic event sample task", stage: "building")

    event = AtomicEvent.open_event!(session_id: "fk-sess", category: "Plan",
                                    reason_slug: "shape the model", task_slug: task.slug)

    assert_equal task.slug, event.task_slug
    assert_equal task, event.task
    assert_includes task.atomic_events, event
  end

  # ---- [integration] close_event! -------------------------------------------

  test "[integration] close_event! stamps the outcome and closes the open span" do
    AtomicEvent.open_event!(session_id: "close-sess", category: "Verify", reason_slug: "run tests")

    closed = AtomicEvent.close_event!(session_id: "close-sess", outcome_slug: "green suite")

    assert closed.closed?
    assert_equal "green suite", closed.outcome_slug
    assert closed.closed_at.present?
    assert_equal 0, AtomicEvent.for_session("close-sess").open.count
  end

  test "[integration] close_event! closes the LATEST open span" do
    AtomicEvent.open_event!(session_id: "latest-sess", category: "Explore", reason_slug: "one")
    AtomicEvent.open_event!(session_id: "latest-sess", category: "Edit", reason_slug: "two")

    closed = AtomicEvent.close_event!(session_id: "latest-sess", outcome_slug: "done two")

    assert_equal "two", closed.reason_slug, "closes the current (latest) open span"
    assert_equal 0, AtomicEvent.for_session("latest-sess").open.count
  end

  test "[integration] close_event! is a no-op when the session has no open span" do
    assert_nil AtomicEvent.close_event!(session_id: "never-opened", outcome_slug: "x")
  end

  # ---- [integration] destroy orphans its actions (survives as history) -------

  test "[integration] destroying a span nullifies its actions rather than destroying them" do
    event = AtomicEvent.open_event!(session_id: "orphan-sess", category: "Explore", reason_slug: "look")
    action = AtomicAction.capture(session_id: "orphan-sess", kind: "read")
    assert_equal event.id, action.atomic_event_id

    assert_no_difference -> { AtomicAction.count } do
      event.destroy!
    end
    assert_nil action.reload.atomic_event_id, "the raw action survives as orphaned history"
  end
end
