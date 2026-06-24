require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
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
