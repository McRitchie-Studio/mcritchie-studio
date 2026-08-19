# frozen_string_literal: true

require "test_helper"

# The card partial in isolation: the suite strip renders accepted → release → main as
# three badges, and each state reaches the markup as itself.
#
# This tier exists because the integration test can only assert what the live board
# happens to be in. Here we hand the partial each state directly — including the two
# that a test database will not reproduce on its own.
class AppLadderCardTest < ActionView::TestCase
  include ApplicationHelper

  test "the suite strip renders the three rungs left to right" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green pending red]) }

    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']", 1
    assert_select "[data-test='app-ladder-suite']", 1
    assert_select "[data-test='app-ladder-rung']", 3

    branches = css_select("[data-test='app-ladder-rung']").map { |el| el["data-branch"] }
    assert_equal %w[accepted release main], branches, "the strip must read up the ladder"
  end

  test "each rung carries its own state" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green pending red]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-state='green']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-state='pending']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-state='red']", 1
  end

  # The colour vocabulary the operator reads: amber in flight, emerald settled green,
  # rose settled bad, faded when not verified.
  test "a running rung is amber and carries a spinner" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[pending pending pending]) }

    assert_select "[data-test='app-ladder-rung'][data-state='pending'] [data-test='app-ladder-rung-fill'].bg-amber-500", 3
    assert_select "[data-test='app-ladder-rung'][data-state='pending'] svg.animate-spin", 3
  end

  test "a verified rung is emerald and carries a check" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-rung'][data-state='green'] [data-test='app-ladder-rung-fill'].bg-emerald-500", 3
    assert_select "[data-test='app-ladder-rung'][data-state='green'] svg.animate-spin", 0
  end

  test "a failed rung is rose" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[red green green]) }

    assert_select "[data-test='app-ladder-rung'][data-state='red'] [data-test='app-ladder-rung-fill'].bg-rose-500", 1
  end

  # THE HONESTY CONTRACT. A stale verdict describes a tree that is no longer the tree,
  # so it must not be painted as a pass — it renders faded, exactly like never-built,
  # and says why on hover.
  test "a stale rung renders faded rather than green" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[stale green green]) }

    stale = css_select("[data-test='app-ladder-rung'][data-branch='accepted']").first
    assert_equal "stale", stale["data-state"]

    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'] [data-test='app-ladder-rung-fill'].bg-emerald-500", 0,
                  "a stale rung must never wear the verified fill"
    assert_match(/NOT verified/, stale["title"])
  end

  test "a not_built rung renders faded and says no verdict was ingested" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[not_built not_built not_built]) }

    assert_select "[data-test='app-ladder-rung'][data-state='not_built']", 3
    assert_select "[data-test='app-ladder-rung-fill'].bg-emerald-500", 0
    assert_select "[data-test='app-ladder-rung-fill'].bg-amber-500", 0

    titles = css_select("[data-test='app-ladder-rung']").map { |el| el["title"] }
    assert titles.all? { |t| t.include?("no CI verdict ingested") }, titles.inspect
  end

  test "a card marks itself for attention when a rung needs it" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[red green green]) }
    assert_select "[data-test='app-ladder-card'][data-attention='true']", 1

    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }
    assert_select "[data-test='app-ladder-card'][data-attention='false']", 1
  end

  test "parked work shows per rung and only where there is some" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [3, 0, 1]) }

    assert_select "[data-test='app-ladder-parked']", 2
    assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", text: /3 on accepted/
    assert_select "[data-test='app-ladder-parked'][data-branch='main']", text: /1 on main/
    assert_select "[data-test='app-ladder-parked'][data-branch='release']", 0
  end

  test "a card with no parked work omits the row entirely" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-parked-row']", 0
  end

  test "the strip carries one spelled-out summary for assistive tech" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green pending not_built]) }

    strip = css_select("[data-test='app-ladder-suite']").first
    assert_equal "group", strip["role"]
    assert_match(/turf-monster test suite/, strip["aria-label"])
    assert_match(/accepted green/, strip["aria-label"])
    assert_match(/release pending/, strip["aria-label"])
    assert_match(/main not built/, strip["aria-label"])
  end

  test "the gem card is labelled distinctly from an app card" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], repo: "studio-engine") }
    assert_select "[data-test='app-ladder-card']", text: /gem/

    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }
    assert_select "[data-test='app-ladder-card']", text: /app/
  end

  private

  def card(states, repo: "turf-monster", parked: [0, 0, 0], sha: "abc1234def")
    rungs = Ci::AppLadder::RUNGS.each_with_index.map do |branch, i|
      Ci::LadderRung.new(repo: repo, branch: branch, state: states[i],
                         sha: sha, parked_count: parked[i])
    end
    Ci::AppLadder::Card.new(repo: repo, rungs: rungs)
  end
end
