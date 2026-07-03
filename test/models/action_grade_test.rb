require "test_helper"

class ActionGradeTest < ActiveSupport::TestCase
  # A graded action to hang grades off of. Each test gets its own session id so
  # the captures never collide on seq across the suite.
  def action(session_id: "grade-sess", **attrs)
    AtomicAction.capture({ session_id: session_id, kind: "edit", outcome: "ok" }.merge(attrs))
  end

  def valid_attrs(**overrides)
    { atomic_action: action, grader: ActionGrade::ALEX,
      slug: "good catch flagging the gaps", disposition: ActionGrade::GOOD }.merge(overrides)
  end

  # A narrated span to hang span-level grades off of.
  def event(session_id: "grade-ev-sess", **attrs)
    AtomicEvent.create!({ session_id: session_id, category: "Explore",
                          reason_slug: "find issue with api", opened_at: Time.current, seq: 0 }.merge(attrs))
  end

  # Valid attrs for a grade that targets a SPAN instead of an action.
  def event_valid_attrs(**overrides)
    { atomic_event: event, grader: ActionGrade::ALEX,
      slug: "narrated the span clearly", disposition: ActionGrade::GOOD }.merge(overrides)
  end

  # ---- [unit] defaults -------------------------------------------------------

  test "[unit] a new grade is neither banked nor discarded by default" do
    grade = ActionGrade.new

    assert_equal false, grade.banked
    assert_equal false, grade.discarded
  end

  # ---- [unit] validations ----------------------------------------------------

  test "[unit] valid with the required attributes present" do
    grade = ActionGrade.new(valid_attrs)

    assert grade.valid?, grade.errors.full_messages.to_sentence
  end

  test "[unit] a grade with no target (neither action nor event) is invalid" do
    grade = ActionGrade.new(valid_attrs(atomic_action: nil))

    assert_not grade.valid?
    assert_includes grade.errors[:base], "must grade exactly one of an action or an event"
  end

  test "[unit] slug is required" do
    grade = ActionGrade.new(valid_attrs(slug: nil))

    assert_not grade.valid?
    assert_includes grade.errors[:slug], "can't be blank"
  end

  # ---- [unit] grader enum ----------------------------------------------------

  test "[unit] grader accepts alex and mcr" do
    ActionGrade::GRADERS.each do |grader|
      grade = ActionGrade.new(valid_attrs(grader: grader))
      assert grade.valid?, "#{grader} should be a valid grader"
    end
  end

  test "[unit] grader rejects an unknown value" do
    grade = ActionGrade.new(valid_attrs(grader: "steffon"))

    assert_not grade.valid?
    assert_includes grade.errors[:grader], "is not included in the list"
  end

  # ---- [unit] disposition enum (binary) -------------------------------------

  test "[unit] disposition accepts only good and not" do
    ActionGrade::DISPOSITIONS.each do |disposition|
      grade = ActionGrade.new(valid_attrs(disposition: disposition))
      assert grade.valid?, "#{disposition} should be a valid disposition"
    end
  end

  test "[unit] disposition rejects a third value (it is binary)" do
    grade = ActionGrade.new(valid_attrs(disposition: "pending"))

    assert_not grade.valid?
    assert_includes grade.errors[:disposition], "is not included in the list"
  end

  # ---- [unit] uniqueness per (action, grader) -------------------------------

  test "[unit] one grade per grader on a given action" do
    graded = action(session_id: "uniq-sess")
    ActionGrade.create!(valid_attrs(atomic_action: graded, grader: ActionGrade::ALEX))

    dup = ActionGrade.new(valid_attrs(atomic_action: graded, grader: ActionGrade::ALEX))

    assert_not dup.valid?
    assert_includes dup.errors[:grader], "has already been taken"
  end

  test "[unit] the same grader may grade a different action" do
    one = ActionGrade.create!(valid_attrs(atomic_action: action(session_id: "a-sess")))
    two = ActionGrade.new(valid_attrs(atomic_action: action(session_id: "b-sess")))

    assert one.persisted?
    assert two.valid?, two.errors.full_messages.to_sentence
  end

  # ---- [unit] predicates -----------------------------------------------------

  test "[unit] grader and disposition predicates reflect the stored value" do
    assert ActionGrade.new(grader: "alex").alex?
    assert ActionGrade.new(grader: "mcr").mcr?
    assert ActionGrade.new(disposition: "good").good?
    assert ActionGrade.new(disposition: "not").not_good?
    assert_not ActionGrade.new(disposition: "good").not_good?
  end

  # ---- [unit] bank!/discard! mutual exclusivity ------------------------------

  test "[unit] bank! sets banked and clears discarded" do
    grade = ActionGrade.create!(valid_attrs(discarded: true))

    grade.bank!

    assert grade.banked
    assert_not grade.discarded
  end

  test "[unit] discard! sets discarded and clears banked" do
    grade = ActionGrade.create!(valid_attrs(banked: true))

    grade.discard!

    assert grade.discarded
    assert_not grade.banked
  end

  # ---- [unit] scopes ---------------------------------------------------------

  test "[unit] by_grader filters to one grader" do
    graded = action(session_id: "scope-grader")
    alex = ActionGrade.create!(valid_attrs(atomic_action: graded, grader: ActionGrade::ALEX))
    mcr  = ActionGrade.create!(valid_attrs(atomic_action: graded, grader: ActionGrade::MCR))

    assert_equal [alex.id], ActionGrade.by_grader(ActionGrade::ALEX).where(atomic_action: graded).pluck(:id)
    assert_equal [mcr.id], ActionGrade.by_grader(ActionGrade::MCR).where(atomic_action: graded).pluck(:id)
  end

  test "[unit] for_action scopes to a single action" do
    mine  = action(session_id: "for-action-mine")
    other = action(session_id: "for-action-other")
    grade = ActionGrade.create!(valid_attrs(atomic_action: mine))
    ActionGrade.create!(valid_attrs(atomic_action: other))

    assert_equal [grade.id], ActionGrade.for_action(mine).pluck(:id)
  end

  # ---- [integration] Insight Bank: bank → appears, discard → excluded --------

  test "[integration] banking a grade lands it in the Insight Bank scope" do
    grade = ActionGrade.create!(valid_attrs(slug: "promote this to a guardrail"))

    assert_not_includes ActionGrade.banked, grade

    grade.bank!

    assert_includes ActionGrade.banked, grade, "a banked grade appears in the Insight Bank"
  end

  test "[integration] discarding a banked grade removes it from the Insight Bank" do
    grade = ActionGrade.create!(valid_attrs)
    grade.bank!
    assert_includes ActionGrade.banked, grade

    grade.discard!

    assert_not_includes ActionGrade.banked, grade, "a discarded grade is excluded from the Bank"
    assert_includes ActionGrade.discarded, grade
  end

  # ---- [integration] alex grade + mcr audit are two rows on one action -------

  test "[integration] an action carries Alex's grade and the McRitchie audit as two rows" do
    graded = action(session_id: "two-row-sess")

    alex = ActionGrade.create!(
      atomic_action: graded, grader: ActionGrade::ALEX,
      slug: "slow diagnosing the nullable column", disposition: ActionGrade::NOT,
      long_form: "Three failed migrations before spotting the missing default."
    )
    mcr = ActionGrade.create!(
      atomic_action: graded, grader: ActionGrade::MCR,
      slug: "agree, check sibling defaults first", disposition: ActionGrade::GOOD,
      long_form: "Right call — promote this to a guardrail memory."
    )

    assert_equal 2, graded.action_grades.count
    assert_equal [alex.id], graded.action_grades.by_grader(ActionGrade::ALEX).pluck(:id)
    assert_equal [mcr.id], graded.action_grades.by_grader(ActionGrade::MCR).pluck(:id)
    assert mcr.mcr?, "the McRitchie row audits Alex's grade for that action"
  end

  test "[integration] destroying the action destroys its grades" do
    graded = action(session_id: "cascade-sess")
    ActionGrade.create!(valid_attrs(atomic_action: graded, grader: ActionGrade::ALEX))
    ActionGrade.create!(valid_attrs(atomic_action: graded, grader: ActionGrade::MCR))

    assert_difference -> { ActionGrade.count }, -2 do
      graded.destroy
    end
  end

  # ---- [unit] dual target (span grading) + XOR -------------------------------

  test "[unit] valid when targeting an event span instead of an action" do
    grade = ActionGrade.new(event_valid_attrs)

    assert grade.valid?, grade.errors.full_messages.to_sentence
    assert grade.event_grade?, "a grade with an atomic_event_id targets a span"
  end

  test "[unit] targeting BOTH an action and an event is invalid (XOR)" do
    grade = ActionGrade.new(valid_attrs(atomic_event: event))

    assert_not grade.valid?
    assert_includes grade.errors[:base], "must grade exactly one of an action or an event"
  end

  test "[unit] an event grade persists with a null atomic_action_id" do
    grade = ActionGrade.create!(event_valid_attrs)

    assert grade.persisted?
    assert_nil grade.atomic_action_id
    assert grade.atomic_event_id.present?
  end

  # ---- [unit] uniqueness per (event, grader) --------------------------------

  test "[unit] one grade per grader on a given event" do
    span = event(session_id: "ev-uniq-sess")
    ActionGrade.create!(event_valid_attrs(atomic_event: span, grader: ActionGrade::ALEX))

    dup = ActionGrade.new(event_valid_attrs(atomic_event: span, grader: ActionGrade::ALEX))

    assert_not dup.valid?
    assert_includes dup.errors[:grader], "has already been taken"
  end

  test "[unit] an event carries Alex's grade and the McRitchie audit as two rows" do
    span = event(session_id: "ev-two-row")
    alex = ActionGrade.create!(event_valid_attrs(atomic_event: span, grader: ActionGrade::ALEX))
    mcr  = ActionGrade.create!(event_valid_attrs(atomic_event: span, grader: ActionGrade::MCR))

    assert_equal 2, span.action_grades.count
    assert_equal [alex.id], span.action_grades.by_grader(ActionGrade::ALEX).pluck(:id)
    assert_equal [mcr.id], span.action_grades.by_grader(ActionGrade::MCR).pluck(:id)
  end

  test "[unit] the same grader may grade both an action and an event" do
    act  = ActionGrade.create!(valid_attrs(atomic_action: action(session_id: "cross-act")))
    span = ActionGrade.new(event_valid_attrs(atomic_event: event(session_id: "cross-ev")))

    assert act.persisted?
    assert span.valid?, span.errors.full_messages.to_sentence
  end

  # ---- [unit] for_event scope ------------------------------------------------

  test "[unit] for_event scopes to a single event" do
    mine  = event(session_id: "for-event-mine")
    other = event(session_id: "for-event-other")
    grade = ActionGrade.create!(event_valid_attrs(atomic_event: mine))
    ActionGrade.create!(event_valid_attrs(atomic_event: other))

    assert_equal [grade.id], ActionGrade.for_event(mine).pluck(:id)
  end

  # ---- [integration] bank!/discard! on an event grade ------------------------

  test "[integration] banking an event grade lands it in the Insight Bank" do
    grade = ActionGrade.create!(event_valid_attrs(slug: "promote this to a guardrail"))

    assert_not_includes ActionGrade.banked, grade

    grade.bank!

    assert grade.banked
    assert_includes ActionGrade.banked, grade, "a banked span grade appears in the Insight Bank"
  end

  test "[integration] discarding a banked event grade removes it from the Bank" do
    grade = ActionGrade.create!(event_valid_attrs)
    grade.bank!
    assert_includes ActionGrade.banked, grade

    grade.discard!

    assert grade.discarded
    assert_not grade.banked
    assert_not_includes ActionGrade.banked, grade
  end

  # ---- [integration] a span deletion nullifies (never destroys) its grades ---

  test "[integration] destroying a span nullifies its grades rather than deleting" do
    span  = event(session_id: "ev-nullify")
    grade = ActionGrade.create!(event_valid_attrs(atomic_event: span))

    assert_no_difference -> { ActionGrade.count } do
      span.destroy
    end

    assert_nil grade.reload.atomic_event_id, "the grade survives the span, orphaned"
  end

  # ---- [unit] insight provenance (the Insight-Bank crash fix) -----------------
  # The bank renders provenance through #insight_source / #insight_label instead of
  # dereferencing atomic_action unconditionally — a span grade has no action.

  test "[unit] insight_source returns the action for an action grade" do
    a = action
    grade = ActionGrade.new(valid_attrs(atomic_action: a))
    assert_equal a, grade.insight_source
  end

  test "[unit] insight_source returns the span for a span grade (never nil-derefs an action)" do
    span = event
    grade = ActionGrade.new(event_valid_attrs(atomic_event: span))
    assert_nil grade.atomic_action, "a span grade has no action target"
    assert_equal span, grade.insight_source
  end

  test "[unit] insight_source is nil once the source is removed (orphaned but still valid to read)" do
    grade = ActionGrade.new(grader: ActionGrade::ALEX, slug: "orphaned lesson body",
                            disposition: ActionGrade::GOOD)
    assert_nil grade.insight_source, "no target -> the bank shows 'source since removed', never crashes"
  end

  test "[unit] insight_label reads a span by category and an action by event slug" do
    span_grade = ActionGrade.new(event_valid_attrs(atomic_event: event(category: "Verify")))
    assert_equal "Verify", span_grade.insight_label

    a = action(event_slug: "Add the auth gate")
    action_grade = ActionGrade.new(valid_attrs(atomic_action: a))
    assert_equal "Add the auth gate", action_grade.insight_label
  end

  test "[unit] insight_label falls back to the tool kind when an action has no event slug" do
    a = action(event_slug: nil, kind: "bash")
    grade = ActionGrade.new(valid_attrs(atomic_action: a))
    assert_equal "bash", grade.insight_label
  end
end
