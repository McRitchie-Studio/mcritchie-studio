# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# [unit] DreamOrgChart: the org-chart builder behind /dreams. It reads the fixture
# bank (test/fixtures/dreams) and a throwaway SOP tree, never the live docs.
class DreamOrgChartTest < ActiveSupport::TestCase
  BANK = Rails.root.join("test/fixtures/dreams").to_s
  SOULS = {
    "pokemon" => { "slug" => "pokemon", "name" => "Pokémon", "title" => "General builder", "position" => 2 },
    "carl" => { "slug" => "carl", "name" => "Carl", "title" => "Lead Architect", "position" => 1 },
    "ray" => { "slug" => "ray", "name" => "Ritch", "title" => "Lead Orchestrator", "position" => 0 },
    "turf-monster" => { "slug" => "turf-monster", "name" => "Turf Monster", "title" => "Operator", "position" => 3 }
  }.freeze

  setup do
    @root = Dir.mktmpdir("dream-org-chart")
    write("docs/agents/agents/carl/HEARTBEAT.md", "# Carl\n")
    write("docs/agents/agents/carl/sops/pr-review.md", "# PR review\n<!-- registry: the review sweep -->\n")
    write("docs/agents/agents/turf_monster/sops/market-refresh.md", "# Market refresh\n")
    write("docs/agents/modules/building-sop.md", "# Building\n<!-- registry: build a task -->\n")
    write("docs/agents/modules/not-an-sop.md", "# Plain module\n")
    @chart = DreamOrgChart.build(root: @root, dir: BANK, souls: SOULS)
  end

  teardown { FileUtils.rm_rf(@root) }

  test "every dream file lands under platform or each soul it is tagged for" do
    files = Dir.glob(File.join(BANK, "**", "*.md")).map { |path| File.basename(path, ".md") }.sort
    under_sops = (@chart.platform.sops + @chart.columns.flat_map(&:sops)).flat_map { |sop| sop.steps.flat_map(&:dreams) }
    placed = (@chart.platform.dreams + @chart.columns.flat_map(&:dreams) + under_sops).map(&:slug).uniq.sort

    assert_equal files, placed, "a dream file went missing from the chart"
    assert_equal %w[list-the-candidates report-what-you-verified], @chart.platform.dreams.map(&:slug).sort
    assert_includes column("carl").dreams.map(&:slug), "wait-for-the-light"
    assert_includes column("ray").dreams.map(&:slug), "wait-for-the-light", "a multi-soul dream shows under each soul"
  end

  test "columns follow the roster position order and keep empty souls" do
    assert_equal %w[ray carl pokemon turf-monster], @chart.columns.map(&:slug)
    assert_empty column("turf-monster").dreams
  end

  test "dreams group by stage with a no-stage bucket last" do
    stages = column("pokemon").stages.map(&:stage)

    assert_equal [ "building", DreamOrgChart::NO_STAGE ], stages
    assert_includes column("pokemon").stages.last.dreams.map(&:slug), "untagged-habit"
  end

  test "proposed dreams stay on the chart with their story and source" do
    proposed = column("pokemon").dreams.find { |dream| dream.slug == "proposed-money-idea" }

    assert_equal "proposed", proposed.status
    assert_equal 1, @chart.counts["proposed"]
    assert_equal @chart.dreams.size, @chart.counts["all"]
  end

  test "SOPs map from the registry to their soul, shared modules to platform, each with a count" do
    assert_equal [ "Carl Heartbeat", "pr-review" ], column("carl").sops.map(&:invocation)
    assert_equal [ "market-refresh" ], column("turf-monster").sops.map(&:invocation), "turf_monster joins turf-monster"
    assert_equal [ "building-sop" ], @chart.platform.sops.map(&:invocation), "only marked modules are shared SOPs"
    assert_equal "agents/carl/sops/pr-review", column("carl").sops.last.doc_path
    assert_equal 0, column("turf-monster").sops.first.dream_count, "a zero count is kept"
  end

  test "step dreams group under their SOP and step, in the column the registry gives the SOP" do
    review = column("carl").sops.find { |sop| sop.invocation == "pr-review" }
    building = @chart.platform.sops.find { |sop| sop.invocation == "building-sop" }

    assert_equal 1, review.dream_count
    assert_equal [ "claim" ], review.steps.map(&:step)
    assert_equal [ "read-ci-before-the-diff" ], review.steps.first.dreams.map(&:slug)
    assert_equal [ "begin" ], building.steps.map(&:step)
    assert_equal [ "name-the-author-at-begin" ], building.steps.first.dreams.map(&:slug)
    refute_includes @chart.platform.dreams.map(&:slug), "name-the-author-at-begin", "a step dream is not a platform dream"
    refute_includes column("carl").dreams.map(&:slug), "read-ci-before-the-diff", "nor one of the soul's own"
    assert_empty column("carl").sops.first.steps, "an SOP with no step dream has no step groups"
  end

  test "a dream tagged with an SOP counts under it" do
    dream = DreamBank::Dream.new(slug: "x", question: "Q?", answer: "A.", why: "", status: "approved",
                                 tags: { "soul" => [ "carl" ], "sop" => [ "pr-review" ] }, home: "carl")
    chart = DreamOrgChart.new(dreams: [ dream ], entries: SopRegistry.entries(@root), souls: SOULS)

    sop = chart.columns.find { |c| c.slug == "carl" }.sops.find { |s| s.invocation == "pr-review" }
    assert_equal 1, sop.dream_count
    assert_equal [ "approved" ], sop.dream_statuses, "the page recounts these under its status filter"
  end

  test "the doc path of a dream is its file under docs/agents" do
    dream = column("carl").dreams.first

    assert_equal "dreams/carl/#{dream.slug}", DreamOrgChart.doc_path_for(dream)
  end

  test "the live bank and registry build without dropping a dream" do
    chart = DreamOrgChart.build
    files = Dir.glob(File.join(DreamBank::DEFAULT_DIR, "**", "*.md"))
              .reject { |path| DreamBank::SKIPPED.include?(File.basename(path)) }.size

    assert_equal files, chart.dreams.size, "a tracked dream failed to parse"
    assert chart.columns.flat_map(&:sops).any?, "the registry produced no soul SOPs"
    qa = chart.columns.flat_map(&:sops).find { |sop| sop.invocation == "qa-release" }
    assert_includes qa.steps.map(&:step), "prepare", "a live step dream shows under its live SOP"
  end

  private

  def column(slug) = @chart.columns.find { |c| c.slug == slug }

  def write(relative, text)
    path = File.join(@root, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
end
