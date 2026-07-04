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

  # ---- [unit] agent attribution ---------------------------------------------

  test "[unit] SOULS is the McRitchie roster" do
    assert_equal %w[avi carl shannon jasper steffon alex], AtomicEvent::SOULS
  end

  test "[unit] a known acting soul is stored, down-cased" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Explore", reason_slug: "x",
                            opened_at: Time.current, agent: "Avi")

    assert event.valid?, event.errors.full_messages.to_sentence
    assert_equal "avi", event.agent
  end

  test "[unit] an unknown acting soul is coerced to nil, never invalid" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Explore", reason_slug: "x",
                            opened_at: Time.current, agent: "gary-oak")

    assert event.valid?, "an unknown soul must NOT fail validation (non-fatal coercion)"
    assert_nil event.agent, "an unknown soul is coerced to nil, not stored"
  end

  test "[unit] a blank acting soul normalizes to nil" do
    event = AtomicEvent.new(session_id: "sess-1", category: "Explore", reason_slug: "x",
                            opened_at: Time.current, agent: "   ")

    assert event.valid?
    assert_nil event.agent, "blank means the base session mascot did it"
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

  test "[integration] open_event! stamps a known acting soul on the span" do
    event = AtomicEvent.open_event!(session_id: "agent-sess", category: "Edit",
                                    reason_slug: "add guard", agent: "Carl")

    assert_equal "carl", event.reload.agent, "the acting soul rides the span, down-cased"
  end

  test "[integration] open_event! coerces an unknown acting soul to nil and still opens" do
    event = AtomicEvent.open_event!(session_id: "agent-sess-2", category: "Edit",
                                    reason_slug: "add guard", agent: "team-rocket")

    assert_nil event.reload.agent, "unknown soul → nil (non-fatal)"
    assert event.open?, "a bad --agent never sinks the open"
  end

  test "[integration] open_event! defaults agent to nil — the base session mascot did it" do
    event = AtomicEvent.open_event!(session_id: "agent-sess-3", category: "Explore", reason_slug: "look")

    assert_nil event.agent
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

  # ---- [integration] per-agent span lanes (audit finding #4) ----------------
  # The reviewer fan-out narrates several souls in ONE session; each soul's
  # start/end must operate on its OWN lane, never closing another's in-flight span.

  test "[integration] concurrent soul spans do NOT close each other" do
    carl    = AtomicEvent.open_event!(session_id: "lane", category: "Verify", reason_slug: "backend", agent: "carl")
    shannon = AtomicEvent.open_event!(session_id: "lane", category: "Verify", reason_slug: "ui", agent: "shannon")

    assert carl.reload.open?,    "carl's span stays open when shannon opens hers"
    assert shannon.reload.open?, "shannon's span opens without disturbing carl's"
    assert_equal 2, AtomicEvent.for_session("lane").open.count, "both lanes open at once"
  end

  test "[integration] opening a new span for a soul auto-closes only THAT soul's prior span" do
    carl_first  = AtomicEvent.open_event!(session_id: "lane2", category: "Explore", reason_slug: "scan", agent: "carl")
    shannon     = AtomicEvent.open_event!(session_id: "lane2", category: "Verify", reason_slug: "ui", agent: "shannon")
    carl_second = AtomicEvent.open_event!(session_id: "lane2", category: "Edit", reason_slug: "fix",
                                          agent: "carl", prior_outcome_slug: "scan done")

    assert carl_first.reload.closed?, "carl's own prior span closes"
    assert_equal "scan done", carl_first.outcome_slug, "and is stamped with the boundary outcome"
    assert shannon.reload.open?, "shannon's span is untouched by carl's boundary"
    assert carl_second.open?
  end

  test "[integration] close_event! closes only the named soul's lane" do
    carl    = AtomicEvent.open_event!(session_id: "lane3", category: "Verify", reason_slug: "backend", agent: "carl")
    shannon = AtomicEvent.open_event!(session_id: "lane3", category: "Verify", reason_slug: "ui", agent: "shannon")

    closed = AtomicEvent.close_event!(session_id: "lane3", agent: "carl", outcome_slug: "approve: clean")

    assert_equal carl.id, closed.id, "carl's close resolves carl's span, not whichever opened last"
    assert_equal "approve: clean", closed.outcome_slug
    assert shannon.reload.open?, "shannon's span survives carl's close"
  end

  test "[integration] the orchestrator's nil lane is independent of soul lanes" do
    orchestrator = AtomicEvent.open_event!(session_id: "lane4", category: "Plan", reason_slug: "orient")
    carl         = AtomicEvent.open_event!(session_id: "lane4", category: "Verify", reason_slug: "review", agent: "carl")

    # closing the nil lane (no agent) leaves the soul lane open, and vice versa
    AtomicEvent.close_event!(session_id: "lane4", outcome_slug: "planned")

    assert orchestrator.reload.closed?
    assert carl.reload.open?, "the soul lane is unaffected by the nil-lane close"
  end

  test "[integration] close_all_open! still closes EVERY lane at session end" do
    AtomicEvent.open_event!(session_id: "lane5", category: "Plan", reason_slug: "orient")
    AtomicEvent.open_event!(session_id: "lane5", category: "Verify", reason_slug: "a", agent: "carl")
    AtomicEvent.open_event!(session_id: "lane5", category: "Verify", reason_slug: "b", agent: "shannon")

    count = AtomicEvent.close_all_open!(session_id: "lane5", outcome_slug: "session ended")

    assert_equal 3, count, "the session-end teardown closes all three lanes"
    assert_equal 0, AtomicEvent.for_session("lane5").open.count
  end

  test "[unit] normalize_agent_value maps known souls and coerces the rest to the nil lane" do
    assert_equal "carl", AtomicEvent.normalize_agent_value("Carl")
    assert_nil AtomicEvent.normalize_agent_value("nobody")
    assert_nil AtomicEvent.normalize_agent_value("")
    assert_nil AtomicEvent.normalize_agent_value(nil)
  end

  test "[integration] an unknown close agent resolves the nil lane, not a soul lane" do
    orchestrator = AtomicEvent.open_event!(session_id: "lane6", category: "Plan", reason_slug: "orient")
    AtomicEvent.open_event!(session_id: "lane6", category: "Verify", reason_slug: "review", agent: "carl")

    # a typo'd/unknown agent normalizes to the nil lane (matches the record coercion)
    closed = AtomicEvent.close_event!(session_id: "lane6", agent: "typo", outcome_slug: "planned")

    assert_equal orchestrator.id, closed.id
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

  # ---- [integration] awaiting_grade — the grade-events READ path -------------

  def resolved_span(session_id:, reason: "resolved span here", **attrs)
    AtomicEvent.open_event!(session_id: session_id, category: "Verify", reason_slug: reason, **attrs)
    AtomicEvent.close_event!(session_id: session_id, outcome_slug: "done")
  end

  test "[integration] awaiting_grade returns resolved spans ungraded by the grader, newest first" do
    older = resolved_span(session_id: "aw-1", reason: "older resolved span")
    older.update!(closed_at: 2.days.ago)
    newer = resolved_span(session_id: "aw-2", reason: "newer resolved span")

    ids = AtomicEvent.awaiting_grade(grader: "alex").map(&:id)

    assert_equal [newer.id, older.id], ids, "resolved spans, newest-resolved first"
  end

  test "[integration] awaiting_grade excludes an OPEN span and one Alex already graded" do
    AtomicEvent.open_event!(session_id: "aw-open", category: "Edit", reason_slug: "still open") # never closed
    graded = resolved_span(session_id: "aw-graded", reason: "already graded span")
    ActionGrade.create!(atomic_event: graded, grader: "alex", slug: "seen this one", disposition: "good")
    fresh = resolved_span(session_id: "aw-fresh", reason: "not yet graded span")

    ids = AtomicEvent.awaiting_grade(grader: "alex").map(&:id)

    assert_includes ids, fresh.id
    refute_includes ids, graded.id, "a span Alex already graded is not awaiting"
    assert(ids.none? { |id| AtomicEvent.find(id).open? }, "open spans are never awaiting")
  end

  test "[integration] awaiting_grade is per-grader — an mcr grade doesn't satisfy alex" do
    span = resolved_span(session_id: "aw-grader", reason: "mcr graded not alex")
    ActionGrade.create!(atomic_event: span, grader: "mcr", slug: "mcr audited this", disposition: "good")

    assert_includes AtomicEvent.awaiting_grade(grader: "alex").map(&:id), span.id,
                    "an mcr grade leaves it awaiting an ALEX grade"
  end

  test "[integration] awaiting_grade clamps the limit" do
    3.times { |i| resolved_span(session_id: "aw-cap-#{i}", reason: "resolved number #{i}") }

    assert_equal 1, AtomicEvent.awaiting_grade(limit: 0).size, "0 clamps up to 1"
    assert_operator AtomicEvent.awaiting_grade(limit: 999).size, :<=, AtomicEvent::MAX_GRADE_BATCH
  end

  test "[unit] to_grading_row carries what a grader needs and drops nils" do
    span = AtomicEvent.open_event!(session_id: "row-sess", category: "Verify",
                                   reason_slug: "narrated well", agent: "carl", task_slug: nil)
    row = span.to_grading_row

    assert_equal span.id, row["id"]
    assert_equal "Verify", row["category"]
    assert_equal "narrated well", row["reason"]
    assert_equal "carl", row["agent"]
    assert_not row.key?("task_slug"), "a nil task_slug is dropped"
  end

  # ---- key_method (the span's one load-bearing call) -------------------------

  test "[integration] close_event! stamps the key method with an inferred lang" do
    AtomicEvent.open_event!(session_id: "km-sess", category: "Edit", reason_slug: "add the guard")
    closed = AtomicEvent.close_event!(session_id: "km-sess", outcome_slug: "guard added",
                                      key_method: "User.find_by(email: ...)")

    assert_equal "User.find_by(email: ...)", closed.key_method
    assert_equal "ruby", closed.key_method_lang
  end

  test "[integration] a bare close never blanks a key method the span already carries" do
    AtomicEvent.open_event!(session_id: "km-keep", category: "Verify", reason_slug: "run suite")
    AtomicEvent.close_event!(session_id: "km-keep", key_method: "bin/rails test", key_method_lang: "bash")
    reopened = AtomicEvent.for_session("km-keep").order(:seq).last
    reopened.update!(closed_at: nil)

    closed = AtomicEvent.close_event!(session_id: "km-keep", outcome_slug: "green")
    assert_equal "bin/rails test", closed.key_method, "a keyless close preserves the stamp"
  end

  test "[integration] open_event! with prior_key_method stamps the auto-closed prior span" do
    prior = AtomicEvent.open_event!(session_id: "km-next", category: "Explore", reason_slug: "orient")
    AtomicEvent.open_event!(session_id: "km-next", category: "Edit", reason_slug: "make the change",
                            prior_outcome_slug: "seam found",
                            prior_key_method: "grep -rn AtomicEvent app/models")

    prior.reload
    assert_equal "seam found", prior.outcome_slug
    assert_equal "grep -rn AtomicEvent app/models", prior.key_method
    assert_equal "bash", prior.key_method_lang, "update_all path still normalizes the pair"
    assert_nil AtomicEvent.for_session("km-next").open.order(:seq).last.key_method,
               "the NEW span opens without the prior's key method"
  end
end
