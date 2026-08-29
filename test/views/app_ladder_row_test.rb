# frozen_string_literal: true

require "test_helper"

# The app-ladder ROW in isolation — the frame around the cards, which is where the
# operator's three asks live:
#
#   ONE SCROLLING LINE   every card in a single horizontal track, never a wrapping
#                        grid whose height grows with the ecosystem.
#   A MEASURED FADE      a right-edge gradient that says "there is more", seeded
#                        server-side at Ci::AppLadder::ROW_FADE_AT so the first paint
#                        is right before Alpine measures anything.
#   THE PINNED STRIP     the same applications, condensed to three rows, ready to fix
#                        under the site header once the row scrolls off.
#
# The pinning itself is browser behaviour and is proved in e2e/app_ladder_row.spec.js.
# What this tier proves is that the strip is RENDERED, carries every app, and carries
# only the three rows it promises — a strip that quietly grew a fourth row would push
# the board down on every scroll, and no server-side assertion elsewhere would notice.
# NAMED FOR ITS TIER, and that is not cosmetic: test/integration/app_ladder_row_test.rb
# already defines AppLadderRowTest under ActionDispatch::IntegrationTest. Each file passes
# alone, so the collision is invisible until something loads BOTH into one process —
# `bin/fast-check`, which maps a diff to its tests, does — and Ruby then raises
# `superclass mismatch for class AppLadderRowTest` from the second file to load.
# Same convention test/system/board_app_filter_test.rb follows (BoardAppFilterSystemTest).
class AppLadderRowViewTest < ActionView::TestCase
  include ApplicationHelper

  test "every card sits in one horizontal scroller rather than a wrapping grid" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(4) }

    assert_select "[data-test='app-ladder-scroller']", 1
    assert_select "[data-test='app-ladder-scroller'].overflow-x-auto", 1
    assert_select "[data-test='app-ladder-scroller'] > [data-test='app-ladder-card']", 4
    assert_select "[data-test='app-ladder-scroller'].grid", 0, "the row must not wrap onto a second line"
  end

  # A card that shrinks to fit would defeat the row: five apps would simply become five
  # narrower cards and nothing would ever scroll.
  test "cards keep their width instead of shrinking to fit the row" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(6) }

    assert_select "[data-test='app-ladder-card'].shrink-0", 6
  end

  # THE FADE IS A CLAIM ABOUT CONTENT OFF-SCREEN. Below the threshold the row fits, so
  # the first paint must not draw one — the browser corrects the reading within a frame,
  # and a fade over a row with nothing behind it is a promise it cannot keep.
  # ONE RENDER PER TEST, deliberately: ActionView::TestCase accumulates `rendered`
  # across renders inside a single test, so the second pass would still be selecting
  # the first pass's markup.
  test "the fade is seeded on at the count that cannot fit" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(Ci::AppLadder::ROW_FADE_AT) }

    assert_select "[data-test='app-ladder-scroller'][data-faded='true']", 1
    assert_match(/overflowing: true/, rendered, "five cards cannot fit — seed the fade on")
  end

  test "a row that fits is seeded with no fade at all" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(Ci::AppLadder::ROW_FADE_AT - 1) }

    assert_select "[data-test='app-ladder-scroller'][data-faded='true']", 0
    assert_match(/overflowing: false/, rendered, "four cards fit — do not promise more")
  end

  # A MASK, NOT AN OVERLAY. An overlay must be painted in the page's background colour —
  # a claim about what sits behind the cards, and one more thing to keep in step with
  # both themes. It would also sit over the cards and have to be made click-through.
  test "the fade masks the row itself rather than painting over it" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(5) }

    scroller = css_select("[data-test='app-ladder-scroller']").first
    assert_equal ApplicationHelper::APP_LADDER_FADE_MASK, scroller["style"]
    assert_equal "(overflowing && !atEnd) ? fadeRight : ''", scroller[":style"],
                 "the browser's own measurement owns the fade after the first paint"
  end

  # --- the pinned strip -----------------------------------------------------

  test "the row renders a pinned strip carrying every application" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(5) }

    assert_select "[data-test='app-ladder-pinned']", 1
    assert_select "[data-test='app-ladder-pinned'] [data-test='app-ladder-pinned-card']", 5
  end

  # NOTHING IS PINNED UNTIL SOMETHING MEASURED. `style="display: none"` is the pre-init
  # and no-JS state; without it the strip paints over the board on first load and a
  # browser with JS off could never scroll out from under it.
  test "the strip stays hidden until the row has actually scrolled off" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(5) }

    strip = css_select("[data-test='app-ladder-pinned']").first
    assert_equal "pinned", strip["x-show"]
    assert_includes strip["style"].to_s, "display: none"
  end

  # THE HEADER IS z-50 AND MUST ALWAYS WIN. A strip that outranks the nav pins itself
  # over the site header the moment the two meet.
  test "the strip sits under the site header rather than over it" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(5) }

    assert_select "[data-test='app-ladder-pinned'].fixed.z-40", 1

    strip = css_select("[data-test='app-ladder-pinned']").first

    # NOT HARD-CODED, AND NOT MEASURED EITHER. The offset used to be an Alpine
    # bind writing a number this component read off the header itself — which is
    # what made the strip chase the header through every intermediate height of
    # its collapse, a frame behind, for the whole 300ms ease (task
    # stop-headers-chasing-navbar). The engine publishes the header's live bottom
    # edge, so the strip positions off THAT, in CSS, with nothing to lag.
    assert_match(/top:\s*var\(--pin-nav-bottom/, strip["style"].to_s,
                 "the strip must take its top from the published edge, never a measured number")
    assert_nil strip[":style"],
               "an Alpine style bind would fight the CSS and reintroduce the frame of lag"

    # AND x-show'S DISPLAY MUST SURVIVE IT. This was the reason the old bind had
    # to use Alpine's OBJECT form: the string form calls setAttribute("style", …)
    # and replaces the whole attribute, including the `display: none` x-show
    # wrote, unhiding the strip over the board. A STATIC style attribute is not
    # exposed to that at all — x-show sets the display property and leaves the
    # rest standing. Verified in a browser: toggling display none/block leaves
    # top at the published edge both ways.
    assert_includes strip["style"].to_s, "display: none",
                    "the strip still starts hidden, and its top must not disturb that"
  end

  # THREE ROWS AND NO FOURTH — the operator's own spec for the pinned form.
  test "a pinned card keeps the name, the CI meter and the ladder" do
    render partial: "tasks/app_ladder_row", locals: { cards: [card(%i[green pending green], repo: "turf-monster")] }

    assert_select "[data-test='app-ladder-pinned-card'][data-repo='turf-monster']", 1
    assert_select "[data-test='app-ladder-pinned-name']", text: "turf-monster"
    assert_select "[data-test='app-ladder-pinned-ci']", 1
    assert_select "[data-test='app-ladder-pinned-card'] [data-test='app-ladder-rung']", 3

    branches = css_select("[data-test='app-ladder-pinned-card'] [data-test='app-ladder-rung']")
               .map { |el| el["data-branch"] }
    assert_equal %w[accepted release main], branches
  end

  test "a pinned card drops everything the full card carries below those three rows" do
    render partial: "tasks/app_ladder_row",
           locals: { cards: [card(%i[green green green], parked: [2, 0, 0],
                                  review_roll: roll(average_seconds: 600, sample: 10, scanned: 10))] }

    pinned = css_select("[data-test='app-ladder-pinned']").first.to_s
    assert_no_match(/app-ladder-review/, pinned, "the review roll is board history, not live news")
    assert_no_match(/app-ladder-position/, pinned, "the position word is a fourth row")
    assert_no_match(/app-ladder-at-rest/, pinned)
    assert_no_match(/app-ladder-parked/, pinned, "a parked count is the first thing to overflow a tile")
  end

  # A RESTING APP KEEPS ITS METER HERE, unlike on the full card. The at-rest collapse
  # quiets a card the operator is scrolling PAST; this strip is what they kept, and a
  # tile with a hole where the meter goes reads as broken rather than as calm.
  test "a resting application still shows its meter in the strip and dims instead" do
    render partial: "tasks/app_ladder_row", locals: { cards: [card(%i[not_built not_built not_built])] }

    assert_select "[data-test='app-ladder-pinned-card'][data-at-rest='true'].opacity-60", 1
    assert_select "[data-test='app-ladder-pinned-card'] [data-test='app-ladder-pinned-ci']", 1
  end

  test "an empty ladder renders neither a row nor a strip" do
    render partial: "tasks/app_ladder_row", locals: { cards: [] }

    assert_select "[data-test='app-ladder-row']", 1
    assert_select "[data-test='app-ladder-scroller']", 0
    assert_select "[data-test='app-ladder-pinned']", 0
  end

  private

  # Distinct repos, because the strip and the row both key their tiles by repo and a
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

  def roll(average_seconds:, sample:, scanned:)
    Review::DurationRoll::Roll.new(repo: "turf-monster", average_seconds: average_seconds,
                                   sample: sample, scanned: scanned)
  end
end
