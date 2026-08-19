# frozen_string_literal: true

require "test_helper"

# The card partial in isolation: given a rung in each state, does the markup say so?
#
# This tier exists because the integration test can only assert what the live board
# happens to be in. Here we hand the partial each state directly — including the two
# that only appear under conditions a test database will not reproduce.
class AppLadderCardTest < ActionView::TestCase
  include ApplicationHelper

  test "renders one rung per ladder step with its state and sha" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green pending red]) }

    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']", 1
    assert_select "[data-test='app-ladder-rung']", 3
    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-state='green']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-state='pending']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-state='red']", 1
    assert_select "code", text: "abc1234"
  end

  # The two states that exist to stop a lie must reach the markup as themselves.
  test "a stale rung renders as stale and not as green" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[stale green green]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-state='stale']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-state='green']", 0
    assert_select "[data-test='app-ladder-rung'][data-branch='accepted']", text: /stale/
  end

  test "a not_built rung says so in words" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[not_built not_built not_built]) }

    assert_select "[data-test='app-ladder-rung'][data-state='not_built']", 3
    assert_select "[data-test='app-ladder-rung'][data-state='green']", 0
    assert_select "[data-test='app-ladder-card']", text: /not built/
  end

  test "a card marks itself for attention when a rung needs it" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[red green green]) }
    assert_select "[data-test='app-ladder-card'][data-attention='true']", 1

    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }
    assert_select "[data-test='app-ladder-card'][data-attention='false']", 1
  end

  test "parked work is shown only where there is some" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [3, 0, 0]) }

    assert_select "[data-test='app-ladder-parked']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='accepted']" do
      assert_select "[data-test='app-ladder-parked']", text: /3 parked/
    end
  end

  test "a rung with no sha omits the code element rather than printing a blank" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[not_built not_built not_built], sha: nil) }

    assert_select "code", 0
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
