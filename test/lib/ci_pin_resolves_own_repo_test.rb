# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Load-order independence: this drives CiTestCommandTest.ecosystem_roots, so the
# class must be defined even when this file runs ALONE — which a 4-way sharded
# lane makes routine. Without this require the file errors with NameError instead
# of asserting, and a mutation would then "redden" for the wrong reason.
require_relative "ci_test_command_test"

# THE FLOOR OF THE ECOSYSTEM PIN IS STRUCTURAL, NOT INCIDENTAL.
#
# `CiTestCommandTest#test_EVERY_ecosystem_repo_still_resolves_CLEAN` runs the real
# parser over every repo it can find and then asserts `refute_empty checked` — an
# anti-vacuity guard, because a resolution bug would otherwise turn the whole pin
# green while checking nothing.
#
# That floor used to rest on `File.join(PROJECTS_ROOT, "mcritchie-studio")` happening
# to be a directory. True on the hub's own runner, where PROJECTS_ROOT lands on
# /home/runner/work and the outer checkout carries the repo's name. FALSE in
# studio-engine's CONSUMER lane, which checks the hub out under a different layout —
# there every repo was skipped, `checked` came back empty, and the guard fired on a
# lane where nothing was actually wrong. It blocked a gem publish preflight.
#
# The repair makes the repo we are RUNNING IN resolve from HUB_ROOT, which is layout
# independent. These pin BOTH directions, because softening the assert instead would
# have turned a guard that just caught a real layout assumption into decoration.
class CiPinResolvesOwnRepoTest < ActiveSupport::TestCase
  # Drives the SHIPPED resolution — CiTestCommandTest.ecosystem_roots — not a copy.
  # A copy would keep passing while the real code drifted, which is the exact shape
  # of guard this repo rejects everywhere else.
  def resolve(hub_root, projects_root)
    CiTestCommandTest.ecosystem_roots(hub_root, projects_root).keys
  end

  test "the pin counts the repo it runs inside when NO sibling is checked out" do
    Dir.mktmpdir do |hub|
      Dir.mktmpdir do |empty_projects|
        checked = resolve(hub, empty_projects)

        refute_empty checked,
                     "a sibling-less checkout must still check ONE repo — this is the consumer-lane case " \
                     "that reddened studio-engine CI and blocked a publish"
        assert_equal [File.basename(hub)], checked
      end
    end
  end

  test "the pin counts the repo it runs inside when PROJECTS_ROOT cannot be derived" do
    Dir.mktmpdir do |hub|
      assert_equal [File.basename(hub)], resolve(hub, nil),
                   "a nil PROJECTS_ROOT must not make the pin vacuous"
    end
  end

  test "a GENUINELY vacuous run still refuses — the guard keeps its teeth" do
    Dir.mktmpdir do |empty_projects|
      checked = resolve(File.join(empty_projects, "no-such-repo"), empty_projects)

      assert_empty checked,
                   "if even the running repo cannot resolve, the pin IS vacuous and refute_empty must fire"
    end
  end

  test "siblings are still picked up when they are present" do
    Dir.mktmpdir do |hub|
      Dir.mktmpdir do |projects|
        FileUtils.mkdir_p(File.join(projects, "turf-monster"))
        FileUtils.mkdir_p(File.join(projects, "studio-engine"))

        checked = resolve(hub, projects)

        assert_includes checked, File.basename(hub), "the running repo"
        assert_includes checked, "turf-monster", "a present sibling"
        assert_includes checked, "studio-engine", "a present sibling"
        refute_includes checked, "rolio", "an ABSENT sibling must stay skipped, not invented"
      end
    end
  end
end
