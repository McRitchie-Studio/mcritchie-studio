# frozen_string_literal: true

require "test_helper"

# [component] The /deployments SUMMARY ROW's cards in isolation — what each summary
# promises the operator, and the shared attributes that make every card open its own
# sidebar. The row's layout and the sidebars around it are proved on the real page in
# test/controllers/tasks_controller_test.rb; the browser behaviour (open, switch,
# dismiss, the carousel turning) in e2e/deploy_summary_row.spec.js.
class DeploySummaryCardsTest < ActionView::TestCase
  include ApplicationHelper
  include ReleaseMembersHelper

  setup do
    Release.delete_all
    Task.delete_all
    GateRun.where(subject_type: "release").delete_all
  end

  # --- the shared card attributes ------------------------------------------

  test "[unit] every summary card opens its own sidebar the same way" do
    options = deploy_summary_card_options("devops", test: "devops-summary-card", id: "devops-summary-card")

    assert_equal "openFrom($event, 'devops')", options[:"@click"]
    assert_includes options[:class], "h-full"
    assert_equal({ test: "devops-summary-card", panel: "devops" }, options[:data])
    assert_equal "devops-summary-card", options[:id]
    refute deploy_summary_card_options("apps", test: "x").key?(:id), "a nil id is dropped, never rendered empty"
    # NOT role=button: a button's children are presentational to assistive tech, and
    # the Workflows card holds copy chips and carousel dots that must stay reachable.
    refute options.key?(:role)
    refute options.key?(:tabindex)
    # The card draws the focus ring its heading button earns.
    assert_includes options[:class], "has-[.summary-card-toggle:focus-visible]:ring-2"
  end

  # THE KEYBOARD AND SCREEN-READER CONTROL: a real button in each card's heading, a
  # disclosure over the sidebar it names. Native Enter/Space, no hand-rolled key handling.
  test "[unit] each card's heading button discloses its own sidebar" do
    toggle = deploy_summary_toggle_options("releases")

    assert_equal "button", toggle[:type]
    assert_equal "deploy-sidebar-releases", toggle[:"aria-controls"]
    assert_equal "false", toggle[:"aria-expanded"], "server-rendered closed, before Alpine binds it"
    assert_equal "panel === 'releases' ? 'true' : 'false'", toggle[:":aria-expanded"]
    assert_equal "toggle('releases')", toggle[:"@click"]
    assert_includes toggle[:class], "summary-card-toggle"
  end

  test "[unit] a summary row names its branch in the width a line can spare" do
    assert_equal "acc", app_summary_branch("accepted")
    assert_equal "rel", app_summary_branch("release")
    assert_equal "main", app_summary_branch("main")
  end

  test "[unit] a soul's heartbeat row describes the soul without repeating its name" do
    launcher = heartbeat_launchers.find { |l| l[:agent_slug] == "steffon" }

    assert_equal "Ship a QA-green release (it archives on the way out), then sweep the machine",
                 heartbeat_description(launcher)
  end

  # --- Applications: one line per app ---------------------------------------

  test "[component] an app line names its latest suite's branch and draws the inline meter" do
    render partial: "tasks/app_summary_row", locals: { card: ladder_card(latest: "release", state: :pending) }

    row = css_select("[data-test='app-summary-row']").first
    assert_equal "turf-monster", row["data-repo"]
    assert_equal "release", row["data-branch"]
    assert_select "[data-test='app-summary-branch']", text: "rel"
    assert_select "[data-test='app-summary-ci'] [data-inline='true']", 1
    assert_includes row["title"], "release suite"
  end

  # The news reads at full strength; an app whose latest suite settled green steps back.
  test "[component] a settled green app steps back, a running one does not" do
    render partial: "tasks/app_summary_row", locals: { card: ladder_card(latest: "main", state: :green) }
    assert_includes css_select("[data-test='app-summary-row']").first["class"], "opacity-70"
  end

  test "[component] a running app keeps full strength" do
    render partial: "tasks/app_summary_row", locals: { card: ladder_card(latest: "accepted", state: :pending) }
    refute_includes css_select("[data-test='app-summary-row']").first["class"], "opacity-70"
  end

  test "[component] the sidebar stacks every full app card, full width, in the order handed in" do
    cards = %w[turf-monster studio-engine].map { |repo| ladder_card(repo: repo, latest: "main", state: :green) }

    render partial: "tasks/app_ladder_detail", locals: { cards: cards }

    assert_select "#app-ladder-detail[data-test='app-ladder-detail']", 1
    assert_equal %w[turf-monster studio-engine],
                 css_select("#app-ladder-detail [data-test='app-ladder-card']").map { |el| el["data-repo"] }
    assert_select "#app-ladder-detail [data-test='app-ladder-card'].w-full", 2
  end

  # --- Releases: counts per app, last ship time, the Pokémon -----------------

  # NOTHING OPEN: Next reads what is QUEUED on `accepted`, per app, largest first —
  # exactly what the next sweep will promote. "None active" alone answered nothing.
  test "[component] with no candidate open, Next counts the work queued on accepted" do
    cards = [ladder_card(repo: "turf-monster", parked_accepted: 2),
             ladder_card(repo: "mcritchie-studio", parked_accepted: 4),
             ladder_card(repo: "solana-studio", parked_accepted: 1),
             ladder_card(repo: "studio-engine", parked_accepted: 0)]

    render partial: "tasks/release_summary_card", locals: { current_release: nil, last_release: nil, cards: cards }

    assert_select "#release-summary-card[data-panel='releases']", 1
    assert_select "[data-test='release-summary-next'][data-state='queued']", 1
    assert_select "[data-test='release-summary-next-state']", text: "none active"
    counts = css_select("[data-test='release-summary-next-counts'] [data-test='app-count']")
    assert_equal [["mcritchie-studio", "4"], ["turf-monster", "2"], ["solana-studio", "1"]],
                 counts.map { |el| [el["data-repo"], el["data-count"]] }
    assert_equal "🪎", counts.first.at_css("[aria-hidden]").text.strip, "the chest is mcritchie-studio"
    assert_select "[data-test='release-summary-next-note']", text: /7 tasks queued on accepted/
    assert_select "[data-test='release-summary-last']", text: /none yet/
  end

  test "[component] an open candidate reads its own members per app, with a live clock" do
    release = Release.open!(branch: "release/summary-open")
    task(repo: "turf-monster", release: release)
    task(repo: "turf-monster", release: release)
    task(repo: "studio-engine", release: release)

    render partial: "tasks/release_summary_card", locals: { current_release: release, last_release: nil, cards: [] }

    assert_select "[data-test='release-summary-next'][data-state='open']", 1
    counts = css_select("[data-test='release-summary-next-counts'] [data-test='app-count']")
    assert_equal({ "turf-monster" => "2", "studio-engine" => "1" }, counts.to_h { |el| [el["data-repo"], el["data-count"]] })
    assert_select "[data-test='release-summary-next-note'] [data-release-ticker][data-since='#{release.created_at.to_i}']", 1
  end

  test "[component] Last shows when it shipped, the Pokémon that ran it, and its features per app" do
    Pokemon.find_or_create_by!(slug: "pidgey") { |p| p.name = "Pidgey"; p.dex = 16 }
    release = Release.open!(branch: "release/summary-last")
    release.update!(metadata: { "devops" => { "mascot" => "pidgey" } })
    task(repo: "mcritchie-studio", release: release)
    task(repo: "mcritchie-studio", release: release)
    release.ship!

    render partial: "tasks/release_summary_card", locals: { current_release: nil, last_release: release.reload, cards: [] }

    assert_select "[data-test='release-summary-last-shipped'] time[datetime='#{release.shipped_at.in_time_zone.iso8601}']", 1
    assert_select "[data-test='release-summary-last-shipped']", text: /Shipped/
    assert_select "[data-test='release-summary-last-mascot']", text: "Pidgey"
    assert_select "[data-test='release-summary-last-counts'] [data-test='app-count'][data-repo='mcritchie-studio'][data-count='2']", 1
  end

  # --- DevOps: the typical release, honestly ---------------------------------

  test "[component] DevOps leads with the median, keeps the mean beside it, and names the outliers" do
    flow = Release::Flow.new([30, 40, 50, 60, 600].each_with_index.map { |minutes, i| entry("rel-#{i}", minutes) })

    render partial: "tasks/devops_summary_card", locals: { flow: flow, wip_count: 17 }

    assert_select "#devops-summary-card[data-panel='devops']", 1
    assert_select "[data-test='summary-card-meta']", text: "17 in flight"
    assert_select "[data-test='devops-typical'][data-seconds='#{50 * 60}']", text: "50m"
    assert_select "[data-test='devops-mean']", text: release_duration_label(156 * 60)
    columns = css_select("[data-test='devops-spark-column']")
    assert_equal %w[rel-4 rel-3 rel-2 rel-1 rel-0], columns.map { |el| el["data-release"] }, "oldest first"
    assert_equal %w[false false false false true].reverse, columns.map { |el| el["data-clipped"] },
                 "the 10h release is clipped and marked, not allowed to flatten the rest"
    assert_select "[data-test='devops-phase']", 4
    assert_select "[data-test='devops-outlier-note']", text: /1 slow release.*most of it in Batch/m
  end

  test "[component] DevOps with nothing shipped says so instead of drawing empty charts" do
    render partial: "tasks/devops_summary_card", locals: { flow: Release::Flow.new([]), wip_count: 0 }

    assert_select "[data-test='devops-empty']", text: "No shipped releases yet."
    assert_select "[data-test='devops-sparkline']", 0
  end

  test "[component] the DevOps sidebar splits WIP by stage, tables the phases, and rows every release" do
    flow = Release::Flow.new([entry("rel-a", 30), entry("rel-b", 600), entry("rel-c", 40)])
    wip = { "designed" => 3, "building" => 5, "submitted" => 0, "reviewed" => 7, "assembled" => 2 }

    render partial: "tasks/devops_detail", locals: { flow: flow, wip_count: 17, wip_by_stage: wip }

    assert_equal wip.transform_values(&:to_s),
                 css_select("[data-test='devops-wip-stage']").to_h { |el| [el["data-stage"], el["data-count"]] }
    assert_select "[data-test='devops-phase-row']", 4
    assert_equal %w[rel-a rel-b rel-c], css_select("[data-test='devops-release-row']").map { |el| el["data-release"] }
    assert_select "[data-test='devops-release-row'][data-slow='true'][data-release='rel-b']", 1
    assert_select "[data-test='devops-detail-flow']", text: /because\s+1 release ran past 3× the median/
  end

  private

  def ladder_card(repo: "turf-monster", latest: "main", state: :green, parked_accepted: 0)
    rungs = Ci::AppLadder::RUNGS.map do |branch|
      Ci::LadderRung.new(repo: repo, branch: branch, state: branch == latest ? state : :green,
                         sha: "abc1234def", verdict_at: (branch == latest ? 1.minute.ago : nil),
                         parked_count: branch == "accepted" ? parked_accepted : 0)
    end
    card = Ci::AppLadder::Card.new(repo: repo, rungs: rungs)
    # The meter's checks, without the query a real rung makes for them.
    progress = if state == :pending then Ci::CheckProgress.new(passed: 3, pending: 2)
               elsif state == :red then Ci::CheckProgress.new(passed: 3, failed: 1)
               else Ci::CheckProgress.new(passed: 5)
               end
    card.instance_variable_set(:@latest_suite_progress, progress)
    card.instance_variable_set(:@progress, progress)
    card
  end

  def task(repo:, release:)
    @task_seq = @task_seq.to_i + 1
    Task.create!(title: "Summary member task #{@task_seq}", stage: "assembled", release_slug: release.slug,
                 merged: Task::MERGED_RELEASE, metadata: { "devops" => { "repositories" => [repo] } })
  end

  # Every minute in Batch unless phases are given — the outlier note names the phase.
  def entry(slug, minutes)
    seconds = minutes * 60
    Release::Flow::Entry.new(slug: slug, mascot: nil, shipped_at: Time.current, total: seconds,
                             phases: { "batch" => seconds, "qa" => 0, "hold" => 0, "ship" => 0 })
  end
end
