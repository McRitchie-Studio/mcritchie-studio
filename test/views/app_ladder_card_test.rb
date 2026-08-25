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

  # THE REGRESSION. A green rung renders GREEN — it used to render faded whenever a
  # task had been stamped after the run started, which is always. Measured in
  # production 2026-08-20: turf-monster release, green@e1217b6, badge faded, 47s apart.
  test "a green rung renders green and never faded" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[green green green]) }

    assert_select "[data-test='app-ladder-rung'][data-state='green']", 3
    assert_select "[data-test='app-ladder-rung'] [data-test='app-ladder-rung-fill'].bg-emerald-500", 3
    assert_select "[data-test='app-ladder-rung'][data-state='stale']", 0
  end

  # The card must not contradict itself: a green CI meter beside a faded badge on the
  # same rung is what sent this back. Whatever CI says, the badge says.
  test "the badge agrees with the verdict it was given" do
    { green: "bg-emerald-500", pending: "bg-amber-500", red: "bg-rose-500" }.each do |state, fill|
      render partial: "tasks/app_ladder_card", locals: { card: card([state, state, state]) }

      assert_select "[data-test='app-ladder-rung'][data-state='#{state}']", 3
      assert_select "[data-test='app-ladder-rung'] [data-test='app-ladder-rung-fill'].#{fill}", 3,
                    "#{state} must wear its own fill"
    end
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
           locals: { card: card(%i[green green green], parked: [3, 1, 0]) }

    assert_select "[data-test='app-ladder-parked']", 2
    assert_select "[data-test='app-ladder-parked'][data-branch='accepted']", text: /3 on accepted/
    assert_select "[data-test='app-ladder-parked'][data-branch='release']", text: /1 on release/
  end

  # THE CLEAN SLATE the operator asked for: once a deployment is done and nothing is
  # waiting below main, the card says nothing at all rather than carrying a permanent
  # "37 on main" that never drains.
  test "a fully shipped repo renders a quiet card" do
    render partial: "tasks/app_ladder_card",
           locals: { card: card(%i[green green green], parked: [0, 0, 0]) }

    assert_select "[data-test='app-ladder-parked-row']", 0
    assert_select "[data-test='app-ladder-parked']", 0
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
  test "a card with no ingested checks says so instead of drawing an empty meter" do
    render partial: "tasks/app_ladder_card", locals: { card: card(%i[not_built not_built not_built]) }

    assert_select "[data-test='app-ladder-ci-empty']", 1
    assert_select "[data-test='app-ladder-ci']", 0
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

  def fake_card(repo:, counted:, uncounted:)
    rungs = Ci::AppLadder::RUNGS.map do |b|
      FakeRung.new(branch: b, state: :green, short_sha: "abc1234", parked_count: 0,
                   counted_lane: counted, uncounted_lanes: uncounted, progress: nil,
                   run_url: nil, verdict_at: Time.current)
    end
    card = Ci::AppLadder::Card.new(repo: repo, rungs: rungs)
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

  def card(states, repo: "turf-monster", parked: [0, 0, 0], sha: "abc1234def", run_url: nil, review_roll: nil)
    rungs = Ci::AppLadder::RUNGS.each_with_index.map do |branch, i|
      Ci::LadderRung.new(repo: repo, branch: branch, state: states[i],
                         sha: sha, parked_count: parked[i], run_url: run_url)
    end
    Ci::AppLadder::Card.new(repo: repo, rungs: rungs, review_roll: review_roll)
  end

  def roll(repo: "turf-monster", average_seconds: nil, sample: 0, scanned: 0)
    Review::DurationRoll::Roll.new(repo: repo, average_seconds: average_seconds,
                                   sample: sample, scanned: scanned)
  end
end
