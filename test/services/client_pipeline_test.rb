require "test_helper"

# [unit] ClientPipeline (docs/agents/system/client-pipeline.md): one app's tasks by
# lane, and the sanitizer that keeps every agent internal off an owner's cards.
class ClientPipelineTest < ActiveSupport::TestCase
  setup do
    @turf = apps(:turf_monster)
    @turf.update!(package_tier: "pro")
    Task.where.not(stage: "archived").update_all(stage: "archived") # only this file's tasks on the lanes
  end

  def task!(title, stage:, repos: [ "turf-monster" ], devops: {}, **attrs)
    Task.create!(title: title, stage: stage, metadata: { "devops" => { "repositories" => repos }.merge(devops) }, **attrs)
  end

  def cards(pipeline) = pipeline.lanes.flat_map(&:cards)

  test "[unit] tasks group into the six lanes; other apps and old shipped work stay out" do
    task!("Queued one", stage: "designed")
    task!("Building one", stage: "building", started_at: 1.hour.ago)
    task!("In review one", stage: "submitted")
    task!("Ready one", stage: "reviewed")
    task!("On QA one", stage: "assembled")
    task!("Shipped recently", stage: "shipped").update_columns(completed_at: 3.days.ago)
    task!("Shipped long ago", stage: "shipped").update_columns(completed_at: 20.days.ago) # the create stamps now
    task!("Hub only", stage: "building", repos: [ "mcritchie-studio" ])
    task!("Turf and engine", stage: "designed", repos: [ "studio-engine", "turf-monster" ])

    pipeline = ClientPipeline.build(@turf)
    lanes = pipeline.lanes.to_h { |lane| [ lane.label, lane.cards.map(&:title) ] }

    assert_equal [ "Queued", "Building", "In review", "Ready for QA", "On QA", "Shipped" ], lanes.keys
    assert_equal [ "Turf and engine", "Queued one" ], lanes["Queued"], "board order: the newest rank first"
    assert_equal [ "Building one" ], lanes["Building"]
    assert_equal [ "Shipped recently" ], lanes["Shipped"]
    assert_equal [ 1, 2 ], pipeline.lanes.first.cards.map(&:queue_position)
    assert_equal "1 of 3 lanes in use", pipeline.lanes_status.label
    refute_includes cards(pipeline).map(&:title), "Hub only"
  end

  test "[unit] the sanitizer: an owner's card carries only the allow-listed fields, nothing internal" do
    task = task!("Wire the scores feed", stage: "building", started_at: 2.hours.ago, agent_slug: nil,
                 session_id: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b", pr_url: "https://github.com/McRitchie-Studio/turf-monster/pull/9",
                 devops: { "built_by" => "carl", "pr_url" => "https://github.com/McRitchie-Studio/turf-monster/pull/9",
                           "agent_context" => "desk /Users/alex/projects/turf-monster/.worktrees/x", "local_url" => "http://localhost:3104/" })
    task.update_columns(blocked_at: 1.minute.ago)

    card = cards(ClientPipeline.build(@turf, admin: false)).first
    shown = card.to_h.compact.reject { |_key, value| value == false }

    assert_equal %i[entered_at lane on_hold role title], shown.keys.sort
    assert_equal "Builder", card.role
    assert card.on_hold
    assert_nil card.slug
    assert_nil card.pr_url
    dump = card.to_h.values.map(&:to_s).join(" ")
    [ "carl", "pull/9", "019f3b0c", "localhost", ".worktrees", task.slug ].each { |internal| refute_includes dump, internal }
    assert_equal ClientPipeline::OWNER_FIELDS.sort, (ClientPipeline::Card.members - %i[slug pr_url]).sort,
                 "a new card field must be added to the owner allow-list on purpose"

    admin = cards(ClientPipeline.build(@turf, admin: true)).first
    assert_equal task.slug, admin.slug
    assert_equal "https://github.com/McRitchie-Studio/turf-monster/pull/9", admin.pr_url
  end

  test "[unit] the title scrubber drops URLs, paths, credentials, souls and other apps" do
    App.create!(slug: "cyvasse", name: "Cyvasse", position: 5)
    scrub = ClientPipeline::Scrubber.new(@turf)

    assert_equal "Fix the [link] preview", scrub.title("Fix the http://localhost:3104/contests preview")
    assert_equal "Clean [link] leftovers", scrub.title("Clean /Users/alex/projects/turf-monster/.worktrees/x leftovers")
    assert_equal "Clean [link] leftovers", scrub.title("Clean .worktrees/foo leftovers")
    assert_equal "Security maintenance", scrub.title("Rotate HEALTH_TOKEN_TURF_MONSTER")
    assert_equal "Security maintenance", scrub.title("Move the Stripe API key to 1Password")
    assert_equal "Security maintenance", scrub.title("Refile credentials for payouts")
    assert_equal "the team reviews the scoring change", scrub.title("Carl reviews the scoring change")
    assert_equal "Share a modal with a shared component", scrub.title("Share a modal with Cyvasse")
    assert_equal "Turf Monster live board", scrub.title("Turf Monster live board"), "the app's own name stays"
    assert_equal "Carlton picks", scrub.title("Carlton picks"), "a name inside a longer word stays"
  end

  test "[unit] an admin's titles are as written" do
    task!("Carl fixes http://localhost:3104", stage: "designed")
    assert_equal "Carl fixes http://localhost:3104", cards(ClientPipeline.build(@turf, admin: true)).first.title
    assert_equal "the team fixes [link]", cards(ClientPipeline.build(@turf)).first.title
  end
end
