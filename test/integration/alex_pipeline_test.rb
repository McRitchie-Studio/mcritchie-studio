require "test_helper"

# [integration] the OPSD distillation pipeline page — three columns (Actions →
# Insights → Confirmations) — plus the McRitchie "Confirm" write. The read page is
# a public meta surface; the confirm write is admin-gated on the current release
# gate (public once make-grading-actions-public lands), so its test logs in.
class AlexPipelineTest < ActionDispatch::IntegrationTest
  def span(session_id:, reason:, **attrs)
    AtomicEvent.create!({ session_id: session_id, category: attrs.delete(:category) || "Verify",
                          reason_slug: reason, opened_at: Time.current,
                          seq: attrs.delete(:seq) || 0 }.merge(attrs))
  end

  test "[integration] the pipeline page is public and renders all three columns" do
    get alex_pipeline_path

    assert_response :success
    assert_select "[data-test=alex-pipeline]"
    assert_select "#col-actions"
    assert_select "#col-insights"
    assert_select "#col-confirmations"
    # the required link to the full All Spans view
    assert_select "a[href=?]", heartbeat_all_spans_path
  end

  test "[integration] column 1 shows a span with its type, narration, cost slot and NOT flag" do
    s = span(session_id: "pl-1", reason: "review the diff", category: "Verify", outcome_slug: "approved")
    ActionGrade.create!(atomic_event: s, grader: "alex", disposition: "not", slug: "missed the edge case")

    get alex_pipeline_path

    assert_select "[data-test=pl-span]" do
      assert_select ".hb-catchip", text: "Verify"
      assert_select ".pl-narr", text: "review the diff"
    end
    assert_select "[data-test=pl-not]", { count: 1 }, "an Alex 'not' grade flags the span"
  end

  test "[integration] column 2 shows an Alex insight with a Confirm button" do
    s = span(session_id: "pl-2", reason: "narrated cleanly")
    g = ActionGrade.create!(atomic_event: s, grader: "alex", disposition: "good",
                            slug: "write the failing test first", long_form: "red before green")
    g.bank!

    get alex_pipeline_path

    assert_select "[data-test=pl-insight]" do
      assert_select ".pl-slug", text: "write the failing test first"
      assert_select ".pl-long", text: "red before green"
    end
    assert_select "form[action=?]", alex_pipeline_confirm_path(s.id) # the Confirm button posts here
  end

  test "[integration] a confirmed insight shows Confirmed instead of a button; column 3 lists it" do
    s = span(session_id: "pl-3", reason: "solid span here")
    ActionGrade.create!(atomic_event: s, grader: "alex", disposition: "good", slug: "keep this lesson").bank!
    ActionGrade.create!(atomic_event: s, grader: "mcr", disposition: "good", slug: "keep this lesson")

    get alex_pipeline_path

    assert_select "[data-test=pl-insight-confirmed]"
    assert_select "[data-test=pl-confirmation]" do
      assert_select ".pl-slug", text: "keep this lesson"
    end
  end

  # ── the Confirm write ───────────────────────────────────────────────────────

  test "[integration] Confirm records a McRitchie mcr grade and redirects back" do
    s = span(session_id: "pl-confirm", reason: "confirm me")
    ActionGrade.create!(atomic_event: s, grader: "alex", disposition: "good", slug: "a good lesson").bank!
    log_in_as(users(:alex)) # admin — the write is gated until make-grading-actions-public lands

    assert_difference -> { ActionGrade.by_grader("mcr").count }, 1 do
      post alex_pipeline_confirm_path(s.id), params: { slug: "a good lesson" }
    end

    assert_redirected_to alex_pipeline_path(anchor: "col-confirmations")
    conf = ActionGrade.for_event(s).by_grader("mcr").first
    assert_equal "good", conf.disposition
    assert_equal "a good lesson", conf.slug
  end

  test "[integration] re-confirming the same span updates the one mcr row (idempotent)" do
    s = span(session_id: "pl-reconfirm", reason: "reconfirm me")
    log_in_as(users(:alex))

    post alex_pipeline_confirm_path(s.id), params: { slug: "first" }
    assert_no_difference -> { ActionGrade.by_grader("mcr").count } do
      post alex_pipeline_confirm_path(s.id), params: { slug: "second" }
    end
    assert_equal "second", ActionGrade.for_event(s).by_grader("mcr").first.slug
  end
end
