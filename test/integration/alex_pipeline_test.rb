require "test_helper"

# [integration] the OPSD distillation pipeline page — three columns (Activities →
# Insights → Confirmations) — plus the McRitchie "Confirm" write. The read page is
# a public meta surface; the confirm write is admin-gated on the current release
# gate (public once make-grading-actions-public lands), so its test logs in.
class AlexPipelineTest < ActionDispatch::IntegrationTest
  def span(session_id:, reason:, **attrs)
    AgentActivity.create!({ session_id: session_id, category: attrs.delete(:category) || "Verify",
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
    # the required link to the full All Activities view
    assert_select "a[href=?]", heartbeat_all_activities_path
  end

  test "[integration] column 1 shows an activity with its type, narration, cost slot and NOT flag" do
    s = span(session_id: "pl-1", reason: "review the diff", category: "Verify", outcome_slug: "approved")
    ActionGrade.create!(agent_activity: s, grader: "alex", disposition: "not", slug: "missed the edge case")

    get alex_pipeline_path

    assert_select "[data-test=pl-activity]" do
      assert_select ".hb-catchip", text: "Verify"
      assert_select ".pl-narr", text: "review the diff"
    end
    assert_select "[data-test=pl-not]", { count: 1 }, "an Alex 'not' grade flags the span"
  end

  test "[integration] column 2 shows an Alex insight with a Confirm button" do
    s = span(session_id: "pl-2", reason: "narrated cleanly")
    g = ActionGrade.create!(agent_activity: s, grader: "alex", disposition: "good",
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
    ActionGrade.create!(agent_activity: s, grader: "alex", disposition: "good", slug: "keep this lesson").bank!
    ActionGrade.create!(agent_activity: s, grader: "mcr", disposition: "good", slug: "keep this lesson")

    get alex_pipeline_path

    assert_select "[data-test=pl-insight-confirmed]"
    assert_select "[data-test=pl-confirmation]" do
      assert_select ".pl-slug", text: "keep this lesson"
    end
  end

  # ── test runs · release test-scope verdicts, each gradeable ─────────────────

  def make_test_run(scope:, result:, session_id: "tr-1", summary: nil, duration_ms: 1200, **attrs)
    AgentAction.create!({
      session_id: session_id, kind: "test_scope", event_slug: scope, result_slug: result,
      summary: summary || "test scope #{scope} #{result == 'pass' ? 'COMPLETED' : 'FAILED'} · mcritchie-studio · #{result}",
      duration_ms: duration_ms, occurred_at: Time.current, seq: 0, outcome: "ok", actor: "agent"
    }.merge(attrs))
  end

  test "[integration] the test-runs band renders a verdict with scope key, pass pill, derived meta, counts and grade link" do
    run = make_test_run(scope: "ship_test_gate", result: "pass", task_slug: "some-task",
                   summary: "test scope ship_test_gate COMPLETED · mcritchie-studio · pass · " \
                            "141 runs, 320 assertions, 0 failures, 0 errors · 12.3s · bin/rails test")

    get alex_pipeline_path

    assert_select "[data-test=pl-test-runs]"
    assert_select "[data-test=pl-test-run]" do
      assert_select ".pl-slug", text: "ship_test_gate"
      assert_select "[data-test=pl-test-verdict].good", text: "pass"
      # phase/tier/host DERIVED from the scope registry (ship_test_gate → ship/full/local)
      assert_select ".pl-tag", text: "ship"
      assert_select ".pl-tag", text: "full"
      assert_select ".pl-tag", text: "local"
      # counts re-parsed from the summary; duration from the stored duration_ms
      assert_select ".pl-counts", text: /141 runs/
    end
    # the run links to the EXISTING action grading drawer (parity with a candidate)
    assert_select "a[href=?]", heartbeat_feedback_path(run.id)
  end

  test "[integration] a failed verdict renders the fail pill" do
    make_test_run(scope: "qa_post_deploy", result: "fail", session_id: "tr-fail",
             summary: "test scope qa_post_deploy FAILED · turf-monster-qa · fail · 1 failures · 3.1s · heroku run")

    get alex_pipeline_path

    assert_select "[data-test=pl-test-verdict].not", text: "fail"
  end

  test "[integration] an untagged START action never lands in the test-runs band" do
    # A START emit is kind:bash with no result_slug — excluded by the band query.
    AgentAction.create!(session_id: "tr-start", kind: "bash", event_slug: "ship_test_gate",
                        summary: "test scope ship_test_gate START · mcritchie-studio · bin/rails test",
                        occurred_at: Time.current, seq: 0, outcome: "ok", actor: "agent")

    get alex_pipeline_path

    assert_select "[data-test=pl-test-runs]", { count: 0 }, "no verdicts → the band is hidden"
    assert_select "[data-test=pl-test-run]", { count: 0 }
  end

  test "[integration] an Alex 'not' grade flags a test-run row" do
    run = make_test_run(scope: "pre_qa_gate", result: "pass", session_id: "tr-not")
    ActionGrade.create!(agent_action: run, grader: "alex", disposition: "not", slug: "flaky integration gate")

    get alex_pipeline_path

    assert_select "[data-test=pl-test-run].is-not", { count: 1 }
  end

  test "[integration] the test-runs band is hidden when there are none" do
    get alex_pipeline_path
    assert_select "[data-test=pl-test-runs]", { count: 0 }
  end

  # ── candidates awaiting grade · block-mined "not" grades ────────────────────

  def block_mined_candidate(task_slug:, session_id:, banked: false)
    s = span(session_id: session_id, reason: "did the risky edit", task_slug: task_slug)
    blk = Activity.create!(task_slug: task_slug, activity_type: "qa_feedback",
                           description: "stage transition bypassed the server-side guard here")
    grade = ActionGrade.create!(agent_activity: s, grader: "alex", disposition: "not",
                                slug: "stage transition bypassed the server-side",
                                long_form: blk.description, source_activity_slug: blk.slug)
    grade.bank! if banked
    [s, blk, grade]
  end

  test "[integration] a block-mined candidate is surfaced awaiting grade" do
    s, blk, = block_mined_candidate(task_slug: "task-blocked", session_id: "pl-cand")

    get alex_pipeline_path

    assert_select "[data-test=pl-candidates]"
    assert_select "[data-test=pl-candidate]" do
      assert_select ".pl-slug", text: "stage transition bypassed the server-side"
      assert_select ".pl-long", text: blk.description
    end
    # the candidate links to its span's grade drawer so it can be promoted
    assert_select "a[href=?]", heartbeat_activity_feedback_path(s.id)
  end

  test "[integration] a banked candidate leaves the awaiting-grade band (promoted to insights)" do
    block_mined_candidate(task_slug: "task-promoted", session_id: "pl-promoted", banked: true)

    get alex_pipeline_path

    assert_select "[data-test=pl-candidate]", { count: 0 }, "a banked candidate is no longer awaiting grade"
    assert_select "[data-test=pl-insight]" # it now lives in the Insights column
  end

  test "[integration] the candidates band is hidden when there are none" do
    get alex_pipeline_path
    assert_select "[data-test=pl-candidates]", { count: 0 }
  end

  # ── the Confirm write ───────────────────────────────────────────────────────

  test "[integration] Confirm records a McRitchie mcr grade and redirects back" do
    s = span(session_id: "pl-confirm", reason: "confirm me")
    ActionGrade.create!(agent_activity: s, grader: "alex", disposition: "good", slug: "a good lesson").bank!
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

  # ── confirm-of-action · a banked test-run grade reaches Column 3 ─────────────
  # An insight can target a raw ACTION (a banked test-run grade), not just an
  # activity — Confirm handles both so the test-run grade reaches Column 3, parity.

  test "[integration] a banked test-run grade shows in Column 2 with an action Confirm button" do
    run = make_test_run(scope: "ship_test_gate", result: "pass", session_id: "cfa-1")
    ActionGrade.create!(agent_action: run, grader: "alex", disposition: "good",
                        slug: "ship gate stayed green").bank!

    get alex_pipeline_path

    assert_select "[data-test=pl-insight]" do
      assert_select ".pl-slug", text: "ship gate stayed green"
    end
    # the Confirm button posts to the action's confirm URL with the agent_action_id form param
    assert_select "[data-test=pl-confirm-action-btn]"
    assert_select "form[action=?]", alex_pipeline_confirm_path(run.id)
    assert_select "input[name=agent_action_id][value=?]", run.id.to_s
  end

  test "[integration] Confirm on an action records an mcr grade for it and lists it in Column 3" do
    run = make_test_run(scope: "pre_qa_gate", result: "fail", session_id: "cfa-2")
    ActionGrade.create!(agent_action: run, grader: "alex", disposition: "not",
                        slug: "pre-qa gate flaked").bank!
    log_in_as(users(:alex)) # admin — the write is gated until make-grading-actions-public lands

    assert_difference -> { ActionGrade.for_action(run).by_grader("mcr").count }, 1 do
      post alex_pipeline_confirm_path(run.id), params: { slug: "pre-qa gate flaked", agent_action_id: run.id }
    end

    assert_redirected_to alex_pipeline_path(anchor: "col-confirmations")
    conf = ActionGrade.for_action(run).by_grader("mcr").first
    assert_equal "good", conf.disposition
    assert_equal "pre-qa gate flaked", conf.slug

    get alex_pipeline_path
    # the insight now reads Confirmed, not a button
    assert_select "[data-test=pl-insight-confirmed]"
    assert_select "[data-test=pl-confirmation]" do
      assert_select ".pl-slug", text: "pre-qa gate flaked"
    end
  end

  test "[integration] re-confirming the same action updates the one mcr row (idempotent)" do
    run = make_test_run(scope: "qa_up_smoke", result: "pass", session_id: "cfa-3")
    ActionGrade.create!(agent_action: run, grader: "alex", disposition: "good", slug: "qa boot green").bank!
    log_in_as(users(:alex))

    post alex_pipeline_confirm_path(run.id), params: { slug: "first", agent_action_id: run.id }
    assert_no_difference -> { ActionGrade.by_grader("mcr").count } do
      post alex_pipeline_confirm_path(run.id), params: { slug: "second", agent_action_id: run.id }
    end
    assert_equal "second", ActionGrade.for_action(run).by_grader("mcr").first.slug
  end
end
