# frozen_string_literal: true

require "test_helper"
require_relative "../support/stated_prose"
require_relative "review_lane_docs_test"
require_relative "turf_vault_lane_figure_docs_test"

# THE TRIPWIRE ON THE SHARED POPULATION (guard-lane-figures-beyond-docs, 2026-09-22).
#
# Two guards shipped the same structural hole on the same day: each globbed a
# DIRECTORY and so could not see a site making the very claim it polices from outside
# that directory. The fix is not two wider globs — it is ONE population, because
# widening a guard's glob changes what every future author is measured against, and
# two builders answering that separately produce two globs and two exemption
# conventions. This file is what makes "decided once" enforceable rather than a
# comment: it fails if either guard drifts back to a population of its own.
#
# IT ALSO PINS THE WIDENING ITSELF. The criterion "a service-file preview site reds
# the guard" is satisfiable by four WRONG fixes — adding one file to a hard-coded
# list; deleting the offending comment; globbing everything including this suite's
# own fixtures; or widening one guard and leaving the other. The assertions below
# refuse each of those in turn.
class GuardPopulationTest < ActiveSupport::TestCase
  def population
    StatedProse.sources(Rails.root)
  end

  test "[unit] both guards read the SAME population, not two globs of their own" do
    shared = population

    assert_equal shared, TurfVaultLaneFigureDocsTest.new("population").guarded_docs,
                 "the turf-vault lane guard has stopped reading the shared population — " \
                 "a second glob is a second exemption convention"
    assert_equal shared, ReviewLaneDocsTest.new("population").guarded_sources,
                 "the reviewer-select preview guard has stopped reading the shared population"
  end

  # WRONG FIX #1: enumerate the one file that was missed. A derived population reaches
  # files nobody listed, so it covers the site added tomorrow.
  test "[unit] the population reaches beyond docs/ — comments in config, app, lib and bin" do
    rel = population.map { |path| StatedProse.rel(Rails.root, path) }

    assert_includes rel, "config/release_repos.yml",
                    "the registry that DECLARES the lane is where a lane figure is most " \
                    "authoritative, and it is not markdown"
    assert_includes rel, "app/services/reviewer_selector.rb",
                    "the preview instruction that started this was in the feature's OWN service"
    assert_includes rel, "bin/fast-check",
                    "the script that RUNS the lane states its figures too"
    assert_includes rel, "README.md",
                    "markdown outside docs/ states operating facts as well"

    assert_operator rel.count { |p| p.end_with?(".rb") }, :>, 100,
                    "the app/lib sweep is not reaching Ruby sources"
    assert_operator rel.count { |p| p.end_with?(".md") }, :>, 100,
                    "the markdown sweep regressed — docs/** must still be covered"
  end

  # WRONG FIX #3: glob everything. Four exclusions are load-bearing rather than tidy,
  # and each one is a way the population could report nonsense instead of findings.
  test "[unit] the population drops this suite's own fixtures, nested desks and vendored trees" do
    rel = population.map { |path| StatedProse.rel(Rails.root, path) }

    assert_empty rel.grep(%r{\Atest/}),
                 "test/ must stay out: both guards carry VERBATIM copies of the prose they " \
                 "exist to catch, so a population including this directory reds every guard " \
                 "against its own fixtures"
    assert_empty rel.grep(%r{(\A|/)\.worktrees/}),
                 "every desk is a full checkout nested inside the primary — scanning them " \
                 "reports other tasks' drafts as this repo's offenders, and the answer " \
                 "changes between runs"
    assert_empty rel.grep(%r{/node_modules/}), "vendored trees are not this repo's prose"
    assert_empty rel.grep(%r{/archive/|/audits/}), "frozen records stay as written"
  end

  # The trailing slash the lane guard's copy lacked. Bare `/archive` also matches
  # `/archived-*` and any segment merely beginning with those letters, which exempts
  # live files silently — the same failure mode as the over-broad frozen banner.
  test "[unit] the archive exclusion is a path SEGMENT, so it cannot swallow archived-*" do
    root = Rails.root

    assert StatedProse.excluded?(root, root.join("docs/agents/archive/old.md").to_s),
           "a real archive directory must stay exempt"
    refute StatedProse.excluded?(root, root.join("docs/agents/archived-tasks.md").to_s),
           "`archived-tasks.md` is a LIVE doc; a bare /archive fragment exempts it silently"
    refute StatedProse.excluded?(root, root.join("docs/agents/modules/archiver.md").to_s),
           "a file merely beginning with those letters is not an archive"
  end

  # The population is only honest if it can still READ what it collects. A regex that
  # matches nothing looks exactly like a tree with no defects — which is what the first
  # probe of this population reported, for that reason.
  test "[unit] comment bodies survive the read, and code bodies do not" do
    ruby = StatedProse.prose(Rails.root.join("app/services/reviewer_selector.rb").to_s)

    assert_match(/bin\/reviewer-select/, ruby,
                 "comment prose read as empty — the whole population would report clean")
    refute_match(/^class ReviewerSelector/, ruby, "code bodies must not be read as prose")
    refute_match(/^\s*POOL\s*=/, ruby, "a constant assignment is not a claim")
  end

  test "[unit] blanking a code line preserves the line number a reader is sent to" do
    path = Rails.root.join("app/services/reviewer_selector.rb").to_s

    assert_equal File.read(path).lines.size, StatedProse.prose(path).lines.size,
                 "a dropped line shifts every citation below it — an offender a reader " \
                 "cannot find is an offender that gets muted"
  end
end
