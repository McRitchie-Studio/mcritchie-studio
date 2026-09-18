# frozen_string_literal: true

require "test_helper"

# The app-ladder ROW in isolation — since 2026-09-18 the APPLICATIONS SUMMARY CARD, the
# first of the four /deployments summary cards, plus the pinned strip it carries:
#
#   ONE LINE PER APP     emoji, name, the inline CI meter and its clock — in the order
#                        the caller hands in (Ci::AppLadder.recent_first on the page:
#                        newest suite restart first).
#   A SIDEBAR, NOT LINKS a click anywhere on the card opens the Applications sidebar;
#                        the full cards (and their GitHub links) live there.
#   THE PINNED STRIP     the same applications, condensed to three rows, ready to fix
#                        under the site header once the card scrolls off — with its own
#                        measured fade, seeded server-side at Ci::AppLadder::ROW_FADE_AT.
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
  # button a keyboard or screen reader uses. And the card is the element the pinned
  # strip measures against (x-ref="row").
  test "the card opens the Applications sidebar and is what the strip measures" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(3) }

    card = css_select("[data-test='app-summary-card']").first
    assert_equal "openFrom($event, 'apps')", card["@click"]
    assert_equal "row", card["x-ref"], "the strip pins when THIS card leaves the screen"
    assert_select "[data-test='app-summary-card'] h3 button[data-test='summary-card-toggle'][aria-controls='deploy-sidebar-apps']", 1
    assert_select "[data-test='app-summary-card'] a", 0, "no row may be a link: a click means 'show me more'"
  end

  # AN APP WITH NOTHING INGESTED GETS WORDS, never an empty rail reading "0 of 0".
  test "an app with no ingested CI says so instead of drawing an empty meter" do
    render partial: "tasks/app_ladder_row", locals: { cards: [card(%i[not_built not_built not_built])] }

    assert_select "[data-test='app-summary-row'] [data-test='app-summary-ci-empty']", text: "no CI ingested"
    assert_select "[data-test='app-summary-row'] [data-test='app-summary-ci']", 0
  end

  # THE FADE LIVES ON THE STRIP NOW — the only part of this slot that still scrolls
  # sideways. Seeded at the count that cannot fit, so the first paint is right.
  # ONE RENDER PER TEST, deliberately: ActionView::TestCase accumulates `rendered`
  # across renders inside a single test.
  test "the strip's fade is seeded on at the count that cannot fit" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(Ci::AppLadder::ROW_FADE_AT) }

    assert_select "[data-test='app-ladder-pinned-scroller'][data-faded='true']", 1
    assert_match(/pinnedOverflowing: true/, rendered, "five tiles cannot fit — seed the fade on")
  end

  test "a strip that fits is seeded with no fade at all" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(Ci::AppLadder::ROW_FADE_AT - 1) }

    assert_select "[data-test='app-ladder-pinned-scroller'][data-faded='true']", 0
    assert_match(/pinnedOverflowing: false/, rendered, "four tiles fit — do not promise more")
  end

  # A MASK, NOT AN OVERLAY. An overlay must be painted in the page's background colour —
  # a claim about what sits behind the tiles, and one more thing to keep in step with
  # both themes. It would also sit over the tiles and have to be made click-through.
  test "the strip's fade masks the strip itself rather than painting over it" do
    render partial: "tasks/app_ladder_row", locals: { cards: cards(5) }

    scroller = css_select("[data-test='app-ladder-pinned-scroller']").first
    assert_equal ApplicationHelper::APP_LADDER_FADE_MASK, scroller["style"]
    assert_equal "(pinnedOverflowing && !pinnedAtEnd) ? fadeRight : ''", scroller[":style"],
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
    # THE STATE LIVES IN A STORE, not on this component. The row is replaced
    # wholesale by DeploymentsBroadcaster.app_ladder, and a component-local
    # `pinned: false` is rebuilt as false on every broadcast — so the strip blinks
    # out and back while the page has not moved. A store outlives the node.
    assert_equal "$store.appLadder.pinned", strip["x-show"]
    assert_includes strip["style"].to_s, "display: none"
  end

  # A DOUBLE QUOTE ANYWHERE IN THE x-data ATTRIBUTE KILLS THE COMPONENT.
  #
  # x-data is delimited by double quotes, so one inside the expression — INCLUDING
  # inside a `//` comment, which is the case that actually shipped — ends the
  # attribute early. Alpine then never parses the component, and the page reports
  # a bare `SyntaxError: Unexpected token ')'` plus `overflowing is not defined`,
  # nowhere near the quote.
  #
  # WHY THIS IS A TEST AND NOT A NOTE. Every other assertion in this file reads
  # SOURCE, and source-reading assertions are all still green with the component
  # dead: the markup is byte-identical whether Alpine ever evaluated it. This one
  # was caught by a browser, on a stack booted to check something else. The rule is
  # cheap to state and impossible to remember, so it is stated here instead.
  #
  # Scoped to the x-data BODY, so the ordinary quotes that delimit the attribute
  # and the other attributes on the element are untouched.
  test "the x-data expression contains no double quote, which would end the attribute" do
    source = Rails.root.join("app/views/tasks/_app_ladder_row.html.erb").read
    body = source[/x-data="\{(.*?)\n\s*\}"/m, 1]

    refute_nil body, "could not isolate the x-data expression — re-anchor this guard"
    offending = body.lines.each_with_index.select { |line, _| line.include?('"') }

    assert_empty offending.map { |line, i| "line #{i + 1}: #{line.strip}" },
                 "a double quote inside x-data ends the attribute early and Alpine never " \
                 "parses the component; use single quotes, or reword the comment"
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
    assert_match(/top:\s*var\(--pin-apps-top/, strip["style"].to_s,
                 "the strip must take its top from the published edge, never a measured number — " \
                 "and from its OWN place in the stack (the edge of everything above it), not " \
                 "from a layer it happens to know the name of")
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

  # The slot and the card stay — the summary row keeps its four cells — but there is
  # nothing to list and nothing to pin.
  test "an empty ladder keeps the card, says so, and renders no strip" do
    render partial: "tasks/app_ladder_row", locals: { cards: [] }

    assert_select "[data-test='app-ladder-row']", 1
    assert_select "[data-test='app-summary-card'] [data-test='app-summary-empty']", 1
    assert_select "[data-test='app-summary-row']", 0
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
