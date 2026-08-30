require "test_helper"

# [integration] The builder stamp, through the API route the CLI calls.
#
# WHAT THIS FILE LOOKED LIKE BEFORE, and why it was worthless: it drove
# Task#builder_to_stamp, which was never broken. A reviewer deleted all 40 lines
# of the production change and 7 of 7 tests still passed. Green tests over a dead
# feature. These cover the mechanism that ACTUALLY carries a builder — rule 4,
# agent_slug — because that is what the fast lane now populates.
class BuilderStampApiTest < ActionDispatch::IntegrationTest
  def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

  def claim!(task, actor:)
    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "building", event: { actor: actor } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  test "a task created with an agent records that soul as the builder" do
    # THE WHOLE FIX. `bin/task begin --agent carl` sets agent_slug; rule 4 stamps
    # built_by from it. No new code, no marker, no --actor — the seam already
    # existed and no documented path passed the flag.
    task = Task.create!(title: "Agent Slug Builder Probe", stage: "designed",
                        agent_slug: "carl", metadata: { "devops" => {} })

    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    assert_response :success
    assert_equal "carl", task.reload.metadata.dig("devops", "built_by"),
                 "agent_slug must carry the builder even when the actor is a session id"
  end

  test "no agent and a session actor leaves the builder blank" do
    # The status quo the fast lane produced for six consecutive tasks. Blank is
    # the CORRECT outcome for an unidentified builder — reviewer-select then
    # fails closed and refuses, which is why the fix is to identify the builder
    # rather than to loosen the selector.
    task = Task.create!(title: "No Agent Builder Probe", stage: "designed",
                        metadata: { "devops" => {} })

    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    assert_response :success
    assert_nil task.reload.metadata.dig("devops", "built_by")
  end

  test "a recorded builder survives a later partial devops write" do
    # NOTE: the actor here is a UUID on purpose. An earlier draft passed "sess"
    # and it was STAMPED AS THE BUILDER — ReviewerSelector#soul? is shape-only and
    # never consults AgentActivity::SOULS, so any lowercase word passes. That is a
    # real hazard (a typo'd `heartbeat stefon` would stamp stefon, LIFT the
    # fail-closed refusal, and exclude nobody) and it has its own task; it is not
    # this diff's to fix, but do not let a test paper over it.
    #
    # The API replaces devops WHOLESALE, so a `--checks` update that never
    # mentions built_by would otherwise erase who built the task — after review
    # had already been routed on it.
    task = Task.create!(title: "Builder Defend Probe Task", stage: "designed",
                        agent_slug: "shannon", metadata: { "devops" => {} })
    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { checks_run: ["[unit] something"] } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_equal "shannon", task.reload.metadata.dig("devops", "built_by")
  end

  # ── THE RESUME PATH (rule 1) ────────────────────────────────────────────────
  #
  # The tests above cover rule 4: agent_slug, which only a CREATE populates.
  # `bin/task begin <slug>` — the RESUME form — never creates, so agent_slug is
  # nil and rule 4 cannot fire. Measured 2026-08-29: four tasks resumed that way
  # reached review with built_by blank. begin now forwards `--agent <soul>` to its
  # child claim as `--actor`, which is rule 1, and rule 1 does not care whether
  # agent_slug was ever set. This is that path, through the API the CLI calls.
  test "a soul actor records the builder when no agent is assigned" do
    task = Task.create!(title: "Resumed Claim Builder Probe", stage: "designed",
                        metadata: { "devops" => {} })

    claim!(task, actor: "steffon")

    assert_response :success
    assert_equal "steffon", task.reload.metadata.dig("devops", "built_by"),
                 "a resumed task has no agent_slug, so the ACTOR is the only thing " \
                 "that can identify the builder — and reviewer-select refuses without one"
  end

  # THE CLAIM MUST BE A CLAIM. A resume of an ALREADY-building task renews the
  # lease rather than changing stage, and begin patches devops directly on that
  # branch instead of shelling out to `move`. Task#build_claim_save? treats a
  # rewritten lease as a claim precisely so the stamp still runs there — without
  # this, resuming your own in-flight task would silently leave built_by blank.
  test "renewing a claim on an already-building task still records the builder" do
    task = Task.create!(title: "Renewed Claim Builder Probe", stage: "building",
                        metadata: { "devops" => { "claimed_session" => "old-session" } })

    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { "claimed_session" => "new-session" }, event: { actor: "jasper" } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_equal "jasper", task.reload.metadata.dig("devops", "built_by"),
                 "a lease rewrite IS a build claim, so the stamp must run on it too"
  end

end
