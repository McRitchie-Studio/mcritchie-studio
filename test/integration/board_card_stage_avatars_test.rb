require "test_helper"

# Component tier (ui-only shape): render the real shared _board partial through
# BOTH board controllers and assert the per-stage crew avatars surface on the
# card — for a Build-lane task (/tasks) and a Deploy task (/deployments). The two
# pages render the same app/views/tasks/_board.html.erb, so a single partial
# change lands on both.
class BoardCardStageAvatarsTest < ActionDispatch::IntegrationTest
  setup do
    @shannon = Agent.create!(name: "Shannon", slug: "shannon")
    @carl    = Agent.create!(name: "Carl", slug: "carl")
    @steffon = Agent.create!(name: "Steffon", slug: "steffon")
    @avi     = Agent.create!(name: "Avi", slug: "avi")
  end

  test "tasks board card splits the build into its stage steps" do
    task = Task.create!(title: "build lane crewed card", stage: "building")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "shannon")

    get tasks_path
    assert_response :success

    # the Build board splits the build into its three steps (designed · building ·
    # submitted) with NO QA spots — a three-column row
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].grid-cols-3", count: 1

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster']", count: 2 # designed + building reached; submitted blank
      assert_select "span.text-white", count: 2            # the designer + the builder, each its own column
      assert_select "div[title^='Carl']"                   # designer's own column
      assert_select "div[title^='Shannon']"                # builder's own column
      assert_select "[data-test='crew-live']"              # ticking counter on the current (building) step
    end
  end

  test "tasks board blocked card shows designer builder and blocker slots" do
    Pokemon.create!(dex: 52, name: "Meowth", slug: "meowth", generation: 1,
                    sprite_url: "https://example.test/meowth-sprite.png")
    task = Task.create!(title: "blocked build crew card", stage: "blocked",
                        metadata: { "devops" => { "mascot" => "meowth" } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 3.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "blocked",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "avi")

    get tasks_path
    assert_response :success

    assert_select "#dropzone-building #card-#{task.slug}[data-stage='blocked']" do
      assert_select "[data-test='stage-agent-avatars'].grid-cols-3", count: 1
      assert_select "[data-test='crew-cluster']", count: 3
      assert_select "img[src='https://example.test/meowth-sprite.png']", count: 2
      assert_select "div[title^='Avi']", count: 1
      assert_select "[data-test='crew-blocked']", count: 1
      # three slots align left / center / right
      assert_select ".origin-left", count: 1
      assert_select ".origin-center", count: 1
      assert_select ".origin-right", count: 1
      # the stack spacing stays fixed; only the top avatar grows
      assert_select "[data-test='crew-stack'][class*='group-hover:scale-110']", count: 0
      assert_select "[data-test='crew-stack'][class*='group-hover:-space-x-']", count: 0
      assert_select "[data-test='crew-stack-avatar'][data-stack-position='top'][class*='group-hover:scale-125']", count: 3
      assert_select "[data-test='crew-stack-avatar'][data-stack-position='under'][class*='group-hover:scale-110']", count: 0
      assert_select "[data-test='crew-stack-avatar'][data-stack-position='under'][class*='group-hover:scale-125']", count: 0
    end
  end

  test "deployments board card shows reviewer + Steffon + Avi avatars" do
    task = Task.create!(title: "deploy crew shipped card", stage: "shipped")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "primary" },
                                                   { "slug" => "carl", "weight" => "light" }] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi")

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "span.text-white", count: 4 # 2 reviewers + Steffon + Avi
      assert_select "div[title^='Steffon']"
      assert_select "div[title^='Avi']"
    end
  end

  # Seed a full build → review → assembled journey (no ship yet) so the card's
  # build / review / assembled lanes are all filled and only the deploy slot is open.
  def assembled_journey(title)
    task = Task.create!(title: title, stage: "assembled")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 7.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 6.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 5.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "primary" },
                                                   { "slug" => "carl", "weight" => "light" }] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon")
    task.reload
  end

  test "an assembled card reserves an empty fourth (deploy) slot so it never reflows" do
    task = assembled_journey("assembled reserved deploy slot")

    get deployments_path
    assert_response :success

    # the lane row is already a fixed four-column grid before the task ships
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].grid-cols-4", count: 1

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster']", count: 3 # build · review · assembled filled
      assert_select "[data-test='crew-empty'][data-lane='shipped']", count: 1 # the reserved deploy slot
      assert_select "[data-test='crew-live']", count: 0 # nobody deploying yet
    end
  end

  test "an open ship intent fills the assembled card's deploy slot with Avi + a live ticker" do
    task = assembled_journey("assembled deploy intent card")
    # Avi starts the deploy while the task is still assembled (bin/task intent --to
    # shipped --actor avi) — his avatar + a live counter take the reserved 4th slot.
    task.record_intent_event(to_stage: "shipped", actor: "avi")

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].grid-cols-4", count: 1

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster']", count: 4              # build · review · assembled · shipped
      assert_select "[data-test='crew-empty']", count: 0               # the deploy slot is now filled
      assert_select "[data-test='crew-cluster'][data-lane='shipped'] div[title^='Avi']", count: 1
      assert_select "[data-test='crew-cluster'][data-lane='shipped'] [data-test='crew-live']", count: 1
    end
  end

  test "a resubmitted card shows the active review intent instead of the old review duration" do
    task = Task.create!(title: "resubmitted review card", stage: "submitted")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 5.hours.ago, seconds_in_from: 1800, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 4.hours.ago, seconds_in_from: 21.minutes,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "primary" },
                                                   { "slug" => "carl", "weight" => "light" }] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "blocked",
                      occurred_at: 3.hours.ago, seconds_in_from: 3600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "blocked", to_stage: "building",
                      occurred_at: 2.hours.ago, seconds_in_from: 3600)
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 30.minutes.ago, seconds_in_from: 5400, actor: "shannon")
    task.record_intent_event(to_stage: "reviewed", reviewers: [{ "slug" => "shannon", "weight" => "primary" },
                                                               { "slug" => "carl", "weight" => "light" }])

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster'][data-lane='review'] [data-test='crew-live']", count: 1
      assert_select "[data-test='crew-cluster'][data-lane='review'] [data-test='crew-duration']", count: 0
    end
  end

  test "a direct-blocked resubmitted card ignores the stale review intent" do
    task = Task.create!(title: "direct blocked review card", stage: "submitted")
    task.record_intent_event(to_stage: "reviewed", reviewers: [{ "slug" => "shannon", "weight" => "primary" },
                                                               { "slug" => "carl", "weight" => "light" }])
    task.block!
    task.build!
    task.submit!

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug}", count: 1
    assert_select "#card-#{task.slug} [data-test='crew-cluster'][data-lane='review'] [data-test='crew-live']", count: 0
    assert_select "#card-#{task.slug} [data-test='crew-cluster'][data-lane='review'] [data-test='crew-duration']", count: 0
  end

  test "the deploy crew is additive — an existing mascot survives render + ship intent" do
    # The 4th slot may only ADD the deploy face; the task's existing mascot (the
    # build-lane face) must never be re-derived, replaced, or reassigned.
    Pokemon.create!(dex: 70, name: "Weepinbell", slug: "weepinbell", generation: 1,
                    sprite_url: "https://example.test/weepinbell-sprite.png")
    task = assembled_journey("mascot preserved deploy card")
    task.update!(metadata: { "devops" => { "mascot" => "weepinbell", "mascot_session" => "sess-x" } })
    before = task.reload.devops["mascot"]

    # Recording the ship intent must not touch the mascot.
    task.record_intent_event(to_stage: "shipped", actor: "avi")
    assert_equal before, task.reload.devops["mascot"], "ship intent leaves the mascot untouched"

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      # build-lane face is STILL the mascot, and the deploy slot ADDS Avi (not the mascot)
      assert_select "img[src='https://example.test/weepinbell-sprite.png']"
      assert_select "[data-test='crew-cluster'][data-lane='shipped'] div[title^='Avi']", count: 1
    end

    # Rendering the deploy crew did not mutate the mascot either.
    assert_equal before, task.reload.devops["mascot"], "rendering the deploy crew leaves the mascot untouched"
  end

  test "the full crew collapses to four lane compartments (build / review / assembled / shipped)" do
    # A full journey: designer, builder, submitter (build), 2 reviewers, Steffon,
    # Avi = 7 faces — all shown, in four lane compartments.
    task = Task.create!(title: "crowded crew shipped card", stage: "shipped")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 7.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 6.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 5.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "primary" },
                                                   { "slug" => "carl", "weight" => "light" }] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi")

    get deployments_path
    assert_response :success

    # the lane row is a fixed four-column grid (25% each) so the full crew is one
    # solid row in the narrow kanban column, never wrapping
    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars'].grid-cols-4", count: 1

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "[data-test='crew-cluster']", count: 4  # build · review · assembled · shipped
      assert_select "span.text-white", count: 7             # all 7 faces, just stacked
      assert_select "[data-test='crew-duration']", count: 4 # one duration per compartment
    end
  end

  test "crew lanes keep hover growth bounded inside their compartments" do
    # Same full four-lane shipped journey: build · review · assembled · shipped.
    # On card hover each lane's stack gets only a small transform lift, anchored
    # inside its column. It must not translate into the card margins.
    task = Task.create!(title: "origin crew shipped card", stage: "shipped")
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 7.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 6.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 5.hours.ago, seconds_in_from: 3600, actor: "shannon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600,
                      metadata: { "reviewers" => [{ "slug" => "shannon", "weight" => "primary" },
                                                   { "slug" => "carl", "weight" => "light" }] })
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon")
    TaskEvent.create!(task_slug: task.slug, from_stage: "assembled", to_stage: "shipped",
                      occurred_at: 1.hour.ago, seconds_in_from: 600, actor: "avi")

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      # four filled lanes → leftmost anchors left, the two middles center, the last anchors right
      assert_select ".origin-left",   count: 1
      assert_select ".origin-center", count: 2
      assert_select ".origin-right",  count: 1
      # every lane keeps fixed stack spacing; only the top avatar grows
      assert_select "[data-test='crew-stack'][class*='group-hover:scale-110']", count: 0
      assert_select "[data-test='crew-stack'][class*='group-hover:-space-x-']", count: 0
      assert_select "[data-test='crew-stack-avatar'][data-stack-position='top'][class*='group-hover:scale-125']", count: 4
      assert_select "[data-test='crew-stack-avatar'][data-stack-position='top'][class*='group-focus-within:scale-125']", count: 4
      assert_select "[data-test='crew-stack-avatar'][data-stack-position='under'][class*='group-hover:scale-110']", count: 0
      assert_select "[data-test='crew-stack-avatar'][data-stack-position='under'][class*='group-hover:scale-125']", count: 0
      assert_select "[class*='group-hover:-translate-x-3']", count: 0
      assert_select "[class*='group-hover:translate-x-3']",  count: 0
    end
  end

  test "build-lane card crew wears the task mascot instead of the actor initial" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", generation: 1,
                    sprite_url: "https://example.test/snorlax-sprite.png")
    task = Task.create!(title: "mascot crew board card", stage: "building",
                        metadata: { "devops" => { "mascot" => "snorlax" } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed",
                      occurred_at: 2.hours.ago, actor: "claude-session")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "claude-session")

    get tasks_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "img[src='https://example.test/snorlax-sprite.png']" # the mascot face, not "C"
      assert_select "div[title^='Snorlax']"
    end
  end

  # --- the self-claim fix: a freshly-filed `designed` task is NOT live ----------
  # `bin/task create` still stamps the task a mascot (its identity), and a conductor
  # bin/release follow-up files it `designed`/unowned. The card must show that mascot
  # face WITHOUT the green live build ticker — filing a task is not building it.
  test "a freshly filed designed task shows its mascot but no live build ticker on the deploy board" do
    Pokemon.create!(dex: 50, name: "Diglett", slug: "diglett", generation: 1,
                    sprite_url: "https://example.test/diglett-sprite.png")
    task = Task.create!(title: "conductor follow up task", stage: "designed",
                        metadata: { "devops" => { "mascot" => "diglett" } })

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "img[src='https://example.test/diglett-sprite.png']" # identity preserved
      assert_select "[data-test='crew-live']", count: 0                  # but NO false live build intent
    end
  end

  # The counterpart the reviewer demanded: a REAL claim (move → building) still ticks
  # the live build counter — the fix must not flatten a legitimately-owned build.
  test "a building-claimed task still ticks a live build counter on the deploy board" do
    Pokemon.create!(dex: 51, name: "Dugtrio", slug: "dugtrio", generation: 1,
                    sprite_url: "https://example.test/dugtrio-sprite.png")
    task = Task.create!(title: "claimed build task", stage: "building",
                        metadata: { "devops" => { "mascot" => "dugtrio" } })
    task.task_events.delete_all
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 2.hours.ago, actor: "carl")
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 1.hour.ago, seconds_in_from: 3600, actor: "carl")

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      assert_select "img[src='https://example.test/dugtrio-sprite.png']"
      assert_select "[data-test='crew-live']", count: 1 # the active claim DOES tick
    end
  end

  # A final evolution (Charmeleon → Charizard at the review gate) shows the evolved
  # form stacked onto the FIRST (build) crew — the mascot's lineage lives together
  # on the card it was born on — and NOT beside Steffon on the assembled cluster.
  test "a final-evolution card stacks the evolved form on the first build crew" do
    [[4, "charmander", ["charmeleon"]], [5, "charmeleon", ["charizard"]], [6, "charizard", []]].each do |dex, slug, evo|
      Pokemon.where(slug: slug).first_or_initialize
             .update!(dex: dex, name: slug.capitalize, slug: slug, generation: 1, base: "charmander", evolution: evo, baby: [])
    end
    task = Task.create!(title: "final evolution board card", stage: "assembled")
    task.task_events.delete_all
    snap = ->(slug, name) { { "mascot" => { "slug" => slug, "name" => name, "avatar" => "https://example.test/#{slug}.png" } } }
    TaskEvent.create!(task_slug: task.slug, to_stage: "designed", occurred_at: 7.hours.ago, actor: "carl", metadata: snap["charmander", "Charmander"])
    TaskEvent.create!(task_slug: task.slug, from_stage: "designed", to_stage: "building",
                      occurred_at: 6.hours.ago, seconds_in_from: 3600, actor: "carl", metadata: snap["charmander", "Charmander"])
    TaskEvent.create!(task_slug: task.slug, from_stage: "building", to_stage: "submitted",
                      occurred_at: 5.hours.ago, seconds_in_from: 3600, actor: "carl", metadata: snap["charmeleon", "Charmeleon"])
    TaskEvent.create!(task_slug: task.slug, from_stage: "submitted", to_stage: "reviewed",
                      occurred_at: 4.hours.ago, seconds_in_from: 3600,
                      metadata: snap["charizard", "Charizard"].merge("reviewers" => [{ "slug" => "shannon", "weight" => "primary" },
                                                                                     { "slug" => "carl", "weight" => "light" }]))
    TaskEvent.create!(task_slug: task.slug, from_stage: "reviewed", to_stage: "assembled",
                      occurred_at: 2.hours.ago, seconds_in_from: 1800, actor: "steffon", metadata: snap["charizard", "Charizard"])

    get deployments_path
    assert_response :success

    assert_select "#card-#{task.slug} [data-test='stage-agent-avatars']" do
      # the evolved final form joins the FIRST (build) crew cluster
      assert_select "[data-test='crew-cluster'][data-lane='build'] img[src='https://example.test/charizard.png']", count: 1
      # …and is NOT duplicated beside Steffon on the assembled cluster
      assert_select "[data-test='crew-cluster'][data-lane='assembled'] img[src='https://example.test/charizard.png']", count: 0
      assert_select "[data-test='crew-cluster'][data-lane='assembled'] div[title^='Steffon']", count: 1
    end
  end

  test "a blocked card keeps a build crew face and blocked marker" do
    Pokemon.create!(dex: 52, name: "Meowth", slug: "meowth", generation: 1,
                    sprite_url: "https://example.test/meowth-sprite.png")
    task = Task.create!(title: "blocked crew marker", stage: "blocked",
                        metadata: { "devops" => { "mascot" => "meowth" } })

    get deployments_path
    assert_response :success

    assert_select "#dropzone-building #card-#{task.slug}[data-stage='blocked']" do
      assert_select "[data-test='stage-agent-avatars'].grid-cols-3", count: 1
      assert_select "img[src='https://example.test/meowth-sprite.png']"
      assert_select "[data-test='crew-blocked']", count: 1
    end
  end
end
