require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  # ActionView::TestCase mixes in only the helper its class name names; the app
  # mixes in all of them. release_state_label reaches for the "at" primitive,
  # which the GEM owns — the hub's fork is retired. Named explicitly here so a
  # broken gem-side rename fails on this line instead of somewhere downstream.
  include Studio::AtTimeHelper

  test "compact_time_ago renders the smallest legible unit and guards blank/future times" do
    now = Time.utc(2026, 7, 7, 12, 0, 0)

    assert_nil compact_time_ago(nil, now: now), "a blank time renders nothing"
    assert_equal "just now", compact_time_ago(now - 10, now: now)
    assert_equal "just now", compact_time_ago(now - 50, now: now), "sub-minute reads 'just now', never '0m ago'"
    assert_equal "just now", compact_time_ago(now + 30, now: now), "a future time clamps, never negative"
    assert_equal "5m ago", compact_time_ago(now - (5 * 60), now: now)
    assert_equal "3h ago", compact_time_ago(now - (3 * 3_600), now: now)
    assert_equal "2d ago", compact_time_ago(now - (2 * 86_400), now: now)
    assert_equal "3w ago", compact_time_ago(now - (21 * 86_400), now: now)
  end

  test "[unit] compact created/updated stamps render tight 12-hour board footer times" do
    t = Time.utc(2026, 7, 7, 15, 32, 0) # 3:32pm, app runs in UTC (config.time_zone unset)

    assert_equal "3:32p", clock_12h(t), "single am/pm letter, no leading zero on the hour"
    assert_equal "Jul 7 3:32p", compact_created_stamp(t), "created carries the date + clock"
    assert_equal "3:32p", compact_updated_stamp(t), "updated is clock-only"

    # midnight/noon + single-digit-minute padding boundaries
    assert_equal "12:05a", clock_12h(Time.utc(2026, 7, 7, 0, 5, 0))
    assert_equal "12:00p", clock_12h(Time.utc(2026, 7, 7, 12, 0, 0))
    assert_equal "4:09p", compact_updated_stamp(Time.utc(2026, 7, 7, 16, 9, 0))

    assert_nil clock_12h(nil), "nil-safe"
    assert_nil compact_created_stamp(nil)
    assert_nil compact_updated_stamp(nil)
  end

  test "[unit] testing_phase_compact_label renders the tight duration cell" do
    assert_equal "2h 4m", testing_phase_compact_label({ "status" => "completed", "seconds" => 7440 })
    assert_equal "12m", testing_phase_compact_label({ "status" => "completed", "seconds" => 720 })
    assert_equal "—", testing_phase_compact_label({ "status" => "completed", "seconds" => nil }),
                 "completed without a measured span stays a dash"
    assert_equal "12m+", testing_phase_compact_label({ "status" => "in_progress", "seconds" => 720 })
    assert_equal "<1m+", testing_phase_compact_label({ "status" => "in_progress", "seconds" => 30 })
    assert_equal "—", testing_phase_compact_label({ "status" => "missing" })
  end

  test "[unit] testing_phase_range parses span stamps into the range hash" do
    range = testing_phase_range({ "started_at" => "2026-07-08T10:05:00Z", "completed_at" => "2026-07-08T10:34:00Z" })
    assert_equal Time.zone.parse("2026-07-08T10:05:00Z"), range[:started_at]
    assert_equal Time.zone.parse("2026-07-08T10:34:00Z"), range[:ended_at]

    open_range = testing_phase_range({ "started_at" => "2026-07-08T10:05:00Z" })
    assert_equal Time.zone.parse("2026-07-08T10:05:00Z"), open_range[:started_at]
    assert_nil open_range[:ended_at], "an in-progress span has no end stamp"

    assert_nil testing_phase_range({ "status" => "missing" }), "no start means no stamp stack"
    assert_nil testing_phase_range({ "started_at" => "not-a-time" }), "garbage parses to nil, never raises"
  end

  test "[unit] gate_verdict_glyph maps each verdict to its chip glyph" do
    now = Time.current

    assert_equal "✓", gate_verdict_glyph(GateRun.new(started_at: now, finished_at: now, success: true))
    assert_equal "✗", gate_verdict_glyph(GateRun.new(started_at: now, finished_at: now, success: false))
    assert_equal "●", gate_verdict_glyph(GateRun.new(started_at: now))
    assert_equal "·", gate_verdict_glyph(nil), "nil-safe for a gate that never ran"
  end

  # ---- phase-strip lane tiles + tile avatars --------------------------------

  test "[unit] review_lane_tiles keeps only the seats that actually ran, in order" do
    primary = GateRun.new(key: "g2a_primary")
    light   = GateRun.new(key: "g2b_light")

    both = review_lane_tiles("g2a_primary" => primary, "g2b_light" => light)
    assert_equal [["g2a_primary", "Primary", primary], ["g2b_light", "Light", light]], both,
                 "both lanes render in primary-then-light seat order"

    assert_equal [["g2b_light", "Light", light]], review_lane_tiles("g2b_light" => light),
                 "a lane with no run drops out (sparse-first)"
    assert_equal [], review_lane_tiles({}), "no review runs means no lanes"
    assert_equal [], review_lane_tiles(nil), "nil-safe when a task carries no gate map"
  end

  test "[unit] phase_tile_face resolves each phase to its owning avatar" do
    mascot = Object.new
    avi = Object.new

    # BUILD / CERT / CI are the machine phases the mascot's session drove.
    assert_same mascot, phase_tile_face("build", mascot_face: mascot, avi: avi)
    assert_same mascot, phase_tile_face("local_certification", mascot_face: mascot, avi: avi)
    assert_same mascot, phase_tile_face("ci", mascot_face: mascot, avi: avi)
    # REVIEW wears the review-owner face passed in as `avi:` (resolved from review_avi).
    assert_same avi, phase_tile_face("review", mascot_face: mascot, avi: avi)

    assert_nil phase_tile_face("build", mascot_face: nil, avi: avi),
               "an unresolved mascot leaves the tile faceless (sparse-first)"
    assert_nil phase_tile_face("review", mascot_face: mascot, avi: nil),
               "an unresolved Avi leaves Review faceless"
    assert_nil phase_tile_face("acceptance", mascot_face: mascot, avi: avi),
               "a phase with no defined owner has no face"
  end

  test "[unit] gate_run_reviewer resolves a lane's soul from the run actor" do
    agent = agents(:alex_agent)

    # Preloaded-map path (the /tasks/recent batch that avoids an N+1).
    assert_same agent, gate_run_reviewer(GateRun.new(actor: "alex"), lookup: { "alex" => agent })
    # Single-lookup path when no map is supplied.
    assert_equal agent, gate_run_reviewer(GateRun.new(actor: "alex"))

    assert_nil gate_run_reviewer(GateRun.new(actor: nil), lookup: { "alex" => agent }),
               "a run with no actor resolves to no soul"
    assert_nil gate_run_reviewer(nil), "nil-safe for a lane that never ran"
    assert_nil gate_run_reviewer(GateRun.new(actor: "ghost"), lookup: { "alex" => agent }),
               "an unresolved actor slug stays faceless, never raises"
  end

  test "[unit] phase_face_avatar_tag renders a sized circle with an image, sparse-safe" do
    assert_equal "", phase_face_avatar_tag(nil), "no face renders nothing"

    faced = Agent.new(name: "Avi", slug: "avi", avatar: "/agents/avi.png")
    html = phase_face_avatar_tag(faced, px: 24)
    assert_includes html, "width:24px;height:24px", "sizes the circle to the requested px"
    assert_includes html, "rounded-full"
    assert_includes html, 'src="/agents/avi.png"', "layers the face image over the initial bubble"
    assert_includes html, "onerror", "a 404 falls back to the bubble, no broken-image icon"
    assert_includes html, 'data-test="phase-tile-avatar"'

    faceless = Agent.new(name: "Mystery", slug: "mystery")
    bubble = phase_face_avatar_tag(faceless)
    assert_not_includes bubble, "<img", "no avatar file means initials-only, no empty img"
    assert_includes bubble, Agent.initials_for("Mystery")
  end

  test "right_fade_style emits both mask-image properties with the given stop" do
    style = right_fade_style
    assert_includes style, "mask-image: linear-gradient(to right, #000 88%, transparent)"
    assert_includes style, "-webkit-mask-image: linear-gradient(to right, #000 88%, transparent)"

    assert_includes right_fade_style(stop: 70), "#000 70%, transparent", "stop is configurable"
  end

  # The four environment-banner cases these helpers used to cover now live in
  # studio-engine (test/lib/studio/environment_banner_test.rb — same four rules,
  # asserted against the shipped module). The hub's own coverage of the seam is
  # test/views/environment_banner_adoption_test.rb: that the layout renders the
  # shared partial and carries no fork of its own.

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
    assert_equal "📐", app_emoji("mcritchie-industries")
  end

  # The /deployments lane badge renders app_emoji raw, so an unmapped member repo
  # draws an EMPTY box — which is how mcritchie-industries shipped a blank lane.
  # Assert the property (every repo the conductor can release has an identity),
  # not just the slugs that happen to be mapped today.
  test "every release-registry repo has a glyph, so no lane draws a blank badge" do
    repos = Release::Repos.gem_repos + Release::Repos.app_repos
    unmapped = repos.reject { |repo| app_emoji(repo) }

    assert_empty unmapped, "release-registry repos with no APP_EMOJIS glyph: #{unmapped.join(', ')}"
  end

  test "the industries glyph matches the one ReleaseNotes::Formatter ships" do
    group = ReleaseNotes::Formatter::APP_GROUPS.find { |g| g[:aliases].include?("mcritchie-industries") }

    assert group, "expected an APP_GROUPS entry aliased to mcritchie-industries"
    assert_equal app_emoji("mcritchie-industries"), group[:emoji],
                 "the board and the release notes must draw the same glyph"
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

  # The fresh-deploy glow window is ONE injectable value. Three hardcoded 8s
  # spellings (_last_release, the FX partial's CSS + JS) turned the release-ship
  # e2e into a wall-clock race under machine load (task
  # stabilize-release-ship-spec); every consumer now renders from this helper,
  # and FRESH_DEPLOY_WINDOW_MS widens it for the e2e server only
  # (playwright.config.js webServer env).
  test "[unit] fresh deploy window defaults to eight seconds" do
    with_env("FRESH_DEPLOY_WINDOW_MS", nil) do
      assert_equal 8_000, fresh_deploy_window_ms
    end
  end

  test "[unit] fresh deploy window honors the e2e injection env var" do
    with_env("FRESH_DEPLOY_WINDOW_MS", "20000") do
      assert_equal 20_000, fresh_deploy_window_ms
    end
  end

  test "[unit] fresh deploy window falls back on unparseable or non-positive overrides" do
    # A bad knob must never 500 every /deployments render — fall back, don't raise.
    ["bananas", "", "0", "-5"].each do |bad|
      with_env("FRESH_DEPLOY_WINDOW_MS", bad) do
        assert_equal 8_000, fresh_deploy_window_ms, "expected fallback for #{bad.inspect}"
      end
    end
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

  test "compact_stage_duration renders a tight one-token form, nil-safe" do
    assert_nil compact_stage_duration(nil)
    assert_equal "<1m", compact_stage_duration(30)
    assert_equal "12m", compact_stage_duration(12 * 60)
    assert_equal "3h", compact_stage_duration(3 * 3600)
    assert_equal "5d", compact_stage_duration(5 * 86_400)
  end

  test "precise_stage_duration compounds hours and days so it never truncates like the pill" do
    assert_nil precise_stage_duration(nil)
    assert_equal "<1m", precise_stage_duration(30)
    assert_equal "12m", precise_stage_duration(12 * 60)
    assert_equal "3h", precise_stage_duration(3 * 3600)                       # exact hour stays compact
    assert_equal "1h 30m", precise_stage_duration((90 * 60))                  # not "1h"
    assert_equal "2d 3h", precise_stage_duration((2 * 86_400) + (3 * 3600))   # not "2d"
    assert_equal "5d", precise_stage_duration(5 * 86_400)                     # exact day stays compact
  end

  test "release_duration_label uses the precise humanizer and its empty placeholder" do
    assert_equal "1h 30m", release_duration_label(90 * 60)
    assert_equal "—", release_duration_label(nil)
    assert_equal "n/a", release_duration_label(nil, empty: "n/a")
  end

  test "deployment_clock renders a 12-hour single-letter meridiem, noon/midnight safe" do
    assert_equal "3:32p", deployment_clock(Time.zone.local(2026, 7, 7, 15, 32))
    assert_equal "9:07a", deployment_clock(Time.zone.local(2026, 7, 7, 9, 7))
    assert_equal "12:00p", deployment_clock(Time.zone.local(2026, 7, 7, 12, 0))
    assert_equal "12:05a", deployment_clock(Time.zone.local(2026, 7, 7, 0, 5))
  end

  test "deployment_range_times bookends a stage, same-day drops the end date, running shows an ellipsis" do
    start = Time.zone.local(2026, 7, 7, 15, 32)
    assert_equal "3:32p → 4:01p", deployment_range_times(started_at: start, ended_at: Time.zone.local(2026, 7, 7, 16, 1))
    assert_equal "3:32p → …", deployment_range_times(started_at: start, ended_at: nil)
    assert_equal "3:32p → Jul 8 1:15a", deployment_range_times(started_at: start, ended_at: Time.zone.local(2026, 7, 8, 1, 15))
    assert_nil deployment_range_times(started_at: nil, ended_at: nil)
  end

  test "deployment_range_date is the light day label, nil when unstarted" do
    assert_equal "Jul 7, 2026", deployment_range_date(started_at: Time.zone.local(2026, 7, 7, 15, 32))
    assert_nil deployment_range_date(started_at: nil)
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
    # review is Carl-owned: one Carl per PR (standing primary + owner) + a domain LIGHT, base-tier tests
    assert_match(/primary/i, deploy["submitted"][:who])
    assert_match(/light/i, deploy["submitted"][:who])
    assert_match(/base/i, deploy["submitted"][:tests])
    # Avi owns the reviewed-stage sweep and QA release.
    assert_match(/avi/i, deploy["reviewed"][:who])
    assert_match(/qa-release/i, deploy["reviewed"][:what])
    # Avi owns QA; Steffon runs the frozen-SHA suite; production authority is explicit
    assert_match(/avi/i, deploy["assembled"][:who])
    assert_match(/frozen ship sha/i, deploy["shipped"][:tests])
    assert_match(/qa-release/i, deploy["shipped"][:gate])
    assert_match(/full-cycle/i, deploy["shipped"][:gate])
  end

  test "release_state_label folds a shipped release into 'Shipped at <clock>'" do
    shipped_at = Time.current.change(hour: 15, min: 53)
    rel = Release.new(state: "shipped", shipped_at: shipped_at)

    assert_equal "Shipped at 3:53p", Nokogiri::HTML.fragment(release_state_label(rel)).text
    assert_equal shipped_at.to_i.to_s,
                 Nokogiri::HTML.fragment(release_state_label(rel)).at_css("time")["data-at-epoch"],
                 "the badge carries the epoch so the client can re-stamp it to the viewer's clock"
  end

  test "release_state_label demotes the relative phrase to the badge's hover title" do
    rel = Release.new(state: "shipped", shipped_at: 7.minutes.ago)
    title = Nokogiri::HTML.fragment(release_state_label(rel)).at_css("time")["title"]

    assert_match(/7 minutes ago/, title)
  end

  test "release_state_label shows 'Assembled at <clock>' for an assembled current release" do
    rel = Release.new(state: "assembled", assembled_at: Time.current.change(hour: 14, min: 11))

    assert_equal "Assembled at 2:11p",
                 Nokogiri::HTML.fragment(release_state_label(rel, current: true)).text
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

  test "[component] _current_release renders a glow hook + a live in-progress ticker" do
    rel = Release.open!
    rel.stamp_stage!("assembling") # an active stage carries the live in-progress ticker
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
    both = devops_next_html("→ reviewed, or → assembled after that")
    assert_equal 2, both.scan("<span").size

    # "blocked" is a building ATTRIBUTE now, not a stage, so it stays plain text
    attr = devops_next_html("sends it back blocked for rework")
    assert_not_includes attr, "<span"

    # false positives: "build" in a flag and "blocked_from" must stay plain text
    plain = devops_next_html("passes dor-check --gate build; records blocked_from")
    assert_not_includes plain, "<span"
  end

  test "[unit] heartbeat_launchers maps the four souls to prompt + atom-act launchers" do
    launchers = heartbeat_launchers

    assert_equal 4, launchers.size
    assert_equal %w[carl avi steffon alex], launchers.map { |l| l[:agent_slug] }
    # Row 1 is the prompt-like soul heartbeat phrase; acts are the launcher atoms.
    assert_equal ["Carl Heartbeat", "Avi Heartbeat", "Steffon Heartbeat", "Alex Heartbeat"],
                 launchers.map { |l| l[:heartbeat] }
    # Acts read across the souls in pipeline order: review → assemble → ship → archive.
    # deploy-with-task trails Avi's list — direct-invoke only, never composed.
    assert_equal ["pr-review", "pr-review-slow"], launchers[0][:actions]
    assert_equal ["qa-release", "deploy-with-task"], launchers[1][:actions]
    assert_equal ["production-deploy", "archive-shipped"], launchers[2][:actions]
    assert_equal ["grade-events", "share-insights", "full-cycle"], launchers[3][:actions]
    assert(launchers.all? { |l| l[:label].present? && l[:title].present? }, "each launcher carries a label + tooltip")
    # review-only contract: Carl's tooltip frames review, not the merge — pr-review
    # stops at reviewed (merged to accepted); Avi's sweep promotes accepted→release.
    refute_match(/merge/i, launchers[0][:title], "Carl's tooltip stays review-framed, not merge-framed")
  end

  test "[component] _heartbeats_card renders the four soul heartbeat launchers in a responsive grid" do
    Agent.find_or_create_by!(slug: "carl") { |a| a.name = "Carl" }
    Agent.find_or_create_by!(slug: "avi") { |a| a.name = "Avi" }
    Agent.find_or_create_by!(slug: "steffon") { |a| a.name = "Steffon" }
    Agent.find_or_create_by!(slug: "alex") { |a| a.name = "Alex" }

    render partial: "tasks/heartbeats_card"

    # The heartbeats live in their own card, one launcher per soul, stacked on
    # narrow screens and 4-up once there is room.
    assert_select "[data-test='heartbeats-card']", count: 1
    assert_select "[data-test='heartbeats-card'][data-compact-limit='3']", count: 1
    assert_select "[data-test='heartbeats-card'][x-data*='heartbeatsExpanded']", count: 1
    assert_select "[data-test='heartbeats-card'] div.grid.grid-cols-1.sm\\:grid-cols-4 [data-test='heartbeat-launcher']", count: 4
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
    # Carl (pr-review + slow), Avi (qa-release + deploy-with-task), Steffon
    # (production-deploy + archive-shipped), Alex (grade + share + full-cycle).
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] button[data-row='action'] code", text: "pr-review-slow"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] button[data-row='action'] code", text: "deploy-with-task"
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] button[data-row='action'] code", text: "full-cycle"
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] [data-copy-row-index='2'] button[data-clip='pr-review']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] [data-copy-row-index='3'] button[data-clip='pr-review-slow']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] [data-copy-row-index='2'] button[data-clip='qa-release']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] [data-copy-row-index='3'] button[data-clip='deploy-with-task']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] [data-copy-row-index='2'] button[data-clip='production-deploy']"
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] [data-copy-row-index='3'] button[data-clip='archive-shipped']"
    assert_select "[data-test='heartbeat-launcher'] > span.text-muted", count: 0
    # Only Alex's list exceeds the compact limit (4 rows) → its row 4 (full-cycle)
    # is tucked behind the card toggle; Carl/Avi/Steffon (3 rows) have none hidden.
    assert_select "[data-test='heartbeat-launcher'][data-agent='alex'] [data-test='heartbeat-copy-row'][data-copy-row-index='4'][x-show='heartbeatsExpanded'][x-cloak]"
    assert_select "[data-test='heartbeat-launcher'][data-agent='carl'] [data-test='heartbeat-copy-row'][x-show='heartbeatsExpanded']", count: 0
    assert_select "[data-test='heartbeat-launcher'][data-agent='avi'] [data-test='heartbeat-copy-row'][x-show='heartbeatsExpanded']", count: 0
    assert_select "[data-test='heartbeat-launcher'][data-agent='steffon'] [data-test='heartbeat-copy-row'][x-show='heartbeatsExpanded']", count: 0
    # Each soul heartbeat row (row 1) carries a leading ❤️; there are exactly four.
    assert_select "[data-test='heartbeat-heart']", count: 4
    assert_select "[data-test='heartbeat-launcher'] button[data-row='heartbeat'] [data-test='heartbeat-heart']", text: "❤️", count: 4
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
    # One icon per act row: Carl 2 + Avi 2 + Steffon 2 + Alex 3 = 9.
    assert_select "[data-test='action-icon']", count: 9
    # The copy helper (with its execCommand fallback) is present on the page.
    assert_includes rendered, "window.copyText"
  end

  test "[component] the DevOps card keeps its stage tiles but no longer carries the heartbeats" do
    render partial: "tasks/release_duration_card", locals: { dashboard: {} }

    assert_select "#release-duration-card [data-test='heartbeat-launcher']", count: 0
    # Five tiles render even with no data (canonical stage list, values as "—").
    assert_select "#release-duration-card [data-test='release-duration-stage']", count: 5
  end

  test "[component] the DevOps card lays the five deployment-stage tiles in a single row (grid-cols-5 on sm+)" do
    render partial: "tasks/release_duration_card", locals: { dashboard: {} }

    # Tested / Assembled / Confirmed / Deployed / Total line up in one row on sm+
    # (grid-cols-5), wrapping on mobile (grid-cols-2 base).
    assert_select "[data-test='release-duration-stage-grid'].grid.grid-cols-2.sm\\:grid-cols-5"
    assert_select "[data-test='release-duration-stage-grid'] [data-test='release-duration-stage']", count: 5
    # The five tiles ARE the five duration columns.
    (Release::DEPLOYMENT_STAGES.map { |stage| stage[:key] } + ["total"]).each do |key|
      assert_select "[data-test='release-duration-stage'][data-stage='#{key}']", count: 1
    end
    # No separate wide Deployment tile — Total is one of the five.
    assert_select "#release-duration-card [data-test='release-duration-deployment']", count: 0
  end

  test "[component] deployment_stage_cell renders a completed span as a timestamp range + duration" do
    now = Time.zone.parse("2026-07-07 15:32:00")
    render partial: "releases/deployment_stage_cell",
           locals: { span: { key: "assembled", label: "Assembled", started_at: now,
                             ended_at: now + 29.minutes, seconds: 29.minutes.to_i, status: "completed" } }

    assert_select "[data-deployment-range][data-start='#{now.to_i}'][data-end='#{(now + 29.minutes).to_i}']"
    assert_select "[data-range-date]"
    assert_select "[data-range-time]"
    assert_includes rendered, "29m"
    assert_select "[data-release-ticker]", count: 0
  end

  test "[component] deployment_stage_cell ticks a live count-up for an in-progress span" do
    now = Time.zone.parse("2026-07-07 15:32:00")
    render partial: "releases/deployment_stage_cell",
           locals: { span: { key: "assembled", label: "Assembled", started_at: now,
                             ended_at: nil, seconds: nil, status: "in_progress" } }

    assert_select "[data-test='deployment-stage-live'][data-release-ticker][data-since='#{now.to_i}']"
    assert_select "[data-deployment-range] [data-range-time]", text: /→ …/
  end

  test "[component] deployment_stage_cell renders a missing span as an em dash" do
    render partial: "releases/deployment_stage_cell",
           locals: { span: { key: "tested", label: "Tested", started_at: nil,
                             ended_at: nil, seconds: nil, status: "missing" } }

    assert_select "[data-deployment-range]", count: 0
    assert_includes rendered, "—"
  end

  AVG_FIXTURE = {
    "sample_count" => 3,
    "stages" => {
      "assembled" => { "label" => "Assembled", "average_seconds" => 1320 },
      "g3_candidate" => { "label" => "G3 Candidate", "average_seconds" => 180 },
      "g4_ship" => { "label" => "G4 Ship", "average_seconds" => 120 },
      "deployed" => { "label" => "Deployed", "average_seconds" => 120 },
      "total" => { "label" => "Total", "average_seconds" => 3180 }
    }
  }.freeze

  test "[component] deployment_average_row renders per-stage means with no timestamp range" do
    # A bare <tr> partial is hoisted out of table context by the HTML parser, so
    # assert on the rendered string rather than assert_select "tr".
    render partial: "releases/deployment_average_row", locals: { averages: AVG_FIXTURE, label: "3-release avg" }

    assert_includes rendered, "deployment-average-row"
    assert_includes rendered, "3-release avg"
    assert_not_includes rendered, "data-deployment-range" # no per-timestamp ranges on the mean row
    assert_includes rendered, "22m" # assembled mean
    assert_includes rendered, "53m" # total mean
  end

  test "[component] deployment_average_chart draws one labelled coloured bar per stage on a shared scale" do
    render partial: "releases/deployment_average_chart",
           locals: { averages: AVG_FIXTURE, label: "3-release avg", max_seconds: 1320 }

    assert_select "figure figcaption", text: /3-release avg/
    assert_select "figure figcaption", text: /Total/
    assert_select "figure [role='img'] > div", count: Release::DEPLOYMENT_STAGES.size
    Release::DEPLOYMENT_STAGES.each { |stage| assert_includes rendered, stage[:label] }
    assert_includes rendered, "background-color: #199e70" # assembled = aqua
    assert_includes rendered, "width: 100%"               # assembled at the shared max
    assert_includes rendered, "22m"
  end

  test "[component] deployment_average_chart shows a no-data stage as an em dash with a zero-width bar" do
    # Regression: a nil average (a stage with no completed samples, e.g. the
    # gate columns on pre-gate releases with no backfill) must NOT coerce to 0
    # and draw the 2%-floor bar reading "<1m" — it should render "—" with no fill.
    averages = {
      "sample_count" => 3,
      "stages" => {
        "assembled" => { "label" => "Assembled", "average_seconds" => 1320 },
        "g3_candidate" => { "label" => "G3 Candidate", "average_seconds" => nil },
        "g4_ship" => { "label" => "G4 Ship", "average_seconds" => 120 },
        "deployed" => { "label" => "Deployed", "average_seconds" => 120 },
        "total" => { "label" => "Total", "average_seconds" => 3180 }
      }
    }
    render partial: "releases/deployment_average_chart",
           locals: { averages: averages, label: "3-release avg", max_seconds: 1320 }

    assert_includes rendered, "width: 0%; background-color: #3987e5"   # G3: no data, no bar
    assert_no_match(/width: 2%; background-color: #3987e5/, rendered)  # never the false 2% floor
    assert_includes rendered, "—"                                      # G3 value is a dash, not "<1m"
    assert_includes rendered, "width: 100%; background-color: #199e70" # a real stage still draws its bar
  end

  test "[component] deployment_stage_cell tints a failed gate attempt red with a ✗" do
    now = Time.zone.parse("2026-07-07 15:32:00")
    render partial: "releases/deployment_stage_cell",
           locals: { span: { key: "g3_candidate", label: "G3 Candidate", started_at: now,
                             ended_at: now + 3.minutes, seconds: 3.minutes.to_i, status: "completed",
                             success: false, attempt: 1 } }

    assert_select "[data-test='deployment-stage-failed'].text-rose-400", text: /✗ 3m/
    assert_select "[data-test='deployment-stage-attempts']", count: 0 # no retry badge on attempt 1
    # The timestamp range still renders — a failed attempt keeps its window.
    assert_select "[data-deployment-range][data-start='#{now.to_i}']"
  end

  test "[component] deployment_stage_cell renders the ×n retry badge when attempt > 1" do
    now = Time.zone.parse("2026-07-07 15:32:00")
    render partial: "releases/deployment_stage_cell",
           locals: { span: { key: "g3_candidate", label: "G3 Candidate", started_at: now,
                             ended_at: now + 17.minutes, seconds: 17.minutes.to_i, status: "completed",
                             success: true, attempt: 2 } }

    assert_select "[data-test='deployment-stage-attempts']", text: "×2"
    # A passed retry is NOT tinted red — the badge alone carries the history.
    assert_select "[data-test='deployment-stage-failed']", count: 0
  end

  test "[component] deployment_stage_cell is unchanged for stamp-backed spans (no gate keys)" do
    now = Time.zone.parse("2026-07-07 15:32:00")
    render partial: "releases/deployment_stage_cell",
           locals: { span: { key: "assembled", label: "Assembled", started_at: now,
                             ended_at: now + 29.minutes, seconds: 29.minutes.to_i, status: "completed" } }

    assert_select "[data-test='deployment-stage-failed']", count: 0
    assert_select "[data-test='deployment-stage-attempts']", count: 0
    assert_includes rendered, "29m"
  end

  test "[unit] gate_sop_duration_label humanizes millisecond durations" do
    assert_equal "6m 52s", gate_sop_duration_label(412_000)
    assert_equal "41s", gate_sop_duration_label(41_000)
    assert_equal "900ms", gate_sop_duration_label(900)
    assert_nil gate_sop_duration_label(0)
    assert_nil gate_sop_duration_label(nil)
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

      assert_select "#last-release[data-fresh-deploy='true'][data-shipped-at-ms][data-fresh-window-ms='8000']"
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

  # THE REGRESSION, at the lowest tier that shows it: +9s is stale under the
  # production 8s window (the test above) — exactly what the release-ship e2e
  # hit when its own arrival waits ate the window under load. Under the
  # injected e2e window the SAME +9s render stays fresh, with the glow phase
  # carrying the true elapsed time — that headroom is what un-races the spec.
  test "[component] a widened injected window keeps a nine-second-old deploy fresh" do
    rel = nil
    travel_to Time.zone.local(2026, 7, 6, 12, 0, 0) do
      rel = Release.open!
      rel.ship!
    end

    with_env("FRESH_DEPLOY_WINDOW_MS", "20000") do
      travel_to Time.zone.local(2026, 7, 6, 12, 0, 9) do
        render partial: "tasks/last_release", locals: { release: rel.reload }

        assert_select "#last-release[data-fresh-deploy='true'][data-fresh-window-ms='20000']"
        card = css_select("#last-release").first
        assert_includes card["class"], "studio-border-glow"
        assert_includes card["class"], "release-fresh-glow"
        assert_includes card["class"], "lbfx-fresh-deploy"
        assert_not_includes card["class"], "opacity-75"
        assert_includes card["style"], "--lbfx-fresh-delay: -9000ms"
      end
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
    assert_equal "Review all submitted PRs (review-only — Avi sweeps)", action_description("pr-review")
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
    assert_equal ["qa-release", "deploy-with-task"], avi[:actions]

    carl = heartbeat_launcher_for("carl")
    assert carl.present?
    assert_equal ["pr-review", "pr-review-slow"], carl[:actions]

    assert_nil heartbeat_launcher_for("shannon"), "a non-heartbeat agent has no launcher"
    assert_nil heartbeat_launcher_for(nil)
  end

end
