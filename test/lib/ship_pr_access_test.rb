# frozen_string_literal: true

# bin/lib/ship_pr_access.rb: the ship's PR-read preflight. Standalone:
#   ruby -Itest test/lib/ship_pr_access_test.rb
#
# THE INCIDENT, rel-20261029-00560a. The ship identity (the deployer App) could not
# read voicebox or alex-build PRs, the containment check could not prove four
# members, and they sat at `assembled` with nothing said before the ship. These cases
# drive the pure decisions with an injected reader, so none touches GitHub.
require "minitest/autorun"
require_relative "../../bin/lib/ship_pr_access"

class ShipPrAccessTest < Minitest::Test
  def reader(denied)
    ->(repo) { denied.key?(repo) ? [false, denied[repo]] : [true, "[]"] }
  end

  def test_it_lists_only_the_repos_whose_read_fails_in_order
    got = ShipPrAccess.unreadable(%w[mcritchie-studio voicebox turf-monster alex-build],
                                  reader: reader("voicebox" => "GraphQL: Could not resolve to a Repository",
                                                 "alex-build" => "HTTP 404"))

    assert_equal [["voicebox", "GraphQL: Could not resolve to a Repository"], ["alex-build", "HTTP 404"]], got
  end

  def test_every_repo_readable_is_no_warning
    assert_empty ShipPrAccess.unreadable(%w[mcritchie-studio turf-monster], reader: reader({}))
    assert_nil ShipPrAccess.warning([], identity: "github.mcritchie-admin")
  end

  def test_a_reader_that_raises_counts_as_unreadable_and_names_the_error
    got = ShipPrAccess.unreadable(["voicebox"], reader: ->(_repo) { raise IOError, "pipe closed" })

    assert_equal [["voicebox", "IOError: pipe closed"]], got, "a preflight bug must not hide the gap"
  end

  def test_repos_are_asked_once_and_blanks_skipped
    asked = []
    ShipPrAccess.unreadable(["voicebox", "", nil, "voicebox"], reader: ->(r) { asked << r; [true, ""] })

    assert_equal ["voicebox"], asked
  end

  def test_the_reason_is_the_first_nonblank_line_capped
    assert_equal "boom", ShipPrAccess.reason("\n  \nboom\nmore")
    assert_equal "no output", ShipPrAccess.reason("")
    assert_equal 140, ShipPrAccess.reason("x" * 500).size
  end

  def test_the_warning_names_each_repo_the_identity_and_what_to_grant
    text = ShipPrAccess.warning([["voicebox", "HTTP 404"], ["alex-build", "HTTP 404"]],
                                identity: "github.mcritchie-admin")

    assert_includes text, "(github.mcritchie-admin) cannot read pull requests in 2 release repo(s): voicebox, alex-build"
    assert_includes text, "- voicebox: HTTP 404"
    assert_includes text, "Pull requests: Read-only", "it must say WHAT to grant"
    assert_includes text, "add voicebox, alex-build under Repository"
    assert_includes text, "Alex McRitchie's GitHub-settings click", "and that no agent grants it"
    assert_includes text, "The ship goes on", "a warning, never a stop"
  end
end
