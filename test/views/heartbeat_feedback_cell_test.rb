require "test_helper"

# [component] the inline feedback cells in the trajectory table — the good/not radios
# (which persist the disposition without opening the drawer), the grade slug, and the
# bank/discard markers. Rendered through the full table partial so the <td> cells sit
# in a real <table> (a bare <td> is dropped by the HTML parser assert_select uses).
class HeartbeatFeedbackCellTest < ActionView::TestCase
  def action(**attrs)
    AtomicAction.create!({ session_id: "fbcell", kind: "edit", outcome: "ok", actor: "agent",
                           seq: attrs.fetch(:seq, 0), occurred_at: Time.current,
                           event_slug: "Implement the view code" }.merge(attrs))
  end

  def render_table(action, grades)
    render partial: "heartbeat/trajectory_table",
           locals: { groups: [["building", [action]]], pokemon_by_slug: {}, grades: grades }
  end

  test "[component] every row carries inline good/not radios for Alex and the McRitchie audit" do
    a = action(stage: "building")

    render_table(a, {})

    assert_select "td#fb-alex-#{a.id} input[type=radio][name=disposition][value=good]"
    assert_select "td#fb-alex-#{a.id} input[type=radio][name=disposition][value=not]"
    assert_select "td#fb-mcr-#{a.id} input[type=radio][name=disposition][value=good]"
    assert_select "td#fb-mcr-#{a.id} input[type=radio][name=disposition][value=not]"
    # ungraded -> the add-slug prompt, no disposition selected
    assert_select "td#fb-alex-#{a.id} .hb-addfb"
    assert_select "td#fb-alex-#{a.id} label.hb-rb.on-good", false
    assert_select "td#fb-alex-#{a.id} [data-test=clear-grade-alex]", false
  end

  test "[component] a stored disposition renders as the selected radio and shows the slug" do
    a = action(stage: "building")
    grade = ActionGrade.create!(atomic_action: a, grader: ActionGrade::ALEX,
                                slug: "good catch flagging the gaps", disposition: ActionGrade::GOOD)

    render_table(a, { a.id => { "alex" => grade } })

    assert_select "td#fb-alex-#{a.id} label.hb-rb.on-good"
    assert_select "td#fb-alex-#{a.id} input[type=radio][value=good][checked=checked]"
    assert_select "td#fb-alex-#{a.id} button[data-test=clear-grade-alex][name=intent][value=clear]", text: "×"
    assert_select "td#fb-alex-#{a.id} .hb-fbslug", text: "good catch flagging the gaps"
  end

  test "[component] a not disposition highlights the not radio" do
    a = action(stage: "building")
    grade = ActionGrade.create!(atomic_action: a, grader: ActionGrade::ALEX,
                                slug: "slow diagnosing the column", disposition: ActionGrade::NOT)

    render_table(a, { a.id => { "alex" => grade } })

    assert_select "td#fb-alex-#{a.id} label.hb-rb.on-not"
    assert_select "td#fb-alex-#{a.id} input[type=radio][value=not][checked=checked]"
  end

  test "[component] a banked grade shows the bank marker" do
    a = action(stage: "building")
    grade = ActionGrade.create!(atomic_action: a, grader: ActionGrade::ALEX,
                                slug: "promote this to a guardrail", disposition: ActionGrade::GOOD, banked: true)

    render_table(a, { a.id => { "alex" => grade } })

    assert_select "td#fb-alex-#{a.id} .hb-bankmark"
    assert_select "td#fb-alex-#{a.id} .hb-discardmark", false
  end

  test "[component] a discarded grade shows the discard marker" do
    a = action(stage: "building")
    grade = ActionGrade.create!(atomic_action: a, grader: ActionGrade::ALEX,
                                slug: "noise not worth keeping here", disposition: ActionGrade::NOT, discarded: true)

    render_table(a, { a.id => { "alex" => grade } })

    assert_select "td#fb-alex-#{a.id} .hb-discardmark"
    assert_select "td#fb-alex-#{a.id} .hb-bankmark", false
  end

  test "[component] a long-form note shows the long-form marker" do
    a = action(stage: "building")
    grade = ActionGrade.create!(atomic_action: a, grader: ActionGrade::ALEX,
                                slug: "good catch flagging the gaps", disposition: ActionGrade::GOOD,
                                long_form: "Anchor: flag the gap before building.")

    render_table(a, { a.id => { "alex" => grade } })

    assert_select "td#fb-alex-#{a.id} .hb-longmark"
  end
end
