# frozen_string_literal: true

require "test_helper"

# The card partial in isolation: the TRACK renders accepted → release → main as one
# connected path, and each state reaches the markup as itself.
#
# THE TRACK CARRIES TWO INDEPENDENT FACTS PER NODE and most of the tests below exist
# to keep them from collapsing back into one:
#
#   data-state    — CI's verdict for that rung (green/pending/red/not_built), drawn as
#                   the GLYPH inside the segment
#   data-progress — where the work is: passed / here / unreached, drawn as the COLOUR
#
# The badge row this replaced spent its only channel on the first, so it could say
# "release is green" but never "release is empty". A green-and-empty `release` is simply
# what a repo looks like between sweeps, and being unable to draw it is why the row
# could not answer "where is this app in the devops process".
#
# This tier exists because the integration test can only assert what the live board
# happens to be in. Here we hand the partial each state directly — including the two
# that a test database will not reproduce on its own.
class AppLadderCardTest < ActionView::TestCase
  include ApplicationHelper

  test "the track renders the three rungs left to right" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green pending red]) }

    assert_select "[data-test='app-ladder-card'][data-repo='turf-monster']", 1
    assert_select "[data-test='app-ladder-suite']", 1
    assert_select "[data-test='app-ladder-rung']", 3

    branches = css_select("[data-test='app-ladder-rung']").map { |el| el["data-branch"] }
    assert_equal %w[accepted release main], branches, "the track must read up the ladder"
  end

  test "each rung carries its own state" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green pending red]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-state='green']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-state='pending']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-state='red']", 1
  end

  # --- the glyph: WHAT CI SAID ---------------------------------------------
  #
  # CI used to own the segment's COLOUR; it now owns the glyph inside it, and colour
  # went to progress. Every test here pins one against the other so the two channels
  # cannot quietly re-merge.

  test "a running rung carries a spinner whatever the work has done" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[pending pending pending]) }

    assert_select "[data-test='app-ladder-rung'][data-state='pending'] svg.animate-spin", 3
  end

  test "a verified rung carries a check and never a spinner" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-rung'][data-state='green'] svg", 3
    assert_select "[data-test='app-ladder-rung'][data-state='green'] svg.animate-spin", 0
  end

  # THE REGRESSION, in its new home. A green rung is drawn green — it used to render
  # faded whenever a task had been stamped after the run started, which is always.
  # Measured in production 2026-08-20: turf-monster release, green@e1217b6, badge
  # faded, 47s apart. A LEVEL card is the case that reads green end to end.
  test "a green rung renders green and never faded" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-rung'][data-state='green']", 3
    assert_select "[data-test='app-ladder-rung'] [data-test='app-ladder-rung-fill'].bg-emerald-500", 3
    assert_select "[data-test='app-ladder-rung'][data-state='stale']", 0
  end

  # THE GLYPH IS THE VERDICT AND NOTHING ELSE. Rendered on a level card so progress is
  # constant across all three rungs and only CI can move the glyph.
  test "the glyph agrees with the verdict it was given" do
    { green: "svg", pending: "svg.animate-spin", red: "svg" }.each do |state, selector|
      render partial: "tasks/app_ladder_card", locals: { card: card([state, state, state]) }

      # SCOPED BY STATE. ActionView::TestCase accumulates `rendered` across renders in
      # one test, so an unscoped count grows each pass; scoping to the state keeps each
      # iteration reading only its own markup.
      assert_select "[data-test='app-ladder-rung'][data-state='#{state}']", 3
      assert_select "[data-test='app-ladder-rung'][data-state='#{state}'] #{selector}", 3,
                    "#{state} must carry its own glyph"
    end
  end

  # AN ABSENCE MUST NEVER WEAR THE PASS GLYPH. `not_built` draws NO icon at all — it is
  # the one state with nothing to say, and a tick there would assert a verification
  # nobody performed.
  test "a not_built rung draws no glyph and says no verdict was ingested" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[not_built not_built not_built]) }

    assert_select "[data-test='app-ladder-rung'][data-state='not_built']", 3
    assert_select "[data-test='app-ladder-rung'] svg", 0

    titles = css_select("[data-test='app-ladder-rung']").map { |el| el["title"] }
    assert titles.all? { |t| t.include?("no CI verdict ingested") }, titles.inspect
  end

  # --- the colour: WHERE THE WORK IS ---------------------------------------
  #
  # The half the badge row could not draw. Every test here holds all three rungs at ONE
  # CI state, so only the PROGRESS can move — which is the point of splitting them.
  #
  # The three states the operator chose:
  #   amber  :here       work is sitting on this rung right now
  #   green  :passed     it moved through (at `main`, it arrived)
  #   faded  :unreached  it has not got this far

  test "work merged onto accepted colours that rung and nothing beyond it" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [2, 0, 0]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-progress='here']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-progress='unreached']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-progress='unreached']", 1
    assert_select "[data-test='app-ladder-rung'][data-progress='here'] [data-test='app-ladder-rung-fill'].bg-amber-500", 1
  end

  test "promotion turns the rung behind the work green and lights the candidate" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [0, 4, 0]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-progress='passed']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-progress='here']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-progress='unreached']", 1
  end

  # PARKED WORK WINS OVER THE FRONTIER, and this is the case a plain "fill up to the
  # frontier" rule gets wrong. An app routinely holds work at `accepted` AND at
  # `release` at once; colouring `accepted` green there would say "this rung is clear"
  # over two tasks still sitting on it.
  test "a rung holding work stays amber even when the frontier moved past it" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [2, 4, 0]) }

    assert_select "[data-test='app-ladder-card'][data-furthest='release']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='accepted'][data-progress='here'][data-parked='2']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-progress='here'][data-parked='4']", 1
  end

  # Nothing parked anywhere means everything ARRIVED — `main` is absent from
  # PARKED_STAMP on purpose — so the whole bar is green.
  test "a level repo reads as three greens" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-card'][data-furthest='main']", 1
    assert_select "[data-test='app-ladder-rung'][data-progress='passed']", 3
    assert_select "[data-test='app-ladder-rung'] [data-test='app-ladder-rung-fill'].bg-emerald-500", 3
  end

  # `main` IS ARRIVAL, NOT WAITING — nothing ever parks there, so reaching it reads
  # :passed. Were it :here, a fully drained app would end on an amber rung, which says
  # "still going" about work that has shipped.
  test "reaching main reads as arrival rather than as work waiting there" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-progress='here']", 0
    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-progress='passed']", 1
  end

  # COLOUR AND VERDICT ARE TWO FACTS. An uncoloured rung whose CI is green reads
  # "passing and empty", which is what `release` looks like between sweeps — precisely
  # what one channel could never say.
  test "a rung can be green in CI and unreached at the same time" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [1, 0, 0]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='release'][data-state='green'][data-progress='unreached']", 1
    assert_select "[data-test='app-ladder-rung'][data-branch='release'] [data-test='app-ladder-rung-fill'].bg-emerald-500", 0,
                  "an empty rung must not wear the passed-through colour"
  end

  # RED IS THE ONE THING LOUD ENOUGH TO TAKE THE COLOUR BACK OFF PROGRESS — a failing
  # rung must be actionable before anything else moves, not legible only as a glyph.
  test "a failing rung goes rose whatever the work has done" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green red], parked: [3, 0, 0]) }

    assert_select "[data-test='app-ladder-rung'][data-branch='main'][data-progress='unreached'][data-state='red']" do
      assert_select "[data-test='app-ladder-rung-fill'].bg-rose-500", 1
    end
  end

  # --- position and the at-rest collapse ------------------------------------

  test "a card names its position in the devops process" do
    {
      [%i[green green green], { parked: [0, 0, 0] }] => "at rest",
      [%i[green green green], { parked: [2, 0, 0] }] => "queued",
      [%i[green green green], { release_member: true }] => "in release",
      [%i[red green green], { }] => "needs attention"
    }.each do |(states, opts), label|
      render partial: "tasks/app_ladder_card", locals: { card: card(states, **opts) }
      assert_select "[data-test='app-ladder-position']", text: label
    end
  end

  # `:queued` means "holds work outside the open release", and that work can sit on
  # EITHER counted rung. Quoting the ACCEPTED count would print "0 tasks waiting" for a
  # repo carrying release stamps with no candidate behind them.
  test "the queued sentence names the rung the work is actually on" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [0, 3, 0]) }

    assert_select "[data-test='app-ladder-position'][title='3 tasks waiting on release']", 1
  end

  # THE BLUE-BOX ASK: after a release, an app that is not in the next one recedes.
  # It dims, drops its meter, and keeps ONE fact — when it last reached production.
  test "an at-rest card dims and collapses to a single shipped line" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], last_shipped_at: 3.hours.ago) }

    assert_select "[data-test='app-ladder-card'][data-at-rest='true'][data-position='at_rest']", 1
    assert_select "[data-test='app-ladder-card'].opacity-60", 1
    assert_select "[data-test='app-ladder-ci']", 0, "a resting card drops its meter"
    assert_select "[data-test='app-ladder-at-rest']", 1
    assert_select "[data-test='app-ladder-shipped']", text: "shipped 3h ago"
  end

  # A DIMMED CARD SAYING NOTHING AT ALL is indistinguishable from a broken one, so the
  # collapsed line always carries a statement — even when the last ship predates the
  # scanned window and there is no timestamp to show.
  test "a resting card with no recorded ship still says shipped rather than nothing" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-shipped']", text: "shipped"
  end

  # THE SAFETY RULE, both halves. Dimming a card is a CLAIM that nothing here needs
  # attention; a red rung or a suite mid-run contradicts it, so neither ever rests.
  test "a failing card never rests however quiet the board looks" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[red green green]) }

    assert_select "[data-test='app-ladder-card'][data-at-rest='false']", 1
    assert_select "[data-test='app-ladder-ci-empty'], [data-test='app-ladder-ci']", 1,
                  "a failing card keeps its meter"
  end

  # A running suite is LIVE NEWS — the one state the meter exists to show moving — so
  # a card must never dim itself over its own in-flight CI.
  test "a card with a suite in flight never rests" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green pending green]) }

    assert_select "[data-test='app-ladder-card'][data-at-rest='false']", 1
    assert_select "[data-test='app-ladder-at-rest']", 0
  end

  # An app IN the open candidate is live work, not residue — however empty its rungs.
  test "a release member never rests" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], release_member: true) }

    assert_select "[data-test='app-ladder-card'][data-at-rest='false'][data-position='in_release']", 1
    assert_select "[data-test='app-ladder-at-rest']", 0
  end

  test "a card marks itself for attention when a rung needs it" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[red green green]) }
    assert_select "[data-test='app-ladder-card'][data-attention='true']", 1

    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }
    assert_select "[data-test='app-ladder-card'][data-attention='false']", 1
  end

  # THE PARKED FOOTNOTE NOW RIDES THE SEGMENT IT DESCRIBES. It used to be the smallest
  # text on the card, saying "1 on release" beneath a `release` badge that could not
  # show it.
  test "parked work shows per rung and only where there is some" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [3, 1, 0]) }

    assert_select "[data-test='app-ladder-parked']", 2, "only the rungs holding work carry a count"
    assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", text: "3"
    assert_select "[data-test='app-ladder-parked'][data-branch='release']", text: "1"
    assert_select "[data-test='app-ladder-parked-row']", 0, "the separate footnote row is gone"
  end

  # `main` NEVER CARRIES A COUNT. Nothing parks there — shipped work has left the
  # ladder — so a number on it would be a claim about work that is no longer waiting.
  test "main never carries a parked count" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [0, 0, 0]) }

    assert_select "[data-test='app-ladder-parked'][data-branch='main']", 0
    assert_select "[data-test='app-ladder-parked']", 0
  end

  # THE CLEAN SLATE the operator asked for: once a deployment is done and nothing is
  # waiting below main, the card says nothing at all rather than carrying a permanent
  # "37 on main" that never drains.
  test "a fully shipped repo renders a quiet card" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [0, 0, 0]) }

    assert_select "[data-test='app-ladder-node-note'][data-branch='accepted']", 0
    assert_select "[data-test='app-ladder-node-note'][data-branch='release']", 0
  end

  # The summary LEADS WITH POSITION, because that is what the track draws. A reader who
  # cannot see the fill would otherwise get three CI verdicts and no idea where the
  # work is — the exact gap the badge row had on screen.
  test "the track carries one spelled-out summary for assistive tech" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green pending not_built], parked: [2, 0, 0]) }

    strip = css_select("[data-test='app-ladder-suite']").first
    assert_equal "group", strip["role"]
    assert_match(/turf-monster/, strip["aria-label"])
    assert_match(/2 tasks waiting on accepted/, strip["aria-label"])
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


  # --- the card as a link to the Actions run -------------------------------

  # The operator asked to click a card and land on the run. A card with a run renders
  # as an <a>; one without degrades to a <div> rather than a dead link — the same rule
  # tasks/_release_phase_meter follows.
  test "a card with a run is a link to it and opens in a new tab" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[pending green green], run_url: "https://github.com/o/r/actions/runs/42") }

    assert_select "a[data-test='app-ladder-card'][data-linked='true']", 1
    assert_select "a[href='https://github.com/o/r/actions/runs/42'][target='_blank'][rel='noopener']", 1
  end

  test "a card with no run is a plain div rather than a dead link" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[not_built not_built not_built]) }

    assert_select "a[data-test='app-ladder-card']", 0
    assert_select "div[data-test='app-ladder-card'][data-linked='false']", 1
  end

  # --- the CI meter ---------------------------------------------------------

  # An app with nothing ingested must not draw an empty rail that reads as
  # "0 of 0 passed" — absence gets said in words instead.
  #
  # `release_member: true` keeps this card OFF the at-rest path, which replaces the
  # meter wholesale; the companion test below covers what a resting suiteless card
  # says instead.
  test "a card with no ingested checks says so instead of drawing an empty meter" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[not_built not_built not_built], release_member: true) }

    assert_select "[data-test='app-ladder-ci-empty']", 1
    assert_select "[data-test='app-ladder-ci']", 0
  end

  # A RESTING SUITELESS CARD STILL SAYS "not built" — on its track, where the three
  # faded nodes carry it. Only the prose notice goes, along with the meter it explains.
  # Ci::AppLadder deliberately draws a card for a repo that declares no suite ("a card
  # reading not built is a true statement; an absent card says nothing at all"), and
  # the at-rest collapse must not quietly undo that.
  test "a resting suiteless card drops the meter notice but keeps not_built on the track" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[not_built not_built not_built]) }

    assert_select "[data-test='app-ladder-card'][data-at-rest='true']", 1
    assert_select "[data-test='app-ladder-ci-empty']", 0
    assert_select "[data-test='app-ladder-rung'][data-state='not_built']", 3
  end


  # --- naming what each half counts ----------------------------------------

  # The fix for the meter/badge contradiction: rather than force two deliberately
  # different scopes to agree, the card SAYS what each one counts. A red sibling lane
  # is named here instead of hiding behind a green meter.
  #
  # Ci::LadderRung is a FROZEN value object, so these use a double rather than a stub.
  FakeRung = Struct.new(:branch, :state, :short_sha, :parked_count, :counted_lane,
                        :uncounted_lanes, :progress, :run_url, :verdict_at, keyword_init: true) do
    def label = state.to_s
    def needs_attention? = false
  end

  # `release_member: true` is not incidental. A card that is level, quiet and outside
  # the release is AT REST, and a resting card drops its meter — so the sibling-lane
  # row, which exists to name what that meter leaves out, would have nothing to sit
  # under. A repo whose lanes you are inspecting is by definition one in flight.
  def fake_card(repo:, counted:, uncounted:)
    rungs = Ci::AppLadder::RUNGS.map do |b|
      FakeRung.new(branch: b, state: :green, short_sha: "abc1234", parked_count: 0,
                   counted_lane: counted, uncounted_lanes: uncounted, progress: nil,
                   run_url: nil, verdict_at: Time.current)
    end
    card = Ci::AppLadder::Card.new(repo: repo, rungs: rungs, release_member: true)
    card.define_singleton_method(:progress) { nil }
    card
  end

  test "a lane the meter does not count is named on the card with its state" do
    card = fake_card(repo: "studio-engine", counted: "Engine CI",
                     uncounted: [{ name: "Consumer CI", state: :red, url: nil }])

    render partial: "tasks/app_ladder_card", locals: { card: card }

    assert_select "[data-test='app-ladder-other-lanes']", 1
    assert_select "[data-test='app-ladder-other-lane'][data-lane='Consumer CI'][data-state='red']", 1
    assert_select "[data-test='app-ladder-other-lane']", text: /Consumer CI/
  end

  # An app runs one lane, so its card gains no extra line to read.
  test "a single lane repo shows no other-lanes row" do
    card = fake_card(repo: "turf-monster", counted: "CI", uncounted: [])

    render partial: "tasks/app_ladder_card", locals: { card: card }

    assert_select "[data-test='app-ladder-other-lanes']", 0
  end

  # --- the review roll ------------------------------------------------------
  #
  # The card carries TWO minute-figures now — the CI meter's run clock and this
  # rolling review average — and the operator must never read one as the other.
  # These tests pin what keeps them apart, and pin the states a quiet repo lands in,
  # because four of the five live cards had fewer than ten usable reviews the day
  # this shipped.

  test "a full rolling ten shows the average and what it excluded" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green],
                                review_roll: roll(average_seconds: 12 * 60, sample: 10, scanned: 13)) }

    assert_select "[data-test='app-ladder-review']", 1
    assert_select "[data-test='app-ladder-review-value']", text: "12m avg"
    assert_select "[data-test='app-ladder-review-note']", text: "3 of 13 excluded"
  end

  # THE EXCLUDED COUNT IS NOT OPTIONAL — the 60-minute cut does real work, so a bare
  # average would be a claim with its evidence hidden. Zero shows too: "0 of 10
  # excluded" is the statement that this average is clean.
  test "a clean window still reports its excluded count" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green],
                                review_roll: roll(average_seconds: 300, sample: 10, scanned: 10)) }

    assert_select "[data-test='app-ladder-review-note']", text: "0 of 10 excluded"
  end

  # An average over four reviews and one over ten are different claims.
  test "a partial sample names how many reviews it covers" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green],
                                review_roll: roll(average_seconds: 8 * 60, sample: 4, scanned: 7)) }

    assert_select "[data-test='app-ladder-review-value']", text: "8m avg"
    assert_select "[data-test='app-ladder-review-note']", text: "over 4 reviews · 3 of 7 excluded"
  end

  # A card that renders blank or NaN for a quiet repo is worse than one that admits
  # it has nothing. solana-studio had ZERO measured reviews on 2026-08-25.
  test "a repo with no measured review says so instead of drawing a blank" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], repo: "solana-studio", review_roll: roll(repo: "solana-studio")) }

    assert_select "[data-test='app-ladder-review-value']", text: "not enough data"
    assert_select "[data-test='app-ladder-review-note']", text: "no reviews measured yet"
  end

  # Read-and-dropped is a different state from never-reviewed, and the card says which.
  test "a repo whose reviews were all excluded reports the count" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green],
                                review_roll: roll(repo: "mcritchie-industries", sample: 0, scanned: 2)) }

    assert_select "[data-test='app-ladder-review-value']", text: "not enough data"
    assert_select "[data-test='app-ladder-review-note']", text: "2 of 2 excluded"
  end

  # THE TWO MINUTE-FIGURES. The CI meter labels its clock by lane and this one says
  # "avg" out loud; if that word is ever dropped the card carries two bare durations.
  test "the review average is labelled apart from the CI run clock" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green],
                                review_roll: roll(average_seconds: 4 * 60, sample: 10, scanned: 10)) }

    assert_select "[data-test='app-ladder-review']", text: /review/i
    assert_select "[data-test='app-ladder-review-value']", text: "4m avg"
  end

  # A hand-built Card (a fixture, a future single-card render) carries no roll. It
  # must still render the empty state rather than raise on nil.
  test "a card built without a roll renders the empty state" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-review-value']", text: "not enough data"
  end

  private

  def card(states, repo: "turf-monster", parked: [0, 0, 0], sha: "abc1234def", run_url: nil,
           review_roll: nil, release_member: false, release_in_qa: false, last_shipped_at: nil)
    rungs = Ci::AppLadder::RUNGS.each_with_index.map do |branch, i|
      Ci::LadderRung.new(repo: repo, branch: branch, state: states[i],
                         sha: sha, parked_count: parked[i], run_url: run_url)
    end
    Ci::AppLadder::Card.new(repo: repo, rungs: rungs, review_roll: review_roll,
                            release_member: release_member, release_in_qa: release_in_qa,
                            last_shipped_at: last_shipped_at)
  end

  def roll(repo: "turf-monster", average_seconds: nil, sample: 0, scanned: 0)
    Review::DurationRoll::Roll.new(repo: repo, average_seconds: average_seconds,
                                   sample: sample, scanned: scanned)
  end
end
