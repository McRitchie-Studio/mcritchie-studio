# frozen_string_literal: true

require "test_helper"

# [component] /dreams renders the org chart: the platform row, a column per soul,
# each SOP with its dream count (zero included), a proposed badge and the detail a
# dream opens to. It reads the fixture bank (DREAM_BANK_DIR) so the page under test
# does not move when a real dream is merged; the SOPs are the live registry.
class DreamsPageTest < ActionDispatch::IntegrationTest
  BANK = Rails.root.join("test/fixtures/dreams").to_s

  setup do
    @previous_bank = ENV["DREAM_BANK_DIR"]
    ENV["DREAM_BANK_DIR"] = BANK
    log_in_as(users(:alex))
  end

  teardown { ENV["DREAM_BANK_DIR"] = @previous_bank }

  test "renders the platform row with its dreams and shared SOPs" do
    get dreams_path
    assert_response :success

    assert_select "[data-test='platform-row']" do
      assert_select "[data-test='dream-card'][data-dream='list-the-candidates']"
      assert_select "[data-test='dream-card'][data-dream='report-what-you-verified']"
      assert_select "[data-test='sop-row'][data-sop='building-sop']"
    end
  end

  test "renders a column per soul in roster order, with SOP rows and zero counts" do
    get dreams_path

    souls = css_select("[data-test='soul-column']").map { |node| node["data-soul"] }
    roster = DreamBank.roster.sort_by { |_, record| record["position"].to_i }.map(&:first)
    assert_equal roster, souls.first(roster.size)

    assert_select "[data-test='soul-column'][data-soul='carl']" do
      assert_select "[data-test='sop-row'][data-sop='pr-review-slow']" do
        assert_select "[data-test='sop-dream-count']", text: "0 dreams"
      end
      assert_select "[data-test='dream-card'][data-dream='wait-for-the-light']"
    end
    assert_select "[data-test='soul-column'][data-soul='xan'] [data-test='dream-card'][data-dream='wait-for-the-light']",
                  1, "a multi-soul dream shows under each soul"
    assert_select "[data-test='soul-column'][data-soul='turf-monster'] [data-test='sop-row']", minimum: 1
  end

  test "shows step dreams under their SOP and step, not among the platform or soul dreams" do
    get dreams_path

    assert_select "[data-test='soul-column'][data-soul='carl'] [data-test='sop-row'][data-sop='pr-review']" do
      assert_select "[data-test='sop-dream-count']", text: "1 dream"
      assert_select "[data-test='sop-step'][data-step='claim'][data-statuses='approved']" do
        assert_select "[data-test='dream-card'][data-dream='read-ci-before-the-diff']"
      end
    end
    assert_select "[data-test='platform-row'] [data-test='sop-row'][data-sop='building-sop'] " \
                  "[data-test='sop-step'][data-step='begin'] [data-dream='name-the-author-at-begin']"
    assert_select "[data-test='platform-row'] [data-test='stage-group'] [data-dream='name-the-author-at-begin']", 0,
                  "a step dream is not a platform dream"
    assert_select "[data-dream='read-ci-before-the-diff']", 1, "one card, under its SOP only"
  end

  test "a status filter hides a step group with no dream of that status" do
    get dreams_path(status: "proposed")

    assert_select "[data-test='sop-step'][data-step='claim'][hidden]"
  end

  test "groups a soul's dreams by stage with a no-stage bucket" do
    get dreams_path

    assert_select "[data-test='soul-column'][data-soul='pokemon']" do
      assert_select "[data-test='stage-group'][data-stage='building'] [data-dream='building-stage-commits-early']"
      assert_select "[data-test='stage-group'][data-stage='#{DreamOrgChart::NO_STAGE}'] [data-dream='untagged-habit']"
    end
  end

  test "marks a proposed dream and offers the status filter" do
    get dreams_path

    assert_select "[data-test='dream-card'][data-dream='proposed-money-idea'][data-status='proposed']" do
      assert_select "[data-test='dream-proposed-badge']", text: "Proposed"
    end
    assert_select "[data-test='dream-card'][data-dream='untagged-habit'] [data-test='dream-proposed-badge']", 0
    %w[all approved proposed].each { |status| assert_select "[data-test='dream-filter-#{status}']" }
    assert_select "[data-test='dreams-page'][data-dreams-filter='all']"
    assert_select "[data-test='dream-card'][hidden]", 0

    get dreams_path(status: "proposed")
    assert_select "[data-test='dreams-page'][data-dreams-filter='proposed']"
    assert_select "[data-test='dream-filter-proposed'][aria-current='page']"
    assert_select "[data-test='dream-filter-all'][aria-current]", 0
    assert_select "[data-dream='proposed-money-idea']:not([hidden])"
    assert_select "[data-dream='untagged-habit'][hidden]"
    assert_select "[data-test='platform-row'] [data-test='stage-group'][hidden]", minimum: 1
  end

  test "the dream counts follow the status filter" do
    pokemon = "[data-test='soul-column'][data-soul='pokemon'] [data-test='column-dream-count']"

    get dreams_path
    tokens = css_select(pokemon).first["data-dream-count"].split
    assert_operator tokens.size, :>, 1
    assert_select pokemon, text: "#{tokens.size} dreams"
    assert_select "[data-test='dream-filter-all'][aria-current='page']"

    get dreams_path(status: "proposed")
    assert_select pokemon, text: "1 dream"
    assert_select "[data-test='soul-column'][data-soul='carl'] [data-test='column-dream-count']", text: "0 dreams"
  end

  test "a dream opens to its answer, why, story, tags, status and file" do
    get dreams_path

    assert_select "[data-test='soul-column'][data-soul='carl'] [data-dream='money-review-reads-the-ledger'] [data-test='dream-detail']" do
      assert_select "[data-test='dream-answer']", text: "The ledger writes and their transaction."
      assert_select "[data-test='dream-why']", text: "A green test can miss an unpaired write."
      assert_select "[data-test='dream-status']", text: "approved"
      assert_select "[data-test='dream-tags'] .badge", text: "risk: money"
      assert_select "[data-test='dream-file-link'][href=?]", doc_path("dreams/carl/money-review-reads-the-ledger")
    end
  end

  test "renders a dream's story body as HTML" do
    get dreams_path

    assert_select "[data-test='soul-column'][data-soul='carl'] [data-dream='money-review-reads-the-ledger'] [data-test='dream-story']" do
      assert_select "h1", 0, "the title repeats the summary, so the story drops it"
      assert_select "h2", text: "Situation"
      assert_select "strong", text: "green"
      assert_select "a", 0, "the fixture's [author note](javascript:…) must not render as a link"
    end
    assert_includes response.body, "[author note](javascript:alert(1))", "it stays readable as text"
  end

  test "/agents links to /dreams" do
    get agents_path

    assert_select "[data-test='agents-dreams-link'][href=?]", dreams_path

    # A white-alpha pill vanishes on the light theme's page; the links sit on theme
    # tokens (text-body on surface-alt, border-strong) that read in both themes.
    %w[agents-dreams-link agents-activities-link].each do |link|
      classes = css_select("[data-test='#{link}']").first["class"].split
      assert_includes classes, "text-body", link
      assert_includes classes, "bg-surface-alt", link
      assert_empty classes.grep(%r{white/}), "#{link} still uses a white-alpha class"
    end
  end

  test "a visitor is walled out" do
    reset!
    get dreams_path

    assert_response :redirect
  end
end
