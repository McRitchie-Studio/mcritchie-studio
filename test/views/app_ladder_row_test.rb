# frozen_string_literal: true

require "test_helper"

# The app-ladder ROW in isolation — since 2026-09-18 the APPLICATIONS SUMMARY CARD, the
# first of the four /deployments summary cards:
#
#   ONE LINE PER APP     emoji, name, the inline CI meter and its clock — in the order
#                        the caller hands in (Ci::AppLadder.recent_first on the page:
#                        newest suite restart first).
#   A SIDEBAR, NOT LINKS a click anywhere on the card opens the Applications sidebar;
#                        the full cards (and their GitHub links) live there.
#   A SCROLLING WELL     the list sits absolutely inside a flex-1 well, so it never sets
#                        the height of the summary row; the other three cards do.
#   NO PINNED STRIP      retired 2026-09-26 by the operator: nothing follows the page.
#
# The scroll itself is browser behaviour and is proved in e2e/app_ladder_row.spec.js.
# NAMED FOR ITS TIER, and that is not cosmetic: test/integration/app_ladder_row_test.rb
# already defines AppLadderRowTest under ActionDispatch::IntegrationTest. Each file passes
# alone, so the collision is invisible until something loads BOTH into one process —
# `bin/fast-check`, which maps a diff to its tests, does — and Ruby then raises
# `superclass mismatch for class AppLadderRowTest` from the second file to load.
# Same convention test/system/board_app_filter_test.rb follows (BoardAppFilterSystemTest).
class AppLadderRowViewTest < ActionView::TestCase
  include ApplicationHelper

  test "every application gets one line in the summary list, in the order handed in" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(4) }

    assert_select "[data-test='app-summary-card'] [data-test='app-summary-list'] > [data-test='app-summary-row']", 4
    rows = css_select("[data-test='app-summary-row']").map { |el| el["data-repo"] }
    assert_equal REPOS.first(4), rows, "the card never re-sorts — the order is the caller's (recent_first)"
    # No horizontal scroller and no full cards on the page's first line any more: those
    # moved to the sidebar (tasks/_app_ladder_detail).
    assert_select "[data-test='app-ladder-scroller']", 0
    assert_select "[data-test='app-ladder-card']", 0
  end

  # THE WHOLE CARD OPENS THE SIDEBAR on a click, through the shared summary-card
  # attributes (ApplicationHelper#deploy_summary_card_options); its heading is the real
  # button a keyboard or screen reader uses.
  test "the card opens the Applications sidebar" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(3) }

    card = css_select("[data-test='app-summary-card']").first
    assert_equal "openFrom($event, 'apps')", card["@click"]
    assert_select "[data-test='app-summary-card'] h3 button[data-test='summary-card-toggle'][aria-controls='deploy-sidebar-apps']", 1
    assert_select "[data-test='app-summary-card'] a", 0, "no row may be a link: a click means 'show me more'"
  end

  # THE LIST MAY NOT SET THE ROW'S HEIGHT. An in-flow list of twelve apps made the
  # Applications card the tallest of the four and stretched Releases and DevOps to
  # match. Laid absolutely inside a flex-1 well, the list contributes only the well's
  # min-height and scrolls past whatever height its siblings set.
  test "the list scrolls inside a well rather than growing the card" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(6) }

    well = css_select("[data-test='app-summary-card'] > [data-test='app-summary-well']").first
    refute_nil well, "the list must sit in a well that is a direct flex child of the card"
    well_classes = well["class"].split
    assert_includes well_classes, "flex-1", "the well fills what the row gives the card"
    assert_includes well_classes, "relative", "the list is positioned against the well"
    assert(well_classes.any? { |c| c.start_with?("min-h-") }, "a lone card still shows several apps")

    list_classes = css_select("[data-test='app-summary-well'] > [data-test='app-summary-list']").first["class"].split
    assert_includes list_classes, "absolute", "an in-flow list would size the row again"
    assert_includes list_classes, "inset-0"
    assert_includes list_classes, "overflow-y-auto"
    assert_includes css_select("[data-test='app-ladder-row']").first["class"].split, "h-full",
                    "the broadcast slot must pass the grid row's height down to the card"
  end

  # AN APP WITH NOTHING INGESTED GETS WORDS, never an empty rail reading "0 of 0".
  test "an app with no ingested CI says so instead of drawing an empty meter" do
    render partial: "tasks/app_ladder_row", locals: { cards: [card(%i[not_built not_built not_built])] }

    assert_select "[data-test='app-summary-row'] [data-test='app-summary-ci-empty']", text: "no CI ingested"
    assert_select "[data-test='app-summary-row'] [data-test='app-summary-ci']", 0
  end

  # THE STRIP IS RETIRED, and so is everything that armed it: the Alpine controller
  # that measured the scroll and the store it wrote.
  test "the row renders no pinned strip and no scroll controller" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(5) }

    assert_select "[data-test='app-ladder-pinned']", 0
    assert_select "[data-test='app-ladder-pinned-card']", 0
    assert_select "[data-pin='apps']", 0, "no layer may publish --pin-apps-* into the stack"
    assert_no_match(/appLadder|@scroll\.window/, rendered)
  end

  # The slot and the card stay — the summary row keeps its four cells — but there is
  # nothing to list.
  test "an empty ladder keeps the card and says so" do
    render partial: "tasks/app_ladder_row", locals: { cards: [] }

    assert_select "[data-test='app-ladder-row']", 1
    assert_select "[data-test='app-summary-card'] [data-test='app-summary-empty']", 1
    assert_select "[data-test='app-summary-row']", 0
    assert_select "[data-test='app-summary-well']", 0
  end

  private

  # Distinct repos, because the row keys its lines by repo and a
  # duplicate would hide a per-card bug behind an identical neighbour.
  REPOS = %w[turf-monster studio-engine solana-studio mcritchie-studio mcritchie-industries rolio].freeze

  def cards(count)
    REPOS.first(count).map { |repo| card(%i[green green green], repo: repo) }
  end

  def card(states, repo: "turf-monster", parked: [0, 0, 0], review_roll: nil, last_shipped_at: nil)
    rungs = Ci::AppLadder::RUNGS.each_with_index.map do |branch, i|
      Ci::LadderRung.new(repo: repo, branch: branch, state: states[i],
                         sha: "abc1234def", parked_count: parked[i])
    end
    Ci::AppLadder::Card.new(repo: repo, rungs: rungs, review_roll: review_roll,
                            last_shipped_at: last_shipped_at)
  end
end
