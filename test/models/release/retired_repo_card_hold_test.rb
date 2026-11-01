# frozen_string_literal: true

require "test_helper"
require "minitest/mock"

# chain-ops left the app catalog on 2026-11-01, but chain-ops-mail-from-team still sits
# at `reviewed` on a live desk. The release registry keeps a bare `ladder: blocked`
# row so that card stays parked. These tests read the REAL registry, not a fixture.
#
# When the card is archived, delete the row, this file, the entry in
# AppRegistryTest::RETIRED_HOLDING_A_CARD, the exclusions in the glyph tests of
# ApplicationHelperTest and AppProfileTest, and the chain-ops entries in
# Release::ReposTest (the app list and the prod_deploy strategy table) together.
class Release::RetiredRepoCardHoldTest < ActiveSupport::TestCase
  RETIRED = "chain-ops"
  LIVE = "mcritchie-studio"

  def reviewed_on(repo)
    Task.create!(title: "#{repo} hold task", stage: "reviewed",
                 metadata: { "devops" => { "shape" => "backend", "repositories" => [ repo ],
                                           "pr_urls" => { repo => "https://github.com/McRitchie-Studio/#{repo}/pull/7" } } })
  end

  def without_retired_row(&block)
    config = Release::Repos.config.deep_dup
    config["apps"].delete(RETIRED)
    Release::Repos.stub(:config, config, &block)
  end

  test "[integration] curate! carries on past a reviewed task naming the retired repo" do
    held = reviewed_on(RETIRED)
    live = reviewed_on(LIVE)

    release = Release::Conductor.curate!(slug: "rel-retired-hold")

    assert_includes release.ordered_members.map(&:slug), live.slug
    assert_not_includes release.ordered_members.map(&:slug), held.slug
    assert_equal "reviewed", held.reload.stage
  end

  test "[integration] control: without the row the same sweep raises and rolls back" do
    held = reviewed_on(RETIRED)
    reviewed_on(LIVE)

    without_retired_row do
      error = assert_raises(ArgumentError) { Release::Conductor.curate!(slug: "rel-retired-hold") }
      assert_match(/can't deploy unknown repo\(s\).*#{held.slug}/, error.message)
    end
    assert_nil Release.find_by(slug: "rel-retired-hold"), "the failed sweep must leave no release behind"
  end

  test "[unit] the retired repo is parked and stays out of the catalog" do
    assert_equal "blocked", Release::Ladder.parked(Release::Repos.config)[RETIRED]
    assert_nil AppCatalog.app(RETIRED)
  end
end
