require "test_helper"

# [component] the Insight Bank card's PROVENANCE meta line (heartbeat/_insight).
#
# That line reads "from #<seq> &middot; <label> &middot; <task-slug>", and the
# separator has to arrive as an HTML ENTITY while the two interpolated values —
# both untrusted — arrive as TEXT. The original spelling built one String and
# called .html_safe on the whole thing:
#
#     " &middot; #{grade.insight_label}".html_safe
#
# which marks the ENTIRE string safe, disabling escaping exactly where the
# untrusted value lands (Brakeman: High-confidence XSS, two counts). Neither value
# is developer-controlled: `insight_label` is agent-authored (an activity's
# `category`, an action's `event_slug`/`kind`) and `task_slug` derives from
# operator- and agent-written titles. None of the three columns carries a format
# validation, so markup stores fine and mcritchie.studio renders it live.
#
# These tests pin BOTH halves of the contract, because the obvious fix breaks the
# other half: drop .html_safe entirely and the value is escaped but the separator
# renders as a literal "&middot;" on the page. So each test asserts (a) the markup
# is inert AND (b) the separator survived as a real "·".
class HeartbeatInsightEscapingTest < ActionView::TestCase
  SCRIPT_PAYLOAD = %(<script>alert("label")</script>).freeze
  IMG_PAYLOAD    = %(<img src=x onerror=alert("slug")>).freeze
  MIDDOT         = "·".freeze

  def action(**attrs)
    AgentAction.create!({ session_id: "xss", kind: "edit", outcome: "ok", actor: "agent",
                          seq: 7, occurred_at: Time.current }.merge(attrs))
  end

  def activity(**attrs)
    AgentActivity.create!({ session_id: "xss", category: "Edit", reason_slug: "prove the escape",
                            seq: 9, opened_at: Time.current }.merge(attrs))
  end

  def render_insight(grade)
    render partial: "heartbeat/insight", locals: { grade: grade }
  end

  # The meta line's visible text, whitespace-collapsed the way a browser collapses it
  # (the separators sit on their own template lines). `squish` touches WHITESPACE only
  # — it never decodes entities — so the "·" vs literal "&middot;" assertions below
  # still discriminate the correct fix from the escape-everything one.
  def meta_text
    css_select(".hb-imeta").first.text.squish
  end

  # --- the label half (action source -> event_slug) ---------------------------

  test "[component] markup in an action's insight_label renders inert, separator intact" do
    a = action(event_slug: SCRIPT_PAYLOAD)
    grade = ActionGrade.create!(agent_action: a, grader: ActionGrade::ALEX,
                                slug: "escape the label", disposition: ActionGrade::GOOD)

    render_insight(grade)

    # (a) the payload did NOT become an element — this is the XSS assertion
    assert_select "script", false, "insight_label must not inject a <script> element"
    # ...and it IS on the page, as text
    assert_includes meta_text, SCRIPT_PAYLOAD
    # (b) the separator still arrived as an entity, not a literal "&middot;"
    assert_includes meta_text, MIDDOT
    refute_includes meta_text, "&middot;"
  end

  # --- the label half (action source -> kind, the event_slug fallback) --------
  #
  # insight_label's OTHER branch — an activity's `category` — is the one input in
  # this line that cannot carry markup: AgentActivity validates `category` for
  # inclusion in CATEGORIES (agent_activity.rb:77). `kind` has no such guard
  # (agent_action.rb:95 is presence-only), so the fallback arm is injectable and
  # is what this pins.
  test "[component] markup in an action's kind renders inert, separator intact" do
    a = action(kind: IMG_PAYLOAD, event_slug: nil)
    grade = ActionGrade.create!(agent_action: a, grader: ActionGrade::ALEX,
                                slug: "escape the kind", disposition: ActionGrade::GOOD)

    render_insight(grade)

    assert_select "img", false, "insight_label must not inject an <img onerror> element"
    assert_includes meta_text, IMG_PAYLOAD
    assert_includes meta_text, MIDDOT
    refute_includes meta_text, "&middot;"
  end

  # --- the activity branch, via its (unvalidated) task_slug -------------------

  test "[component] markup in an activity grade's task_slug renders inert" do
    e = activity(task_slug: IMG_PAYLOAD)
    grade = ActionGrade.create!(agent_activity: e, grader: ActionGrade::ALEX,
                                slug: "escape the activity slug", disposition: ActionGrade::GOOD)

    render_insight(grade)

    assert_select "img", false, "task_slug must not inject an <img onerror> element"
    assert_includes meta_text, IMG_PAYLOAD
    assert_includes meta_text, MIDDOT
    assert_includes meta_text, "from activity #9"
  end

  # --- the task_slug half -----------------------------------------------------

  test "[component] markup in task_slug renders inert, separator intact" do
    a = action(event_slug: "ordinary label", task_slug: IMG_PAYLOAD)
    grade = ActionGrade.create!(agent_action: a, grader: ActionGrade::ALEX,
                                slug: "escape the slug", disposition: ActionGrade::GOOD)

    render_insight(grade)

    assert_select "img", false, "task_slug must not inject an <img onerror> element"
    assert_includes meta_text, IMG_PAYLOAD
    assert_includes meta_text, MIDDOT
    refute_includes meta_text, "&middot;"
  end

  # --- both at once, the live shape ------------------------------------------

  test "[component] both interpolations escaped together with two separators" do
    a = action(event_slug: SCRIPT_PAYLOAD, task_slug: IMG_PAYLOAD)
    grade = ActionGrade.create!(agent_action: a, grader: ActionGrade::ALEX,
                                slug: "escape both", disposition: ActionGrade::GOOD)

    render_insight(grade)

    assert_select "script", false
    assert_select "img", false
    assert_equal 2, meta_text.scan(MIDDOT).size, "both separators must render as ·"
    assert_includes meta_text, "from #7"
  end

  # --- the whole-output guard -------------------------------------------------
  #
  # Every other test here scopes its assertions to `.hb-imeta`, which is blind to
  # anything that lands OUTSIDE that div. The explanatory ERB comment above the div
  # originally contained a literal output-tag example; its "%" + ">" closed the
  # `<%#` comment early and dumped the remaining prose onto the page as visible
  # text — with all the scoped tests still green. This guard reads the ENTIRE
  # rendered partial, so a comment that stops commenting fails the suite.
  test "[component] the explanatory comment never leaks onto the page" do
    a = action(event_slug: "label here", task_slug: "slug-here")
    grade = ActionGrade.create!(agent_action: a, grader: ActionGrade::ALEX,
                                slug: "no leak", disposition: ActionGrade::GOOD)

    render_insight(grade)

    %w[Brakeman html_safe interpolated separator escaping untrusted].each do |probe|
      refute_includes rendered, probe,
                      "ERB comment leaked #{probe.inspect} into the rendered page"
    end
    refute_includes rendered, "%>", "an unterminated ERB tag leaked into the output"
  end

  # --- the benign path still reads correctly ---------------------------------

  test "[component] a plain label and slug render with the middot separators" do
    a = action(event_slug: "Implement the view code", task_slug: "escape-insight-label-and-slug")
    grade = ActionGrade.create!(agent_action: a, grader: ActionGrade::ALEX,
                                slug: "plain provenance", disposition: ActionGrade::GOOD)

    render_insight(grade)

    assert_includes meta_text, "from #7 #{MIDDOT} Implement the view code"
    assert_includes meta_text, "#{MIDDOT} escape-insight-label-and-slug"
  end
end
