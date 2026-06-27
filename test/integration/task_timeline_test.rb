require "test_helper"

class TaskTimelineTest < ActionDispatch::IntegrationTest
  # [component] the timeline section renders on the public task show page,
  # with a badge per transition.
  test "task show page renders the stage timeline with event badges" do
    task = Task.create!(title: "Timeline render task", stage: "designed")
    task.update!(stage: "building")

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='stage-timeline']"
    assert_match "Stage Timeline", response.body
    # genesis (Created → Designed) and the designed → building transition both show
    assert_match "Created", response.body
    assert_match "Designed", response.body
    assert_match "Building", response.body
  end

  # [integration] an API stage move carrying a usage payload records a fully
  # annotated TaskEvent end-to-end, and the model surfaces on the timeline.
  test "api stage move with usage records a TaskEvent and shows it on the timeline" do
    task = Task.create!(title: "Timeline api task", stage: "designed")
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

    assert_difference -> { task.task_events.count }, 1 do
      patch "/api/v1/tasks/#{task.slug}",
            params: { stage: "building",
                      event: { model: "claude-opus-4-8", tokens_in: 1000, tokens_out: 2000, cost: "0.30" } },
            headers: { "Authorization" => "Bearer #{token}" },
            as: :json
    end
    assert_response :success

    event = task.task_events.chronological.last
    assert_equal "building", event.to_stage
    assert_equal "claude-opus-4-8", event.model
    assert_equal 3000, event.tokens_total
    assert_equal "0.30".to_d, event.cost
    assert_equal "api", event.source

    get task_path(task.slug)
    assert_response :success
    assert_match "claude-opus-4-8", response.body
  end

  # [integration] a task reworked by a new session keeps the original build
  # mascot on the completed historical cards and shows the new mascot only for
  # the rework/current build cards.
  test "task show keeps historical build mascots after rework handoff" do
    Pokemon.create!(dex: 87, name: "Dewgong", slug: "dewgong", generation: 1)
    Pokemon.create!(dex: 88, name: "Grimer", slug: "grimer", generation: 1)
    SessionMascot.create!(session_id: "sess-design", mascot_slug: "dewgong")
    SessionMascot.create!(session_id: "sess-rework", mascot_slug: "grimer")

    task = Task.create!(title: "Timeline mascot history task",
                        metadata: { "devops" => { "session_id" => "sess-design" } })
    task.build!
    task.submit!
    task.block!
    task.update!(stage: "building",
                 metadata: task.metadata.deep_merge("devops" => { "session_id" => "sess-rework" }))

    get task_path(task.slug)

    assert_response :success
    assert_select "[data-test='timeline-crew-member'][title^='Dewgong']", minimum: 3
    assert_select "[data-test='timeline-crew-member'][title^='Grimer']", minimum: 2
  end

  # [integration] recording a review INTENT via the API appends a kind=intent
  # event and surfaces the pair as a live in-progress block on the show page.
  test "api intent records a review intent and the show page shows the live pair" do
    Agent.create!(name: "Carl", slug: "carl")
    Agent.create!(name: "Shannon", slug: "shannon")
    task = Task.create!(title: "Timeline intent task", stage: "submitted")
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

    assert_difference -> { task.task_events.intents.count }, 1 do
      post "/api/v1/tasks/#{task.slug}/intent",
           params: { to_stage: "reviewed",
                     reviewers: [{ slug: "carl", weight: "heavy" }, { slug: "shannon", weight: "light" }],
                     event: { source: "cli" } },
           headers: { "Authorization" => "Bearer #{token}" }, as: :json
    end
    assert_response :success

    intent = task.task_events.intents.last
    assert_equal "reviewed", intent.to_stage
    assert_equal "cli", intent.source
    assert_equal %w[carl shannon], intent.metadata["reviewers"].map { |r| r["slug"] }

    get task_path(task.slug)
    assert_response :success
    assert_select "[data-test='timeline-inprogress']", count: 0 # pill removed
    assert_select "[data-test='timeline-pulse']"                # pulsing backdrop signals live work
    assert_select "[data-test='timeline-live']"                 # ticking duration
    assert_match "Carl", response.body
    assert_match "Shannon", response.body
  end

  # [integration] the intent endpoint is append-only + a no-op once the target
  # stage has already landed (a retry never stacks duplicate rows).
  test "api intent is a no-op once the target stage has already landed" do
    task = Task.create!(title: "Timeline intent noop task", stage: "reviewed")
    task.update!(stage: "assembled")
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

    assert_no_difference -> { task.task_events.intents.count } do
      post "/api/v1/tasks/#{task.slug}/intent",
           params: { to_stage: "assembled", actor: "steffon", event: { source: "cli" } },
           headers: { "Authorization" => "Bearer #{token}" }, as: :json
    end
    assert_response :success
  end

  # [integration] a bad request (no to_stage) is a clean 400, never a 500.
  test "api intent without to_stage is a 400" do
    task = Task.create!(title: "Timeline intent bad task", stage: "submitted")
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth)

    post "/api/v1/tasks/#{task.slug}/intent",
         params: { actor: "steffon" }, headers: { "Authorization" => "Bearer #{token}" }, as: :json

    assert_response :bad_request
  end
end
