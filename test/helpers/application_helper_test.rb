require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "right_fade_style emits both mask-image properties with the given stop" do
    style = right_fade_style
    assert_includes style, "mask-image: linear-gradient(to right, #000 88%, transparent)"
    assert_includes style, "-webkit-mask-image: linear-gradient(to right, #000 88%, transparent)"

    assert_includes right_fade_style(stop: 70), "#000 70%, transparent", "stop is configurable"
  end

  test "environment banner shows in non-production rails environments" do
    assert show_environment_banner?(
      qa_environment: false,
      rails_env: ActiveSupport::StringInquirer.new("development")
    )
  end

  test "environment banner shows in QA even when Rails runs in production mode" do
    assert show_environment_banner?(
      qa_environment: true,
      rails_env: ActiveSupport::StringInquirer.new("production")
    )
  end

  test "environment banner hides in production when not QA" do
    assert_not show_environment_banner?(
      qa_environment: false,
      rails_env: ActiveSupport::StringInquirer.new("production")
    )
  end

  test "environment banner message calls out QA as non-production" do
    assert_equal "QA Environment · Non-production",
                 environment_banner_message(
                   qa_environment: true,
                   rails_env: ActiveSupport::StringInquirer.new("production")
                 )
  end

  test "devops_stage_guide covers both workflows with the right stages" do
    guide = devops_stage_guide

    assert_equal %w[Build Deploy], guide.keys
    # Build guide tracks the /tasks board columns; the Deploy guide tracks the deploy
    # WORKFLOW (DEPLOY_STAGES, four stages). The /deployments board now carries extra
    # upstream designed/building lanes, but the workflow guide stays the four stages.
    assert_equal Task::TASKS_BOARD_STAGES, guide["Build"].map { |row| row[:stage] }
    assert_equal Task::DEPLOY_STAGES, guide["Deploy"].map { |row| row[:stage] }
    assert_includes guide["Build"].map { |r| r[:stage] }, "submitted"
    assert_includes guide["Deploy"].map { |r| r[:stage] }, "submitted"

    # every row carries the swimlane fields
    guide.values.flatten.each do |row|
      assert row[:what].present?, "#{row[:stage]} missing :what"
      assert row[:who].present?, "#{row[:stage]} missing :who"
      assert row[:nxt].present?, "#{row[:stage]} missing :nxt"
    end

    # kickoff chips: none on the feature-agent (Build) lane; one per DevOps stage
    guide["Build"].each { |row| assert_nil row[:kick], "#{row[:stage]} should have no kickoff chip" }
    guide["Deploy"].each do |row|
      assert row[:kick].present?, "#{row[:stage]} missing :kick"
      assert_operator row[:kick].split.size, :<=, 3, "#{row[:stage]} kickoff command should be 2-3 words"
      assert_equal devops_kickoffs[row[:stage]], row[:kick], "#{row[:stage]} kick should come from devops_kickoffs"
    end
  end

  test "devops_kickoffs is exactly the per-stage DevOps board kickoffs" do
    # The four legacy release-wide meta-trigger chips were retired; devops_kickoffs
    # now carries ONLY the per-stage board kickoffs (the soul heartbeat launchers
    # replaced the chips — see heartbeat_launchers below).
    assert_equal Task::DEPLOY_STAGES.sort, devops_kickoffs.keys.sort
    # per-stage kickoffs stay terse enough for a column header (≤3 words)
    devops_kickoffs.each_value { |v| assert_operator v.split.size, :<=, 3 }
  end

  test "shipped kickoff is the Archive completed tasks workflow (DevOps loop conclusion)" do
    assert_equal "Archive completed tasks", devops_kickoffs["shipped"]
  end

  test "app_emoji maps each canonical app slug to its glyph" do
    assert_equal "🪎", app_emoji("mcritchie-studio")
    assert_equal "🐊", app_emoji("turf-monster")
    assert_equal "💎", app_emoji("studio-engine")
    assert_equal "🏛️", app_emoji("turf-vault")
    assert_equal "🧱", app_emoji("solana-studio")
    assert_equal "⛓️", app_emoji("chain-ops")
    assert_equal "📇", app_emoji("rolio")
  end

  test "app_emoji is blank-safe and case/whitespace tolerant, nil for unknown" do
    assert_equal "🪎", app_emoji("  MCRITCHIE-STUDIO  ")
    assert_nil app_emoji("nope")
    assert_nil app_emoji("")
    assert_nil app_emoji(nil)
  end

  test "app_emojis drops unknowns, collapses shared-glyph aliases, preserves order" do
    assert_equal ["🐊", "💎"], app_emojis(["turf-monster", "studio-engine"])
    # turf-vault and its 'vault' alias share one glyph → one entry
    assert_equal ["🏛️"], app_emojis(["turf-vault", "vault"])
    # unmapped repos are dropped, not rendered blank
    assert_equal ["🪎"], app_emojis(["mcritchie-studio", "ghost-app"])
    assert_equal [], app_emojis(nil)
  end

  test "app_emoji_badge returns nil when nothing maps, else a titled span" do
    assert_nil app_emoji_badge(["ghost-app"])
    assert_nil app_emoji_badge([])

    badge = app_emoji_badge(["mcritchie-studio", "studio-engine"])
    assert_includes badge, "🪎"
    assert_includes badge, "💎"
    assert_includes badge, %(title="mcritchie-studio, studio-engine")
    assert badge.html_safe?
  end

  test "release rainbow glow style centralizes the shared release glow recipe" do
    style = release_rainbow_glow_style

    assert_includes style, "--task-card-glow-color: #a78bfa"
    assert_includes style, "--task-card-glow-color-a: #fb0094"
    assert_includes style, "--task-card-glow-color-b: #00c4ff"
    assert_includes style, "--task-card-glow-border-color: color-mix(in srgb, var(--task-card-glow-color) 58%, transparent)"
    assert_includes style, "0 0 118px color-mix(in srgb, var(--task-card-glow-color) 12%, transparent)"
    assert_includes style, "border-color: var(--task-card-glow-border-color)"
    assert_includes style, "box-shadow: var(--task-card-glow-shadow)"
    assert_not_includes style, "--lbfx-fresh-delay"
  end

  test "release fresh glow style adds deterministic motion and freshness phase" do
    rel = Release.new(slug: "rel-test-glow")
    style = release_fresh_glow_style(rel, elapsed_ms: 2_500)

    assert_includes style, "--studio-border-glow-offset:"
    assert_includes style, "--studio-border-glow-duration:"
    assert_includes style, "--studio-border-glow-angle:"
    assert_includes style, "--lbfx-fresh-delay: -2500ms"
    assert_includes style, "--task-card-glow-color-a: #fb0094"
    assert_includes style, "--task-card-glow-color-b: #00c4ff"
  end

  # Component-tier: render the board card's slug-row markup (mirrors
  # tasks/_board.html.erb) for a rolio-tagged task and assert the 📇 app badge
  # rides the slug. Guards the reported bug — rolio cards rendering glyph-less.
  test "board slug-row renders the 📇 app badge alongside a rolio task slug" do
    rendered = render(
      inline: <<~ERB,
        <div class="relative mt-0.5 mb-1.5">
          <code class="block text-[10px] font-mono text-muted truncate"><%= slug %></code>
          <%= app_emoji_badge(repositories, css: "absolute inset-y-0 right-0 z-10 flex items-center") %>
        </div>
      ERB
      locals: { slug: "rolio-public-api", repositories: ["rolio"] }
    )

    assert_includes rendered, "rolio-public-api", "the card should still show the slug"
    assert_includes rendered, "📇", "rolio's affected-app glyph should render on the card"
    assert_includes rendered, %(title="rolio"), "the badge is titled with the affected repo"
  end

  # Component-tier: render the shared _release_summary partial for an active
  # release carrying a conductor mascot and assert the mascot avatar (sprite +
  # name) and the in-progress timing line both ride the card. No members → the
  # task-pill loop is skipped, keeping this a focused render of MY additions.
  test "[component] _release_summary renders the conductor mascot avatar + timing line" do
    Pokemon.create!(dex: 143, name: "Snorlax", slug: "snorlax", types: %w[normal], generation: 1,
                    sprite_url: "https://example.test/snorlax.png")
    rel = Release.open!
    rel.update!(metadata: { "devops" => { "mascot" => "snorlax", "mascot_session" => "s" } })

    render partial: "tasks/release_summary", locals: { release: rel, variant: :current }

    assert_select "[data-test='release-mascot'] img[src=?]", "https://example.test/snorlax.png"
    assert_select "[data-test='release-mascot']", text: /Snorlax/
    assert_select "[data-test='release-timing']", text: /\Ain progress · /
  end

  test "[component] _release_summary stacks Last Release member pills into one overlapping row" do
    Release.delete_all
    rel = Release.open!(branch: "release/member-stack")
    3.times do |index|
      task = Task.create!(
        title: "Stacked release member task #{index}",
        stage: "reviewed",
        metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }
      )
      rel.add(task)
    end

    render partial: "tasks/release_summary", locals: { release: rel.reload, variant: :last }

    assert_select "[data-test='release-member-stack'].flex-nowrap.overflow-hidden", count: 1
    assert_select "[data-test='release-member-stack'] [data-test='release-member-pill']", count: 3
    assert_select "[data-test='release-member-pill'] span.truncate", count: 3

    pills = css_select("[data-test='release-member-pill']")
    assert_not_includes pills.first["class"], "-ml-20"
    assert_not_includes pills.first["style"], "box-shadow"
    pills.drop(1).each do |pill|
      assert_includes pill["class"], "-ml-20"
      assert_includes pill["class"], "border-l"
    end
    assert_includes pills[1]["style"], "z-index: 2;"
    assert_includes pills[1]["style"], "box-shadow: -10px 0 14px -12px color-mix(in srgb, var(--color-text) 70%, transparent);"
    assert_includes pills[1]["style"], "border-left-color: color-mix(in srgb, var(--color-text) 28%, var(--color-border));"
    assert_includes pills[2]["style"], "z-index: 3;"
    assert_includes pills[2]["style"], "box-shadow: -10px 0 14px -12px color-mix(in srgb, var(--color-text) 70%, transparent);"
    assert_includes pills[2]["style"], "border-left-color: color-mix(in srgb, var(--color-text) 28%, var(--color-border));"
  end

  test "[component] _release_summary keeps Current Release member pills wrapping" do
    Release.delete_all
    rel = Release.open!(branch: "release/current-wrap")
    3.times do |index|
      task = Task.create!(
        title: "Current release member task #{index}",
        stage: "reviewed",
        metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }
      )
      rel.add(task)
    end

    render partial: "tasks/release_summary", locals: { release: rel.reload, variant: :current }

    assert_select "[data-test='release-member-list'].flex-wrap.gap-2", count: 1
    assert_select "[data-test='release-member-stack']", count: 0

    pills = css_select("[data-test='release-member-pill']")
    assert_equal 3, pills.size
    pills.each do |pill|
      assert_not_includes pill["class"], "-ml-20"
      assert_not_includes pill["class"], "border-l"
      assert_not_includes pill["style"], "box-shadow"
    end
  end

  test "[unit] release_tracker_steps walks the stage stamps, handoff gaps included" do
    rel = Release.open!
    # An untouched timeline: every node dark — no stage has claimed the work yet.
    assert_equal %i[pending pending pending pending pending],
                 release_tracker_steps(rel).map { |step| step[:state] }
    assert_equal [ "Testing", "Assembling", "Deploying QA", "Confirming", "Deploying" ],
                 release_tracker_steps(rel).map { |step| step[:label] }
    assert_equal %i[pending pending pending pending pending],
                 release_tracker_steps(rel).map { |step| step[:connector_state] }

    rel.stamp_stage!("testing")
    assert_equal %i[active pending pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }

    rel.stamp_stage!("assembling")
    assert_equal %i[complete active pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }
    assert_equal [ "Tested", "Assembling", "Deploying QA", "Confirming", "Deploying" ],
                 release_tracker_steps(rel.reload).map { |step| step[:label] }
    assert_equal %i[active pending pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:connector_state] }

    rel.stamp_stage!("assembled")
    assert_equal %i[complete complete pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] },
                 "assembled does not auto-start the QA deploy"

    rel.stamp_stage!("qa_deploying")
    assert_equal %i[complete complete active pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }
    assert_equal %i[complete active pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:connector_state] }

    rel.stamp_stage!("qa_deployed")
    assert_equal %i[complete complete complete pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] },
                 "Live on QA is Steffon's finish line — Confirming stays dark until Avi starts"
    assert_equal [ "Tested", "Assembled", "Live on QA", "Confirming", "Deploying" ],
                 release_tracker_steps(rel.reload).map { |step| step[:label] }
    assert_equal %i[complete complete pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:connector_state] },
                 "no connector pulses into the unclaimed handoff"

    rel.stamp_stage!("confirming")
    assert_equal %i[complete complete complete active pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] },
                 "Avi's confirming stamp lights stage four"
    assert_equal %i[complete complete active pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:connector_state] }

    rel.stamp_stage!("confirmed")
    assert_equal %i[complete complete complete complete pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }
    assert_equal [ "Tested", "Assembled", "Live on QA", "Confirmed", "Deploying" ],
                 release_tracker_steps(rel.reload).map { |step| step[:label] }

    rel.stamp_stage!("prod_deploying")
    assert_equal %i[complete complete complete complete active],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }

    rel.ship!
    assert_equal %i[complete complete complete complete complete],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }
    assert_equal [ "Tested", "Assembled", "Live on QA", "Confirmed", "Deployed" ],
                 release_tracker_steps(rel.reload).map { |step| step[:label] }
    assert_equal %i[complete complete complete complete complete],
                 release_tracker_steps(rel.reload).map { |step| step[:connector_state] }
  end

  test "[unit] release_tracker_steps winds back with reopen! (re-assembly + re-QA ahead)" do
    rel = Release.open!
    rel.stamp_stage!("assembling")
    rel.stamp_stage!("qa_deploying")
    rel.stamp_stage!("qa_deployed")
    rel.assemble!

    rel.reopen!
    assert_equal %i[complete active pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] },
                 "a reopened release re-assembles — downstream stamps cleared"
  end

  test "[unit] release_tracker_steps yields five DISTINCT active labels" do
    # On an untouched timeline every step renders its active_label, so this is
    # the full active-label set. The fix disambiguated the old repeats ("Testing"
    # twice, "Deploying" twice) into Deploying QA / Confirming / Deploying.
    labels = release_tracker_steps(Release.open!).map { |step| step[:label] }
    assert_equal [ "Testing", "Assembling", "Deploying QA", "Confirming", "Deploying" ], labels
    assert_equal labels.size, labels.uniq.size, "tracker active labels must be unambiguous"
  end

  test "[unit] release_ago_label uses hours and minutes once hourly" do
    assert_equal "0s ago", release_ago_label(0)
    assert_equal "59s ago", release_ago_label(59)
    assert_equal "1m ago", release_ago_label(60)
    assert_equal "59m ago", release_ago_label((60 * 60) - 1)
    assert_equal "1h 00m ago", release_ago_label(60 * 60)
    assert_equal "1h 04m ago", release_ago_label(60 * 60 + 4.minutes + 9.seconds)
    assert_equal "23h 59m ago", release_ago_label((24 * 60 * 60) - 1)
    assert_equal "24h 00m ago", release_ago_label(24 * 60 * 60)
    assert_equal "180h 24m ago", release_ago_label(180.hours + 24.minutes + 14.seconds)
  end

  test "[unit] a reached tracker node carries its started_at and ago seconds" do
    rel = Release.open!
    rel.stamp_stage!("testing")
    rel.stamp_stage!("assembling")

    tested = release_tracker_steps(rel.reload, now: 5.minutes.from_now).first
    assert_equal :complete, tested[:state]
    assert_equal rel.stage_stamp("testing"), tested[:started_at]
    assert_equal rel.stage_stamp("assembling"), tested[:completed_at]
    assert_in_delta 5.minutes.to_i, tested[:ago_seconds], 2,
                    "ago_seconds is the stage's START stamp → now"
    assert_equal false, tested[:duration_live]
    assert_not_nil tested[:duration_seconds], "own start → completion span survives for the took tooltip"

    # The active node now ALSO carries started-ago (its live clock IS this ago) —
    # with no completion fields yet.
    assembling = release_tracker_steps(rel.reload).second
    assert_equal :active, assembling[:state]
    assert assembling[:duration_live]
    assert_equal rel.stage_stamp("assembling"), assembling[:started_at]
    assert assembling[:ago_seconds] >= 0, "an active node ticks its own started-ago"
    assert_nil assembling[:completed_at]
    assert_nil assembling[:duration_seconds], "no completed span yet, so no took"
  end

  test "[component] _release_summary renders the current release tracker stages" do
    rel = Release.open!
    tasks(:queued_task).update!(stage: "assembled", release_slug: rel.slug)
    rel.update!(qa_url: "https://qa.mcritchie.studio")
    %w[testing assembling assembled qa_deploying qa_deployed confirming].each { |stage| rel.stamp_stage!(stage) }

    render partial: "tasks/release_summary", locals: { release: rel, variant: :current }

    assert_select "[data-test='release-tracker']"
    assert_select "[data-test='release-tracker-step']", 5
    [ "Tested", "Assembled", "Live on QA", "Confirming", "Deploying" ].each do |label|
      assert_select "[data-test='release-tracker-label']", text: label
    end
    assert_select "[data-test='release-tracker-label']", { text: /✅/, count: 0 }
    assert_select "[data-test='release-tracker-label']", { text: "Merging", count: 0 }
    # The confirming step no longer mislabels itself "Testing"; the prod-deploy
    # step reads a bare "Deploying" (distinct from step 3's "Deploying QA").
    assert_select "[data-test='release-tracker-label']", { text: "Testing", count: 0 }
    assert_select "[data-test='release-tracker-label']", { text: "Deploying", count: 1 }
    assert_select "[data-test='release-tracker-step'][data-state='complete']", 3
    assert_select "[data-test='release-tracker-step'][data-state='active'][data-stage='confirming']"
    assert_select "[data-test='release-tracker-step'][data-state='active'] [aria-current=?]", "step"
    assert_select "[data-test='release-tracker-step'][data-state='active'] [data-test='release-tracker-label'].text-amber-700.dark\\:text-amber-200"
    assert_select "[data-test='release-tracker-step'][data-stage='qa_deploying'] [data-test='release-tracker-connector'][data-state='active'].animate-pulse"
    assert_select "[data-test='release-tracker-step'][data-state='active'] [data-test='release-tracker-connector'][data-state='pending']"
  end

  test "[component] every reached tracker node shows started-ago, active included" do
    rel = Release.open!
    tasks(:queued_task).update!(stage: "assembled", release_slug: rel.slug)
    %w[testing assembling assembled qa_deploying].each { |stage| rel.stamp_stage!(stage) }

    render partial: "tasks/release_tracker", locals: { release: rel }

    # Complete nodes: an ago-mode ticker anchored on the stage's OWN START stamp,
    # with the absolute start time + the stage span demoted to the hover title.
    assert_select "[data-test='release-tracker-step'][data-state='complete']", 2
    %w[testing assembling].each do |key|
      assert_select "[data-test='release-tracker-step'][data-stage='#{key}'] " \
                    "[data-test='release-tracker-duration'][data-release-ticker][data-mode='ago']" \
                    "[data-since='#{rel.stage_stamp(key).to_i}']",
                    text: /\A\d+[smhd] ago\z/ do |spans|
        assert_match(/\AStarted .+ · took \d+[sm]\z/, spans.first["title"])
        assert_match(/\A\d+[sm]\z/, spans.first["data-took"],
                     "data-took feeds the browser-local title rewrite")
      end
    end

    # The ACTIVE node now shows started-ago too (its live clock IS this ago),
    # anchored on its start stamp — ago mode, but no took yet (stage unfinished).
    assert_select "[data-test='release-tracker-step'][data-stage='qa_deploying'] " \
                  "[data-test='release-tracker-duration'][data-release-ticker][data-mode='ago']" \
                  "[data-since='#{rel.stage_stamp("qa_deploying").to_i}']",
                  text: /\A\d+[smhd] ago\z/ do |spans|
      assert_nil spans.first["data-took"], "an in-flight stage has no span yet, so no took"
      assert_match(/\AStarted /, spans.first["title"])
    end
  end

  test "compact_stage_duration renders a tight one-token form, nil-safe" do
    assert_nil compact_stage_duration(nil)
    assert_equal "<1m", compact_stage_duration(30)
    assert_equal "12m", compact_stage_duration(12 * 60)
    assert_equal "3h", compact_stage_duration(3 * 3600)
    assert_equal "5d", compact_stage_duration(5 * 86_400)
  end

  test "devops_stage_guide Deploy steps carry tests-run + gate; Build steps do not" do
    guide = devops_stage_guide

    guide["Deploy"].each do |row|
      assert row[:tests].present?, "#{row[:stage]} Deploy step missing :tests"
      assert row[:gate].present?, "#{row[:stage]} Deploy step missing :gate"
    end
    guide["Build"].each do |row|
      assert_nil row[:tests], "#{row[:stage]} Build step should not carry :tests"
      assert_nil row[:gate], "#{row[:stage]} Build step should not carry :gate"
    end

    deploy = guide["Deploy"].index_by { |row| row[:stage] }
    # review is a NESTED chain: Avi thin-delegates → the PRIMARY owns the lane → the LIGHT, scoped to base-tier tests
    assert_match(/primary/i, deploy["submitted"][:who])
    assert_match(/light/i, deploy["submitted"][:who])
    assert_match(/base/i, deploy["submitted"][:tests])
    # Steffon owns the reviewed-stage merge sweep and QA release.
    assert_match(/steffon/i, deploy["reviewed"][:who])
    assert_match(/qa-release/i, deploy["reviewed"][:what])
    # Steffon owns QA; Avi runs the frozen-SHA suite; production authority is explicit
    assert_match(/steffon/i, deploy["assembled"][:who])
    assert_match(/frozen ship sha/i, deploy["shipped"][:tests])
    assert_match(/qa-release/i, deploy["shipped"][:gate])
    assert_match(/full-cycle/i, deploy["shipped"][:gate])
  end

  test "release_state_label folds a shipped release into 'Shipped <time> ago'" do
    rel = Release.new(state: "shipped", shipped_at: 7.minutes.ago)
    assert_match(/\AShipped .+ ago\z/, release_state_label(rel))
  end

  test "release_state_label shows 'Assembled <time> ago' for an assembled current release" do
    rel = Release.new(state: "assembled", assembled_at: 2.hours.ago)
    assert_match(/\AAssembled .+ ago\z/, release_state_label(rel, current: true))
  end

  test "release_state_label falls back to the capitalized state when no timestamp applies" do
    # in-progress release with no timestamp yet
    assert_equal "Assembling", release_state_label(Release.new(state: "assembling"), current: true)
    # a not-current (Last Release) card ignores assembled_at — only shipped_at promotes a time
    assert_equal "Assembled",
                 release_state_label(Release.new(state: "assembled", assembled_at: 1.hour.ago), current: false)
  end

  test "release_timing_label shows 'in progress · <dur>' for an active release" do
    rel = Release.new(state: "assembling", created_at: Time.utc(2026, 1, 1, 0, 0, 0))
    now = Time.utc(2026, 1, 1, 0, 23, 0)
    assert_equal "in progress · 23m", release_timing_label(rel, now: now)

    rel.created_at = Time.utc(2026, 1, 1, 0, 0, 0)
    assert_equal "in progress · 3h", release_timing_label(rel, now: Time.utc(2026, 1, 1, 3, 0, 0))
  end

  test "release_timing_label shows 'took <dur>' for a shipped release (begin→ship)" do
    rel = Release.new(state: "shipped",
                      created_at: Time.utc(2026, 1, 1, 0, 0, 0),
                      shipped_at: Time.utc(2026, 1, 1, 0, 18, 0))
    assert_equal "took 18m", release_timing_label(rel)
  end

  test "release_timing_label is nil when no timing applies" do
    assert_nil release_timing_label(Release.new(state: "shipped")), "shipped with no shipped_at → no duration"
    assert_nil release_timing_label(Release.new(state: "abandoned", created_at: Time.utc(2026, 1, 1))),
               "a terminal-but-unshipped release shows no timing"
  end

  test "elapsed_seconds is nil-safe and clamps clock skew to zero" do
    assert_nil elapsed_seconds(nil, Time.current)
    assert_nil elapsed_seconds(Time.current, nil)
    t = Time.utc(2026, 1, 1, 0, 0, 0)
    assert_equal 60, elapsed_seconds(t, t + 60)
    assert_equal 0, elapsed_seconds(t, t - 60), "a negative span clamps to 0, never a bogus past"
  end

  test "format_elapsed_clock renders seconds below hours and H/M after" do
    assert_equal "0s", format_elapsed_clock(0)
    assert_equal "45s", format_elapsed_clock(45)
    assert_equal "7m 23s", format_elapsed_clock(7 * 60 + 23)
    assert_equal "7m 03s", format_elapsed_clock(7 * 60 + 3), "trailing units zero-pad for a stable width"
    assert_equal "1h 04m", format_elapsed_clock(3600 + 4 * 60 + 9)
    assert_equal "180h 24m", format_elapsed_clock(180.hours + 24.minutes + 14.seconds)
  end

  test "release_elapsed_clock counts seconds from the release's created_at" do
    rel = Release.new(state: "assembling", created_at: Time.utc(2026, 1, 1, 0, 0, 0))
    assert_equal "0s", release_elapsed_clock(rel, now: Time.utc(2026, 1, 1, 0, 0, 0))
    assert_equal "7m 23s", release_elapsed_clock(rel, now: Time.utc(2026, 1, 1, 0, 7, 23))
    assert_equal "1h 04m", release_elapsed_clock(rel, now: Time.utc(2026, 1, 1, 1, 4, 9))
  end

  test "release_static_duration_label renders seconds or whole minutes" do
    assert_equal "14s", release_static_duration_label(14)
    assert_equal "3m", release_static_duration_label(3.minutes + 22.seconds)
  end

  test "release_tracker_steps carries started-ago timing for every reached node" do
    rel = Release.open!
    started = Time.zone.parse("2026-06-29 12:00:00")
    rel.record_event!(step: "assemble_release", status: "started", source: "conductor", occurred_at: started)
    rel.record_event!(step: "assemble_release", status: "completed", source: "conductor", occurred_at: started + 90.seconds)
    rel.record_event!(step: "deploy_qa", status: "started", source: "conductor", occurred_at: started + 2.minutes)
    rel.update_columns(assembled_at: started + 90.seconds, state: "assembling") # rubocop:disable Rails/SkipsModelValidations

    steps = release_tracker_steps(rel.reload, now: started + 3.minutes)
    assembling = steps.detect { |step| step[:key] == "assembling" }
    qa = steps.detect { |step| step[:key] == "qa_deploying" }

    # A COMPLETE node: "started X ago" off its own start stamp, plus a real "took".
    assert_equal :complete, assembling[:state]
    assert_equal started, assembling[:started_at]
    assert_equal 180, assembling[:ago_seconds], "started 3m before now"
    assert_equal 90, assembling[:duration_seconds], "own start → completed span survives for the took tooltip"
    assert_not assembling[:duration_live]

    # The ACTIVE node: "started X ago" too (its live clock is this ago, not mm:ss);
    # no span yet, so no took.
    assert_equal :active, qa[:state]
    assert_equal started + 2.minutes, qa[:started_at]
    assert_equal 60, qa[:ago_seconds]
    assert qa[:duration_live]
    assert_nil qa[:duration_seconds], "an in-flight stage has no completed span yet"
  end

  test "release_tracker_steps falls back to release-open for a node missing its start stamp" do
    created = Time.zone.parse("2026-06-29 12:00:00")
    completed = created + 4.minutes + 12.seconds
    rel = Release.open!(created_at: created)
    # assemble completed but its 'started' was never posted (a frequent late/missing stamp).
    rel.record_event!(step: "assemble_release", status: "completed", source: "conductor", occurred_at: completed)

    steps = release_tracker_steps(rel.reload, now: completed)
    assembling = steps.detect { |step| step[:key] == "assembling" }

    assert_equal :complete, assembling[:state]
    assert_equal created, assembling[:started_at], "no own start stamp → fall back to release open, never blank"
    assert_equal 252, assembling[:ago_seconds]
    assert_nil assembling[:duration_seconds], "took stays nil off a fallback anchor — never overstate the span"
  end

  test "[component] _current_release renders a glow hook + a live in-progress ticker" do
    rel = Release.open!
    rel.stamp_stage!("assembling") # an active stage carries the live per-node ticker
    render partial: "tasks/current_release", locals: { release: rel }

    assert_select "#current-release[data-glow]" # the live-flash tint hook rides the card
    assert_select "#current-release [data-release-ticker][data-since=?]", rel.created_at.to_i.to_s
    assert_select "#current-release [data-test='release-timing']", text: /\Ain progress · /
    assert_select "#current-release [data-test='release-tracker-duration'][data-release-ticker]", minimum: 1
  end

  test "[component] active release tracker hides seconds after one hour" do
    now = Time.zone.local(2026, 6, 29, 12, 0, 0)

    travel_to now do
      rel = Release.open!
      rel.stamp_stage!("assembling", at: now - 180.hours - 24.minutes - 14.seconds)

      render partial: "tasks/release_tracker", locals: { release: rel }

      assert_select "[data-test='release-tracker-step'][data-stage='assembling'] " \
                    "[data-test='release-tracker-duration'][data-release-ticker]",
                    text: /\A180h 24m(?: ago)?\z/ do |spans|
        assert_no_match(/\d+s\b/, spans.first.text)
      end
    end
  end

  test "devops_next_html badges whole-word stage names only" do
    html = devops_next_html("pulls it into the next release → assembled")
    assert_includes html, "<span"
    assert_includes html, "Assembled" # label, badged
    assert html.html_safe?

    # both branches of an or-transition get badged
    both = devops_next_html("→ reviewed, or sends it back blocked for rework")
    assert_equal 2, both.scan("<span").size

    # false positives: "build" in a flag and "blocked_from" must stay plain text
    plain = devops_next_html("passes dor-check --gate build; records blocked_from")
    assert_not_includes plain, "<span"
  end

  test "[unit] heartbeat_launchers maps the three souls to prompt + atom-act launchers" do
    launchers = heartbeat_launchers

    assert_equal 3, launchers.size
    assert_equal %w[avi steffon alex], launchers.map { |l| l[:agent_slug] }
    # Row 1 is the prompt-like soul heartbeat phrase (Avi's two lanes now share one
    # column); acts are the launcher atoms that scope it.
    assert_equal ["Avi Heartbeat", "Steffon Heartbeat", "Alex Heartbeat"],
                 launchers.map { |l| l[:heartbeat] }
    # Acts run DOWNSTREAM-FIRST: each soul leads with its idempotent close-out
    # action (production-deploy / archive-shipped) before the new-work action.
    # deploy-with-task trails Avi's list — direct-invoke only, never composed.
    assert_equal ["production-deploy", "pr-review", "pr-review-slow", "deploy-with-task"], launchers[0][:actions]
    assert_equal ["archive-shipped", "qa-release"], launchers[1][:actions]
    assert_equal ["grade-events", "share-insights", "full-cycle"], launchers[2][:actions]
    assert(launchers.all? { |l| l[:label].present? && l[:title].present? }, "each launcher carries a label + tooltip")
    # review-only contract (2026-07-03): Avi's tooltip must not claim the merge —
    # pr-review stops at reviewed; Steffon's sweep merges.
    refute_match(/merge/i, launchers[0][:title], "Avi's tooltip must not claim review + merge")
  end

  test "[component] _heartbeats_card renders the three soul heartbeat launchers in a 3-up grid" do
    Agent.find_or_create_by!(slug: "avi") { |a| a.name = "Avi" }
    Agent.find_or_create_by!(slug: "steffon") { |a| a.name = "Steffon" }
    Agent.find_or_create_by!(slug: "alex") { |a| a.name = "Alex" }

    render partial: "tasks/heartbeats_card"

    # The heartbeats live in their own card, one launcher per soul, 3-up grid.
    assert_select "[data-test='heartbeats-card']", count: 1
    assert_select "[data-test='heartbeats-card'][data-compact-limit='3']", count: 1
    assert_select "[data-test='heartbeats-card'][x-data*='heartbeatsExpanded']", count: 1
    assert_select "[data-test='heartbeats-card'] div.grid.grid-cols-3 [data-test='heartbeat-launcher']", count: 3
    assert_select "[data-test='heartbeat-compact-toggle']", text: /Show All/
    assert_select "[data-test='heartbeat-compact-toggle'] span[x-show='heartbeatsExpanded']", text: "Compact"
    # The tracker does NOT live here — it stays in the Current Release card.
    assert_select "[data-test='heartbeats-card'] [data-test='release-tracker-steps']", count: 0
    # Each launcher stacks a soul avatar (LINKING to /agents/<slug>) OVER a prompt-
    # like row 1 + its atom action(s), each an independently-copyable data-clip target.
    heartbeat_launchers.each do |launcher|
      scope = "[data-test='heartbeat-launcher'][data-agent='#{launcher[:agent_slug]}']"
      assert_select "#{scope} a[data-test='heartbeat-avatar-link'][href=?]", "/agents/#{launcher[:agent_slug]}"
      assert_select "#{scope} button[data-row='heartbeat'][data-clip=?]", launcher[:heartbeat] do
        assert_select "code", text: launcher[:heartbeat]
      end
      launcher[:actions].each do |act|
        assert_select "#{scope} button[data-row='action'][data-clip=?]", act do
          assert_select "code", text: act
        end
      end
      # Exactly (1 heartbeat + N acts) independently-copyable rows per launcher.
      assert_select "#{scope} button[data-clip]", count: 1 + launcher[:actions].size
    end
    # The new pr-review-slow + deploy-with-task (Avi) and full-cycle (Alex) acts
    # are copyable rows.
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] button[data-row='action'] code", text: "pr-review-slow"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] button[data-row='action'] code", text: "deploy-with-task"
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] button[data-row='action'] code", text: "full-cycle"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] [data-copy-row-index='2'] button[data-clip='pr-review']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] [data-copy-row-index='3'] button[data-clip='production-deploy']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] [data-copy-row-index='2'] button[data-clip='qa-release']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] [data-copy-row-index='3'] button[data-clip='archive-shipped']"
    assert_select "[data-test='heartbeat-launcher'] > span.text-muted", count: 0
    # Rows 4+ are still rendered as copy targets, but tucked behind the card toggle.
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] [data-test='heartbeat-copy-row'][data-copy-row-index='4'][x-show='heartbeatsExpanded'][x-cloak]"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] [data-test='heartbeat-copy-row'][data-copy-row-index='5'][x-show='heartbeatsExpanded'][x-cloak]"
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] [data-test='heartbeat-copy-row'][data-copy-row-index='4'][x-show='heartbeatsExpanded'][x-cloak]"
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] [data-test='heartbeat-copy-row'][x-show='heartbeatsExpanded']", count: 0
    # Each soul heartbeat row (row 1) carries a leading ❤️; there are exactly three.
    assert_select "[data-test='heartbeat-heart']", count: 3
    assert_select "[data-test='heartbeat-launcher'] button[data-row='heartbeat'] [data-test='heartbeat-heart']", text: "❤️", count: 3
    # Every act carries a leading icon — a 1️⃣–4️⃣ keycap for the four ordered release
    # acts, a themed glyph for the rest.
    assert_select "button[data-row='action'][data-clip='pr-review'] [data-test='action-icon']", text: "1️⃣"
    assert_select "button[data-row='action'][data-clip='qa-release'] [data-test='action-icon']", text: "2️⃣"
    assert_select "button[data-row='action'][data-clip='production-deploy'] [data-test='action-icon']", text: "3️⃣"
    assert_select "button[data-row='action'][data-clip='archive-shipped'] [data-test='action-icon']", text: "4️⃣"
    assert_select "button[data-row='action'][data-clip='pr-review-slow'] [data-test='action-icon']", text: "🐢"
    assert_select "button[data-row='action'][data-clip='grade-events'] [data-test='action-icon']", text: "🧑🏻‍🏫"
    assert_select "button[data-row='action'][data-clip='share-insights'] [data-test='action-icon']", text: "📡"
    assert_select "button[data-row='action'][data-clip='full-cycle'] [data-test='action-icon']", text: "🌎"
    assert_select "button[data-row='action'][data-clip='deploy-with-task'] [data-test='action-icon']", text: "⚡"
    # One icon per act row: Avi 4 + Steffon 2 + Alex 3 = 9.
    assert_select "[data-test='action-icon']", count: 9
    # The copy helper (with its execCommand fallback) is present on the page.
    assert_includes rendered, "window.copyText"
  end

  test "[component] the DevOps card keeps its stage tiles but no longer carries the heartbeats" do
    render partial: "tasks/release_duration_card", locals: { dashboard: {} }

    assert_select "#release-duration-card [data-test='heartbeat-launcher']", count: 0
    assert_select "#release-duration-card [data-test='release-duration-stage']", count: 4
  end

  test "[component] the DevOps card lays the four stage tiles in a single row (grid-cols-4 on sm+)" do
    render partial: "tasks/release_duration_card", locals: { dashboard: {} }

    # All four per-stage tiles (Building/Reviewing/Assembling/Shipping) line up in one
    # row on sm+ (grid-cols-4), wrapping to 2×2 on mobile (grid-cols-2 base).
    assert_select "[data-test='release-duration-stage-grid'].grid.grid-cols-2.sm\\:grid-cols-4"
    assert_select "[data-test='release-duration-stage-grid'] [data-test='release-duration-stage']", count: 4
    # The wider Deployment summary tile stays its own full-width row below.
    assert_select "#release-duration-card [data-test='release-duration-deployment']", count: 1
  end

  test "[component] the Last Release card shows a muted empty state when nothing has shipped" do
    render partial: "tasks/last_release", locals: { release: nil }

    # With no shipped release the card still renders (filling its 2×2 grid cell),
    # mirroring the Next Release "none active" placeholder.
    assert_select "#last-release", count: 1
    assert_select "#last-release", text: /Last Release/
    assert_select "#last-release", text: /none yet/
  end

  test "[component] the Last Release card marks a freshly shipped deploy for live glow" do
    travel_to Time.zone.local(2026, 7, 6, 12, 0, 0) do
      rel = Release.open!
      rel.ship!

      render partial: "tasks/last_release", locals: { release: rel }

      assert_select "#last-release[data-fresh-deploy='true'][data-shipped-at-ms]"
      card = css_select("#last-release").first
      assert_includes card["class"], "studio-border-glow"
      assert_includes card["class"], "release-fresh-glow"
      assert_includes card["class"], "lbfx-fresh-deploy"
      assert_not_includes card["class"], "opacity-75"
      assert_includes card["style"], "--lbfx-fresh-delay: -0ms"
      assert_includes card["style"], "--task-card-glow-color-a: #fb0094"
      assert_includes card["style"], "--task-card-glow-color-b: #00c4ff"
      assert_includes card["style"], "border-color: var(--task-card-glow-border-color)"
      assert_includes card["style"], "box-shadow: var(--task-card-glow-shadow)"
    end
  end

  test "[component] the Last Release card stops marking stale deploys as fresh" do
    rel = nil
    travel_to Time.zone.local(2026, 7, 6, 12, 0, 0) do
      rel = Release.open!
      rel.ship!
    end

    travel_to Time.zone.local(2026, 7, 6, 12, 0, 9) do
      render partial: "tasks/last_release", locals: { release: rel.reload }

      assert_select "#last-release[data-fresh-deploy='false']"
      card = css_select("#last-release").first
      assert_includes card["class"], "opacity-75"
      assert_not_includes card["class"], "studio-border-glow"
      assert_not_includes card["class"], "release-fresh-glow"
      assert_not_includes card["class"], "lbfx-fresh-deploy"
      assert_nil card["style"]
    end
  end

  test "[component] _current_release no longer carries the heartbeat cluster (moved to the DevOps card)" do
    rel = Release.open!
    render partial: "tasks/current_release", locals: { release: rel }
    assert_select "#current-release [data-test='heartbeat-launcher']", count: 0

    render partial: "tasks/current_release", locals: { release: nil }
    assert_select "#current-release [data-test='heartbeat-launcher']", count: 0
  end

  test "[unit] action_description captions every act in every launcher" do
    heartbeat_launchers.each do |launcher|
      launcher[:actions].each do |act|
        desc = action_description(act)
        assert desc.present?, "act #{act} should have a one-line description"
        assert_operator desc.length, :<=, 60, "act description stays a short one-liner"
      end
    end
  end

  test "[unit] action_description maps the known acts to their captions" do
    assert_equal "Review all submitted PRs (review-only — Steffon sweeps)", action_description("pr-review")
    assert_equal "Review submitted PRs one at a time", action_description("pr-review-slow")
    assert_equal "Ship a QA-ready release to production", action_description("production-deploy")
    assert_equal "Prepare + deploy the QA release", action_description("qa-release")
    assert_equal "Archive shipped tasks + releases", action_description("archive-shipped")
    assert_equal "Grade 10 recent events for quality", action_description("grade-events")
    assert_equal "Full cycle — review, assemble, QA, ship to prod", action_description("full-cycle")
    assert_nil action_description("not-an-act")
  end

  test "[unit] action_icon numbers the four ordered release actions (1→4), nil otherwise" do
    assert_equal "1️⃣", action_icon("pr-review")
    assert_equal "2️⃣", action_icon("qa-release")
    assert_equal "3️⃣", action_icon("production-deploy")
    assert_equal "4️⃣", action_icon("archive-shipped")
    assert_equal "🐢", action_icon("pr-review-slow")
    assert_equal "🧑🏻‍🏫", action_icon("grade-events")
    assert_equal "🌎", action_icon("full-cycle")
    assert_nil action_icon("not-an-act")
  end

  test "[unit] heartbeat_launcher_for resolves the soul launcher and skips non-souls" do
    avi = heartbeat_launcher_for("avi")
    assert avi.present?
    assert_equal "Avi Heartbeat", avi[:heartbeat]
    assert_equal ["production-deploy", "pr-review", "pr-review-slow", "deploy-with-task"], avi[:actions]

    assert_nil heartbeat_launcher_for("shannon"), "a non-heartbeat agent has no launcher"
    assert_nil heartbeat_launcher_for(nil)
  end
end
