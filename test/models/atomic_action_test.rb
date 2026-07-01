require "test_helper"
# Object#stub — the best-effort capture tests force failures standalone (mock
# isn't required globally; matches the repo's per-file convention).
require "minitest/mock"

class AtomicActionTest < ActiveSupport::TestCase
  # ---- [unit] defaults -------------------------------------------------------

  test "[unit] a new record carries the column defaults" do
    action = AtomicAction.new

    assert_equal 0, action.seq
    assert_equal AtomicAction::PENDING, action.outcome
    assert_equal AtomicAction::AGENT, action.actor
    assert_equal 0, action.tokens_in
    assert_equal 0, action.tokens_out
    assert_equal 0.to_d, action.cost
    assert_equal false, action.feedback_anchor
  end

  # ---- [unit] validations ----------------------------------------------------

  test "[unit] valid with the required attributes present" do
    action = AtomicAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current)

    assert action.valid?, action.errors.full_messages.to_sentence
  end

  test "[unit] session_id is required" do
    action = AtomicAction.new(kind: "read", occurred_at: Time.current)

    assert_not action.valid?
    assert_includes action.errors[:session_id], "can't be blank"
  end

  test "[unit] kind is required" do
    action = AtomicAction.new(session_id: "sess-1", occurred_at: Time.current)

    assert_not action.valid?
    assert_includes action.errors[:kind], "can't be blank"
  end

  test "[unit] occurred_at is required" do
    action = AtomicAction.new(session_id: "sess-1", kind: "read")

    assert_not action.valid?
    assert_includes action.errors[:occurred_at], "can't be blank"
  end

  test "[unit] seq must be a non-negative integer" do
    action = AtomicAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, seq: -1)

    assert_not action.valid?
    assert_includes action.errors[:seq], "must be greater than or equal to 0"
  end

  # ---- [unit] outcome enum ---------------------------------------------------

  test "[unit] outcome accepts ok error and pending" do
    AtomicAction::OUTCOMES.each do |outcome|
      action = AtomicAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, outcome: outcome)
      assert action.valid?, "#{outcome} should be a valid outcome"
    end
  end

  test "[unit] outcome rejects an unknown value" do
    action = AtomicAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, outcome: "maybe")

    assert_not action.valid?
    assert_includes action.errors[:outcome], "is not included in the list"
  end

  # ---- [unit] actor enum -----------------------------------------------------

  test "[unit] actor accepts harness agent board and human" do
    AtomicAction::ACTORS.each do |actor|
      action = AtomicAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, actor: actor)
      assert action.valid?, "#{actor} should be a valid actor"
    end
  end

  test "[unit] actor rejects an unknown value" do
    action = AtomicAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, actor: "robot")

    assert_not action.valid?
    assert_includes action.errors[:actor], "is not included in the list"
  end

  # ---- [unit] helpers + scopes ----------------------------------------------

  test "[unit] tokens_total sums the two sides" do
    action = AtomicAction.new(tokens_in: 1200, tokens_out: 3400)

    assert_equal 4600, action.tokens_total
  end

  test "[unit] outcome predicates reflect the stored value" do
    assert AtomicAction.new(outcome: "ok").ok?
    assert AtomicAction.new(outcome: "error").error?
    assert AtomicAction.new(outcome: "pending").pending?
    assert AtomicAction.new(feedback_anchor: true).anchor?
    assert_not AtomicAction.new(feedback_anchor: false).anchor?
  end

  test "[unit] scopes filter by session anchors and errored outcome" do
    ok      = AtomicAction.capture(session_id: "scope-sess", kind: "read", outcome: "ok")
    errored = AtomicAction.capture(session_id: "scope-sess", kind: "bash", outcome: "error")
    anchor  = AtomicAction.capture(session_id: "scope-sess", kind: "edit", feedback_anchor: true)
    AtomicAction.capture(session_id: "other-sess", kind: "read", outcome: "ok")

    assert_equal 3, AtomicAction.for_session("scope-sess").count
    assert_equal [errored.id], AtomicAction.for_session("scope-sess").errored.pluck(:id)
    assert_equal [anchor.id], AtomicAction.for_session("scope-sess").anchors.pluck(:id)
    assert_equal [ok.id, errored.id, anchor.id], AtomicAction.for_session("scope-sess").chronological.pluck(:id)
  end

  # ---- [integration] capture writes one forward record -----------------------

  test "[integration] capture persists one record with the given fields" do
    occurred = Time.zone.local(2026, 6, 30, 9, 0, 0)

    action = assert_difference -> { AtomicAction.count }, 1 do
      AtomicAction.capture(
        session_id:      "cap-sess",
        task_slug:       nil,
        mascot:          "rotom",
        kind:            "edit",
        event_slug:      "implement-atomic-action-model",
        result_slug:     "migration-and-model-written",
        input:           "write app/models/atomic_action.rb",
        output:          "file created",
        outcome:         "ok",
        model:           "claude-opus-4-8",
        tokens_in:       6800,
        tokens_out:      2400,
        cost:            "0.28".to_d,
        stage:           "building",
        actor:           "agent",
        feedback_anchor: true,
        occurred_at:     occurred,
        duration_ms:     1234
      )
    end

    assert action.persisted?
    assert_equal "cap-sess", action.session_id
    assert_equal "rotom", action.mascot
    assert_equal "edit", action.kind
    assert_equal "implement-atomic-action-model", action.event_slug
    assert_equal "migration-and-model-written", action.result_slug
    assert_equal "ok", action.outcome
    assert_equal "claude-opus-4-8", action.model
    assert_equal 9200, action.tokens_total
    assert_equal "0.28".to_d, action.cost
    assert_equal "building", action.stage
    assert_equal "agent", action.actor
    assert action.feedback_anchor
    assert_equal occurred, action.occurred_at
    assert_equal 1234, action.duration_ms
  end

  test "[integration] capture defaults outcome and actor and auto-derives seq per session" do
    first  = AtomicAction.capture(session_id: "seq-sess", kind: "read")
    second = AtomicAction.capture(session_id: "seq-sess", kind: "bash")
    other  = AtomicAction.capture(session_id: "fresh-sess", kind: "read")

    assert_equal AtomicAction::PENDING, first.outcome
    assert_equal AtomicAction::AGENT, first.actor
    assert_equal 0, first.seq, "the first action in a session is position 0"
    assert_equal 1, second.seq, "the next action increments within the session"
    assert_equal 0, other.seq, "a different session starts its own trajectory"
  end

  test "[integration] capture honours an explicit seq" do
    action = AtomicAction.capture(session_id: "explicit-seq", kind: "read", seq: 42)

    assert_equal 42, action.seq
  end

  test "[integration] capture pulls usage from Current when not given (the TaskEvent seam)" do
    Current.task_event_model = "claude-opus-4-8"
    Current.task_event_tokens_in = 1200
    Current.task_event_tokens_out = 3400
    Current.task_event_cost = "0.42".to_d

    action = AtomicAction.capture(session_id: "usage-sess", kind: "read")

    assert_equal "claude-opus-4-8", action.model
    assert_equal 1200, action.tokens_in
    assert_equal 3400, action.tokens_out
    assert_equal "0.42".to_d, action.cost
  ensure
    Current.reset
  end

  test "[integration] explicit usage attrs win over Current" do
    Current.task_event_model = "from-current"
    Current.task_event_tokens_in = 999

    action = AtomicAction.capture(session_id: "override-sess", kind: "read",
                                  model: "claude-opus-4-8", tokens_in: 50)

    assert_equal "claude-opus-4-8", action.model
    assert_equal 50, action.tokens_in
  ensure
    Current.reset
  end

  test "[integration] capture with string keys works" do
    action = AtomicAction.capture("session_id" => "str-sess", "kind" => "verify", "outcome" => "ok")

    assert action.persisted?
    assert_equal "verify", action.kind
    assert_equal "ok", action.outcome
  end

  test "[integration] capture links to a task via the slug FK" do
    task = Task.create!(title: "atomic capture sample task", stage: "building")

    action = AtomicAction.capture(session_id: "fk-sess", task_slug: task.slug, kind: "edit")

    assert_equal task.slug, action.task_slug
    assert_equal task, action.task
    assert_includes task.atomic_actions, action
  end

  # ---- [integration] best-effort: a capture failure never breaks the caller --

  test "[integration] a capture error is swallowed logged and returns nil" do
    result = nil
    assert_difference -> { ErrorLog.count }, 1 do
      AtomicAction.stub(:create!, ->(*) { raise "boom" }) do
        assert_nothing_raised do
          result = AtomicAction.capture(session_id: "err-sess", kind: "read")
        end
      end
    end

    assert_nil result, "capture returns nil on failure — never re-raises"
    assert_equal "boom", ErrorLog.order(:id).last.message
  end

  test "[integration] capture survives even when error logging also fails" do
    result = nil
    AtomicAction.stub(:create!, ->(*) { raise "boom" }) do
      ErrorLog.stub(:capture!, ->(*) { raise "logging is down" }) do
        assert_nothing_raised do
          result = AtomicAction.capture(session_id: "double-fail", kind: "read")
        end
      end
    end

    assert_nil result, "a double failure is still swallowed — the action is never broken"
  end

  test "[integration] next_seq_for is zero for a blank or unseen session" do
    assert_equal 0, AtomicAction.next_seq_for(nil)
    assert_equal 0, AtomicAction.next_seq_for("never-seen")
  end

  # ---- [integration] SPAN attribution (atomic_event_id) ----------------------

  test "[integration] capture attributes an action to the session's open span" do
    event = AtomicEvent.open_event!(session_id: "attr-sess", category: "Explore", reason_slug: "look")

    action = AtomicAction.capture(session_id: "attr-sess", kind: "read")

    assert_equal event.id, action.atomic_event_id, "the action rolls up under the open span"
    assert_equal action, event.atomic_actions.first
  end

  test "[integration] capture attributes to the LATEST open span" do
    AtomicEvent.open_event!(session_id: "latest-attr", category: "Explore", reason_slug: "one")
    second = AtomicEvent.open_event!(session_id: "latest-attr", category: "Edit", reason_slug: "two")

    action = AtomicAction.capture(session_id: "latest-attr", kind: "edit")

    assert_equal second.id, action.atomic_event_id, "opening a new span moves attribution to it"
  end

  test "[integration] an action with no open span carries a null atomic_event_id" do
    action = AtomicAction.capture(session_id: "no-span-sess", kind: "read")

    assert_nil action.atomic_event_id
  end

  test "[integration] a closed span stops receiving new actions" do
    AtomicEvent.open_event!(session_id: "closed-attr", category: "Verify", reason_slug: "test")
    AtomicEvent.close_event!(session_id: "closed-attr", outcome_slug: "green")

    action = AtomicAction.capture(session_id: "closed-attr", kind: "read")

    assert_nil action.atomic_event_id, "once the span closes, actions attribute to nothing"
  end

  test "[integration] an explicit atomic_event_id wins over the derived one" do
    open = AtomicEvent.open_event!(session_id: "pin-sess", category: "Explore", reason_slug: "open")
    other = AtomicEvent.create!(session_id: "pin-sess", category: "Edit", reason_slug: "pinned",
                                seq: 9, opened_at: Time.current, closed_at: Time.current)

    action = AtomicAction.capture(session_id: "pin-sess", kind: "edit", atomic_event_id: other.id)

    assert_equal other.id, action.atomic_event_id
    assert_not_equal open.id, action.atomic_event_id
  end

  test "[integration] an attribution lookup failure is swallowed and the action still writes" do
    action = nil
    AtomicEvent.stub(:for_session, ->(*) { raise "attribution is down" }) do
      assert_nothing_raised do
        action = AtomicAction.capture(session_id: "attr-fail", kind: "read")
      end
    end

    assert action&.persisted?, "capture still writes the action when attribution fails"
    assert_nil action.atomic_event_id, "a failed attribution degrades to a null span"
  end
end
