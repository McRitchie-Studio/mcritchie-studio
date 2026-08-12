require "test_helper"

class TriageControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:viewer)
    @finding = TriageFinding.create!(
      title: "Raise hub web concurrency",
      body: "Outage follow-up: hub web dynos run single-process.",
      source: "release-retro", repo: "mcritchie-studio"
    )
  end

  test "[component] index renders open findings for any visitor" do
    get triage_path
    assert_response :success
    assert_match @finding.title, response.body
    assert_match @finding.slug, response.body
    # The board nav renders here too — /triage must not strand the visitor.
    assert_select "a[href=?]", deployments_path
  end

  test "[component] promote controls render only for an admin" do
    get triage_path
    refute_match 'value="Promote"', response.body

    log_in_as(@admin)
    get triage_path
    assert_match 'value="Promote"', response.body
  end

  test "[integration] promote mints a designed task and stamps the finding" do
    log_in_as(@admin)
    assert_difference "Task.count", 1 do
      post promote_triage_finding_path(@finding.slug),
           params: { title: "Raise Hub Web Concurrency", kind: "chore" }
    end

    task = Task.order(:created_at).last
    assert_equal "designed", task.stage
    assert_equal "chore", task.metadata.dig("devops", "kind")
    assert_includes task.metadata.dig("devops", "agent_context").to_s, @finding.slug
    assert_equal ["mcritchie-studio"], task.metadata.dig("devops", "repositories")

    @finding.reload
    assert_equal "promoted", @finding.status
    assert_equal task.slug, @finding.promoted_task_slug
  end

  test "[integration] promote surfaces a task validation failure without stamping" do
    log_in_as(@admin)
    assert_no_difference "Task.count" do
      post promote_triage_finding_path(@finding.slug), params: { title: "Too long a task title to pass validation", kind: "chore" }
    end
    assert_equal "open", @finding.reload.status
  end

  test "[integration] promote and dismiss are admin-gated" do
    log_in_as(@viewer)
    post promote_triage_finding_path(@finding.slug), params: { title: "Raise Hub Web Concurrency" }
    assert_equal "open", @finding.reload.status

    post dismiss_triage_finding_path(@finding.slug)
    assert_equal "open", @finding.reload.status
  end

  test "[integration] dismiss retires the finding for an admin" do
    log_in_as(@admin)
    post dismiss_triage_finding_path(@finding.slug)
    assert_equal "dismissed", @finding.reload.status
  end

  # PROMOTION is where a finding stops being a note and becomes the brief someone
  # WORKS from — the exact hop where the false framing in finding-6a5fdcd157b3
  # propagated ("I inherited that framing"). An uninvestigated finding must hand
  # its builder the caveat and the instruction, not a clean slate.
  test "[integration] promoting an uninvestigated finding carries the caveat into agent_context" do
    log_in_as(@admin)
    post promote_triage_finding_path(@finding.slug),
         params: { title: "Raise Hub Web Concurrency", kind: "chore" }

    context = Task.order(:created_at).last.metadata.dig("devops", "agent_context").to_s
    assert_includes context, "PRIOR ART: NOT INVESTIGATED"
    assert_includes context, "BEFORE assuming this change introduced it"
    assert_includes context, @finding.body, "the discovery still rides through verbatim"
  end

  test "[integration] promoting an investigated finding carries the answer, not a nag" do
    log_in_as(@admin)
    note = "TM's deleted preview view carried the identical iframe since 2025-11"
    @finding.update!(prior_art: "found", prior_art_note: note)
    post promote_triage_finding_path(@finding.slug),
         params: { title: "Raise Hub Web Concurrency", kind: "chore" }

    context = Task.order(:created_at).last.metadata.dig("devops", "agent_context").to_s
    assert_includes context, "PRIOR ART: checked — #{note}"
    refute_includes context, "NOT INVESTIGATED"
  end

  # [component] the inbox card states prior art for EVERY finding. Rendering only
  # the answered ones would put "nobody looked" back into a blank, which is the
  # read this whole change exists to remove.
  test "[component] the inbox card renders the uninvestigated warning" do
    get triage_path
    assert_response :success
    assert_match(/⚠ Prior art/, response.body)
    assert_match(/NOT INVESTIGATED/, response.body)
  end

  test "[component] an investigated finding renders its answer instead of the warning" do
    @finding.update!(prior_art: "none")
    get triage_path
    assert_response :success
    assert_match(/none found/i, response.body)
    refute_match(/⚠ Prior art: NOT INVESTIGATED/, response.body)
  end

  test "[integration] promote refuses an already-resolved finding" do
    log_in_as(@admin)
    @finding.dismiss!
    assert_no_difference "Task.count" do
      post promote_triage_finding_path(@finding.slug), params: { title: "Raise Hub Web Concurrency" }
    end
    assert_equal "dismissed", @finding.reload.status
    assert_nil @finding.promoted_task_slug
  end
end
