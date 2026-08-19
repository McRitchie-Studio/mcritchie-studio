# frozen_string_literal: true

require "test_helper"

# /deployments renders the app-ladder row, and renders it HONESTLY: the two states
# that exist to stop a stale or absent verdict reading as a pass must survive all
# the way to the markup, not just the model.
class AppLadderRowTest < ActionDispatch::IntegrationTest
  setup do
    Task.delete_all
    GithubWorkflowRun.delete_all
  end

  test "the deployments page renders the app ladder row" do
    get deployments_path

    assert_response :success
    assert_select "[data-test='app-ladder-row']", 1
    assert_select "[data-test='app-ladder-card']", minimum: 1
    assert_select "[data-test='app-ladder-suite']", minimum: 1
  end

  test "every reportable repo gets exactly one card" do
    get deployments_path

    Ci::AppLadder.reportable_repos.each do |repo|
      assert_select "[data-test='app-ladder-card'][data-repo='#{repo}']", 1,
                    "#{repo} must have exactly one ladder card"
    end
  end

  test "a dormant repo gets no card" do
    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='rolio']", 0
  end

  # On the ladder, but declares no CI suite — every rung would read not_built
  # forever, so it earns no card. See Ci::AppLadder.reportable_repos.
  test "a three-rung repo with no declared CI suite gets no card" do
    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='solana-studio']", 0
  end

  test "each card carries all three rungs" do
    get deployments_path

    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']" do
      %w[accepted release main].each do |branch|
        assert_select "[data-test='app-ladder-rung'][data-branch='#{branch}']", 1
      end
    end
  end

  # With nothing ingested, every rung must read not_built — never green. This is
  # the empty-board case, and a card that greened here would be asserting a pass
  # from an absence.
  test "with no ingested CI every rung reads not_built rather than green" do
    get deployments_path

    assert_select "[data-test='app-ladder-rung'][data-state='not_built']", minimum: 3
    assert_select "[data-test='app-ladder-rung'][data-state='green']", 0,
                  "an absent verdict must never render as green"
  end

  test "parked work is counted onto the rung its stamp names" do
    make_task(slug: "parked-on-accepted-one", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])
    make_task(slug: "parked-on-accepted-two", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

    get deployments_path

    assert_response :success
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']" do
      assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", text: /2 on accepted/
    end
  end

  # The reset the operator asked for: once work advances to main, the accepted rung
  # stops reporting it. Derived from the stamp, so there is nothing to clear.
  test "advancing a task to main drains the accepted rung" do
    task = make_task(slug: "advances-to-production", merged: Task::MERGED_ACCEPTED, repos: %w[turf-monster])

    get deployments_path
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']" do
      assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", 1
    end

    task.update!(merged: Task::MERGED_MAIN)

    get deployments_path
    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']" do
      assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", 0,
                    "the accepted rung must drain when the stamp advances"
      assert_select "[data-test='app-ladder-parked'][data-branch='main']", 1,
                    "and the work must reappear on the rung it advanced to"
    end
  end

  test "a card needing attention is marked for the operator" do
    get deployments_path

    assert_response :success
    # not_built is not an attention state, so a bare board marks nothing.
    assert_select "[data-test='app-ladder-card'][data-attention='true']", 0
  end

  private

  def make_task(slug:, merged:, repos:, stage: "reviewed")
    words = slug.tr("-", " ").titleize.split
    words += %w[Ladder Fixture Task] while words.length < 3
    Task.create!(
      slug: slug,
      title: words.first(5).join(" "),
      stage: stage,
      merged: merged,
      metadata: { "devops" => { "repositories" => repos } }
    )
  end
end
