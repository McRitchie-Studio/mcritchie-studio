require "test_helper"

# [unit] AgentSession: tier by soul, task scope for studio, no scope for admin,
# expiry, issued_by, and the token round trip.
class AgentSessionTest < ActiveSupport::TestCase
  setup do
    @task = tasks(:in_progress_task) # building
  end

  def studio(**attrs)
    AgentSession.create!({ soul: "pokemon", tier: "studio", task_slug: @task.slug, issued_by: "task_claim" }.merge(attrs))
  end

  test "a studio session is scoped to one task and expires in 24 hours" do
    freeze_time do
      session = studio

      assert session.studio?
      assert_equal @task.slug, session.task_slug
      assert_equal 24.hours.from_now, session.expires_at
      assert_match(/\Asess-\h{16}\z/, session.slug)
    end
  end

  test "a studio session needs a task" do
    session = AgentSession.new(soul: "pokemon", tier: "studio", issued_by: "task_claim")

    refute session.valid?
    assert_includes session.errors[:task_slug].join, "scoped to one task"
  end

  test "a studio session is issued only by a claim" do
    session = AgentSession.new(soul: "carl", tier: "studio", task_slug: @task.slug, issued_by: "operator_grant")

    refute session.valid?
    assert_includes session.errors[:issued_by].join, "task_claim or review_claim"
  end

  test "an admin session carries no task scope and expires in 8 hours" do
    freeze_time do
      session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")

      assert session.admin?
      assert_nil session.task_slug
      assert_equal 8.hours.from_now, session.expires_at
    end
  end

  test "an admin session refuses a task scope: the tier is the scope" do
    session = AgentSession.new(soul: "xan", tier: "admin", task_slug: @task.slug, issued_by: "operator_grant")

    refute session.valid?
    assert_includes session.errors[:task_slug].join, "unscoped within the admin tier"
  end

  test "admin is held only by the admin souls" do
    session = AgentSession.new(soul: "carl", tier: "admin", issued_by: "operator_grant")

    refute session.valid?
    assert_includes session.errors[:tier].join, "steffon and xan"
  end

  test "an admin soul may hold a narrower studio session" do
    assert studio(soul: "steffon").valid?
  end

  test "client tier is for the client souls, and a client soul holds no studio session" do
    assert AgentSession.new(soul: "tyrion", tier: "client", issued_by: "runtime_key").valid?
    refute AgentSession.new(soul: "carl", tier: "client", issued_by: "runtime_key").valid?
    refute AgentSession.new(soul: "turf-monster", tier: "studio", task_slug: @task.slug, issued_by: "task_claim").valid?
  end

  test "a slug that is no soul is refused, and an alias resolves to its successor" do
    refute AgentSession.new(soul: "nobody", tier: "studio", task_slug: @task.slug, issued_by: "task_claim").valid?
    assert_equal "xan", AgentSession.create!(soul: "alex", tier: "admin", issued_by: "operator_grant").soul
  end

  test "covers_task?: studio its own task only, admin any task, client none" do
    other = tasks(:queued_task)

    assert studio.covers_task?(@task.slug)
    refute studio.covers_task?(other.slug)
    admin = AgentSession.create!(soul: "xan", tier: "admin", issued_by: "launch_phrase")
    assert admin.covers_task?(other.slug)
    refute AgentSession.create!(soul: "tyrion", tier: "client", issued_by: "runtime_key").covers_task?(@task.slug)
  end

  test "a live session has no refusal reason" do
    assert_nil studio.refusal_reason
  end

  test "a revoked session names who revoked it" do
    session = studio
    session.revoke!(by: "pokemon")

    assert_match(/revoked by pokemon/, session.refusal_reason)
  end

  test "an expired session names when it expired" do
    session = studio
    travel 25.hours do
      assert_match(/expired at/, session.refusal_reason)
    end
  end

  test "a studio session ends when its task leaves building and review" do
    session = studio
    assert_nil session.refusal_reason
    @task.update_column(:stage, "submitted")
    assert_nil session.refusal_reason, "a task under review keeps its session"
    @task.update_column(:stage, "reviewed")

    assert_match(/left building and review \(it is reviewed\)/, session.refusal_reason)
  end

  test "an admin session does not end with any task" do
    session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")

    assert_nil session.refusal_reason
  end

  test "the token names the session and nothing else verifies as one" do
    session = studio

    assert_equal session, AgentSession.from_token(session.token)
    legacy = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    assert_nil AgentSession.from_token(legacy)
    assert_nil AgentSession.from_token("junk")
  end

  test "issue_studio! revokes the soul's earlier session on the same task" do
    first = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")
    second = AgentSession.issue_studio!(soul: "pokemon", task: @task, issued_by: "task_claim")

    assert first.reload.revoked?
    assert_equal "reissue", first.revoked_by
    refute second.revoked?
  end

  test "soul, tier and scope cannot change after login" do
    session = studio
    %i[tier task_slug soul].each do |attribute|
      assert_raises(ActiveRecord::ReadonlyAttributeError) { session.update(attribute => nil) }
    end

    session.reload
    assert_equal %w[pokemon studio], [session.soul, session.tier]
    assert_equal @task.slug, session.task_slug
  end
  # The mint endpoint asks this before it issues a studio login: the task record,
  # not the request, names the souls a login is for.
  test "a task_claim login is for the soul the claim stamped, and no other" do
    @task.update_column(:metadata, { "devops" => { "built_by" => "pokemon", "builders" => %w[pokemon jasper] } })

    assert_nil AgentSession.studio_login_refusal(soul: "pokemon", task: @task, issued_by: "task_claim")
    assert_nil AgentSession.studio_login_refusal(soul: "jasper", task: @task, issued_by: "task_claim")
    assert_match(/carl is not #{@task.slug}'s builder/,
                 AgentSession.studio_login_refusal(soul: "carl", task: @task, issued_by: "task_claim"))
  end

  test "a task with no recorded builder entitles no task_claim login" do
    assert_match(/the claim recorded none/,
                 AgentSession.studio_login_refusal(soul: "pokemon", task: @task, issued_by: "task_claim"))
  end

  test "a review_claim login is for a named reviewer who did not build the task" do
    @task.update_column(:metadata, { "devops" => { "built_by" => "pokemon" },
                                     "reviewers" => [{ "slug" => "carl", "weight" => "primary" }] })

    assert_nil AgentSession.studio_login_refusal(soul: "carl", task: @task, issued_by: "review_claim")
    assert_match(/not a reviewer/, AgentSession.studio_login_refusal(soul: "steffon", task: @task, issued_by: "review_claim"))
    assert_match(/built #{@task.slug}/,
                 AgentSession.studio_login_refusal(soul: "pokemon", task: @task, issued_by: "review_claim"))
  end

  # ---- the review claim's login --------------------------------------------------

  def review_task(builder: "pokemon")
    task = Task.create!(title: "Review Login Target", stage: "submitted")
    task.update_column(:metadata, { "devops" => { "built_by" => builder, "builders" => [builder] } })
    task
  end

  def claim(task, reviewer: "carl", session: "rev-1", mint_session: true, now: Time.current)
    TaskReviewClaim.acquire(task_slug: task.slug, session: session, nonce: "n-#{session}", reviewer: reviewer,
                            mint_session: mint_session, now: now)
  end

  test "review_claim session scoped ends at verdict" do
    task = review_task
    session = claim(task).agent_session

    assert_equal %w[carl studio review_claim], [session.soul, session.tier, session.issued_by]
    assert_equal "rev-1", session.harness_session_id
    assert session.covers_task?(task.slug)
    refute session.covers_task?(@task.slug)
    assert_nil session.refusal_reason

    task.update_column(:stage, "reviewed")
    assert_match(/ended when #{task.slug} left review \(it is reviewed\)/, session.refusal_reason)
    task.update_column(:stage, "building") # a block lands the task on building
    assert_match(/left review \(it is building\)/, session.refusal_reason)
  end

  test "a builder's session outlives the block that ends the reviewer's" do
    task = review_task
    builder = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")
    reviewer = claim(task).agent_session
    task.update_column(:stage, "building")

    assert_nil builder.refusal_reason
    assert reviewer.refusal_reason
  end

  test "a review_claim session is revoked when its claim is released" do
    task = review_task
    session = claim(task).agent_session
    TaskReviewClaim.release(task_slug: task.slug, session: "rev-1", nonce: "n-rev-1")

    assert_match(/revoked by review_claim_released/, session.reload.refusal_reason)
  end

  test "a review_claim session is refused while its claim is lapsed" do
    task = review_task
    session = claim(task).agent_session

    travel ClaimLease::REVIEW_TTL_SECONDS + 1 do
      assert_match(/review claim on #{task.slug} is not live/, session.refusal_reason)
    end
    assert_nil session.refusal_reason, "the same session is live while the claim is"
  end

  test "a review_claim session is revoked when the claim changes hands or the task is resubmitted" do
    task = review_task
    first = claim(task).agent_session
    later = Time.current + ClaimLease::REVIEW_TTL_SECONDS + 1
    second = claim(task, reviewer: "jasper", session: "rev-2", now: later).agent_session

    assert first.reload.revoked?
    refute second.revoked?

    TaskReviewClaim.release_for_new_submission!(task.slug)
    assert second.reload.revoked?
  end

  test "a renewing acquire keeps the reviewer's session" do
    task = review_task
    first = claim(task).agent_session

    assert_equal first, claim(task).agent_session
    refute first.reload.revoked?
  end

  test "a claim mints no session unless asked, and none for a soul with no review login" do
    assert_nil claim(review_task, mint_session: false).agent_session
    assert_nil claim(review_task, reviewer: "").agent_session
    assert_nil claim(review_task, reviewer: "avi").agent_session, "avi is outside the reviewer pool"

    building = review_task
    building.update_column(:stage, "building")
    outcome = claim(building)
    assert outcome.acquired
    assert_nil outcome.agent_session

    refused = claim(review_task(builder: "carl"))
    refute refused.acquired
    assert_nil refused.agent_session
  end

  test "transition_refusal: submitted to reviewed or blocked needs a reviewer outside the author set" do
    task = review_task
    builder = AgentSession.issue_studio!(soul: "pokemon", task: task, issued_by: "task_claim")
    reviewer = claim(task).agent_session
    admin = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")

    %w[reviewed blocked].each do |to|
      assert_match(/submitted to #{to} .* pokemon holds a task_claim session/, builder.transition_refusal(task, to))
      assert_nil reviewer.transition_refusal(task, to)
      assert_nil admin.transition_refusal(task, to)
    end
    assert_nil builder.transition_refusal(task, "building")

    # A reviewer who joins the author set (a fix-forward) is no longer outside it.
    task.update_column(:metadata, { "devops" => { "built_by" => "pokemon", "builders" => %w[pokemon carl] } })
    assert_match(/carl is one of its authors/, reviewer.transition_refusal(task.reload, "reviewed"))
  end

  test "transition_refusal: archived is an admin transition from any stage" do
    builder = studio
    admin = AgentSession.create!(soul: "xan", tier: "admin", issued_by: "operator_grant")

    assert_match(/building to archived is an admin transition; pokemon holds a studio session/,
                 builder.transition_refusal(@task, "archived"))
    assert_nil admin.transition_refusal(@task, "archived")
    assert_nil builder.transition_refusal(@task, "submitted")
  end
end
