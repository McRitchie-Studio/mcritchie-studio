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

  test "devops_kickoffs covers every DevOps board stage plus the QA-release meta-trigger" do
    stage_keys = devops_kickoffs.keys - [ApplicationHelper::QA_RELEASE_KICKOFF_KEY]
    assert_equal Task::DEPLOY_STAGES.sort, stage_keys.sort
    # per-stage kickoffs stay terse enough for a column header (≤3 words)
    stage_keys.each { |k| assert_operator devops_kickoffs[k].split.size, :<=, 3 }
  end

  test "shipped kickoff is the Archive completed tasks workflow (DevOps loop conclusion)" do
    assert_equal "Archive completed tasks", devops_kickoffs["shipped"]
  end

  test "qa_release_kickoff is the one-trigger Build and Deploy QA Release command" do
    assert_equal "Build and Deploy QA Release", qa_release_kickoff
    assert_equal qa_release_kickoff, devops_kickoffs[ApplicationHelper::QA_RELEASE_KICKOFF_KEY]
    # the meta-trigger is exempt from the per-stage word cap (prominent chip, not a header)
    assert_not_includes Task::DEPLOY_STAGES, ApplicationHelper::QA_RELEASE_KICKOFF_KEY
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

  test "[component] _release_summary stacks member pills into one overlapping row" do
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
    pills.drop(1).each { |pill| assert_includes pill["class"], "-ml-20" }
    assert_includes pills[1]["style"], "z-index: 2;"
    assert_includes pills[2]["style"], "z-index: 3;"
  end

  test "[unit] release_tracker_steps maps release train updates" do
    rel = Release.open!
    assert_equal %i[active pending pending pending pending],
                 release_tracker_steps(rel).map { |step| step[:state] }

    tasks(:queued_task).update!(stage: "assembled", release_slug: rel.slug)
    assert_equal %i[complete active pending pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }

    rel.update!(qa_url: "https://qa.mcritchie.studio")
    assert_equal %i[complete complete active pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }

    rel.assemble!
    assert_equal %i[complete complete complete active pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }

    rel.reopen!
    assert_equal %i[complete complete active pending pending],
                 release_tracker_steps(rel.reload).map { |step| step[:state] },
                 "a reopened release must not over-advance from sticky assembled_at"

    rel.assemble!
    rel.update!(confirmed_at: Time.current)
    assert_equal %i[complete complete complete complete active],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }

    rel.update!(state: "shipped")
    assert_equal %i[complete complete complete complete complete],
                 release_tracker_steps(rel.reload).map { |step| step[:state] }
  end

  test "[component] _release_summary renders the current release tracker stages" do
    rel = Release.open!
    tasks(:queued_task).update!(stage: "assembled", release_slug: rel.slug)
    rel.update!(qa_url: "https://qa.mcritchie.studio")
    rel.assemble!

    render partial: "tasks/release_summary", locals: { release: rel, variant: :current }

    assert_select "[data-test='release-tracker']"
    assert_select "[data-test='release-tracker-step']", 5
    %w[Merging Testing Assembling Confirming Deploying].each do |label|
      assert_select "[data-test='release-tracker-label']", text: label
    end
    assert_select "[data-test='release-tracker-step'][data-state='complete']", 3
    assert_select "[data-test='release-tracker-step'][data-state='active'][data-stage='confirming']"
    assert_select "[data-test='release-tracker-step'][data-state='active'] [aria-current=?]", "step"
    assert_select "[data-test='release-tracker-step'][data-state='active'] [data-test='release-tracker-label'].text-amber-700.dark\\:text-amber-200"
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
    # review is Avi-delegated to two seniors, scoped to base-tier tests
    assert_match(/two senior/i, deploy["submitted"][:who])
    assert_match(/base/i, deploy["submitted"][:tests])
    # Steffon owns QA; Avi runs the frozen-SHA suite; the operator is the one gate
    assert_match(/steffon/i, deploy["assembled"][:who])
    assert_match(/frozen ship sha/i, deploy["shipped"][:tests])
    assert_match(/operator gate/i, deploy["shipped"][:gate])
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

  test "format_elapsed_clock renders a seconds-precision H/M/S clock, zero-padded" do
    assert_equal "0s", format_elapsed_clock(0)
    assert_equal "45s", format_elapsed_clock(45)
    assert_equal "7m 23s", format_elapsed_clock(7 * 60 + 23)
    assert_equal "7m 03s", format_elapsed_clock(7 * 60 + 3), "trailing units zero-pad for a stable width"
    assert_equal "1h 04m 09s", format_elapsed_clock(3600 + 4 * 60 + 9)
  end

  test "release_elapsed_clock counts seconds from the release's created_at" do
    rel = Release.new(state: "assembling", created_at: Time.utc(2026, 1, 1, 0, 0, 0))
    assert_equal "0s", release_elapsed_clock(rel, now: Time.utc(2026, 1, 1, 0, 0, 0))
    assert_equal "7m 23s", release_elapsed_clock(rel, now: Time.utc(2026, 1, 1, 0, 7, 23))
  end

  test "[component] _current_release renders a glow hook + a live in-progress ticker" do
    rel = Release.open!
    render partial: "tasks/current_release", locals: { release: rel }

    assert_select "#current-release[data-glow]" # the live-flash tint hook rides the card
    assert_select "#current-release [data-release-ticker][data-since=?]", rel.created_at.to_i.to_s
    assert_select "#current-release [data-test='release-timing']", text: /\Ain progress · /
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
end
