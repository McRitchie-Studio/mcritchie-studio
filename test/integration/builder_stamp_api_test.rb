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
    # NOTE: the actor here is a UUID on purpose. An earlier draft passed "sess" and
    # it was STAMPED AS THE BUILDER, because #soul? was shape-only: any lowercase
    # word passed. FIXED by /tasks/reviewer-select-seats-authors — every authorship
    # guard now checks Task.soul_roster, so a typo'd `stefon` names nobody, leaves
    # the authors UNKNOWN, and refuses. See the roster cases at the bottom of this
    # file and in test/models/task_builder_roll_call_test.rb.
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


  # --- THE AUTHOR SET, through the same route (reviewer-select-seats-authors) ---
  # `built_by` holds ONE soul but a task can have SEVERAL: a session limit kills a
  # builder mid-work and another soul finishes it. Rule 1 RE-POINTS built_by on the
  # second claim, so the first author vanished from the only field the reviewer pool
  # consulted — and on 2026-08-30 `bin/reviewer-select` seated ALEX as the light on a
  # diff Alex had written every test on (PR #1081, built_by=steffon).

  # A handoff is a claim by a DIFFERENT session — the payload `bin/task move <slug>
  # building --actor <soul>` sends when a killed builder's desk is picked up in a new
  # terminal (bin/task#1919 merges ClaimLease.renewed into the devops write). The
  # LEASE is what makes a second claim a claim at all: the stage is already
  # `building`, so #build_claim_save? has only the rewritten lease to go on, and a
  # payload without it is correctly no claim.
  def handoff!(task, actor:, session:, nonce: "inst-B", at: Time.current)
    patch "/api/v1/tasks/#{task.slug}",
          params: { stage: "building", event: { actor: actor },
                    devops: ClaimLease.renewed(session: session, nonce: nonce, now: at) },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json
  end

  STEFFON_SESSION = "s1d0f2a3-4b5c-4d6e-8f90-a1b2c3d4e5f6"
  ALEX_SESSION    = "s2e1f3b4-5c6d-4e7f-9a01-b2c3d4e5f6a7"

  test "a task handed off between two souls records BOTH as authors" do
    task = Task.create!(title: "Handoff Author Probe", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })

    handoff!(task, actor: "steffon", session: STEFFON_SESSION, nonce: "inst-A")
    assert_response :success
    handoff!(task, actor: "alex", session: ALEX_SESSION, at: 1.minute.from_now)
    assert_response :success

    assert_equal "alex", task.reload.metadata.dig("devops", "built_by"),
                 "built_by still names the CURRENT builder"
    assert_equal %w[steffon alex], task.reload.metadata.dig("devops", "builders"),
                 "and the server-owned set remembers the author it replaced"
  end

  test "NEITHER author is seated when the reviewer pool selects on the handed-off task" do
    # The end of the live failure, driven through the real HTTP route: the pool sees
    # the task exactly as the board stored it.
    task = Task.create!(title: "Handoff Selection Probe", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    handoff!(task, actor: "steffon", session: STEFFON_SESSION, nonce: "inst-A")
    handoff!(task, actor: "alex", session: ALEX_SESSION, at: 1.minute.from_now)

    decision = ReviewerSelector.explain(task.reload)

    assert_equal true, decision["builder_known"], "both claims named a soul"
    # Order is the drop order (worst-fit first), not the claim order — the set is
    # what matters here.
    assert_equal %w[alex steffon], decision["excluded_builders"].sort
    seated = decision["reviewers"].map { |r| r["slug"] }
    refute_includes seated, "alex", "the co-author must not review their own diff"
    refute_includes seated, "steffon"
  end

  test "a client cannot forge or shrink the author set over the API" do
    # `builders` is deliberately absent from Task::DEVOPS_KEYS, so
    # normalize_devops_metadata drops it and the before_save rebuilds the real one.
    # Otherwise the record could be laundered between the handoff and the review.
    task = Task.create!(title: "Author Set Forgery Probe", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })
    handoff!(task, actor: "steffon", session: STEFFON_SESSION, nonce: "inst-A")
    handoff!(task, actor: "alex", session: ALEX_SESSION, at: 1.minute.from_now)

    patch "/api/v1/tasks/#{task.slug}",
          params: { devops: { builders: ["shannon"], builders_unattributed: "" } },
          headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :success
    assert_equal %w[steffon alex], task.reload.metadata.dig("devops", "builders"),
                 "the author set is server-owned — a client write is dropped, not honored"
  end

  test "a typo'd actor over the API stamps nobody and leaves the authors unknown" do
    # The second mechanism, end to end: `--actor stefon` matched the SOUL_SLUG shape,
    # so it was stamped, read as KNOWN, and excluded nobody. The refusal that keeps a
    # soul off their own PR was lifted by a value identifying no one.
    task = Task.create!(title: "Typo Actor Api Probe", stage: "designed",
                        metadata: { "devops" => { "shape" => "backend" } })

    claim!(task, actor: "stefon")

    assert_response :success
    assert_nil task.reload.metadata.dig("devops", "built_by"), "no phantom on the record"
    assert_equal false, ReviewerSelector.explain(task.reload)["builder_known"],
                 "an unrecognised soul must do no better than silence"
  end
end
