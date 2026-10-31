# frozen_string_literal: true

# `bin/release ship`'s PR-read preflight (bin/lib/ship_pr_access.rb), driven through
# the real ship. Its own file, because the release CLI suite's files are frozen at
# their size. Run directly:
#   ruby -Itest test/lib/release_cli_ship_pr_access_test.rb
#
# rel-20261029-00560a: the ship identity could not read voicebox/alex-build PRs, and
# the first anyone heard of it was four members held at `assembled` after the deploy.
# The preflight names every such repo BEFORE ship authority, dry run included.

require_relative "release_cli_harness"

class ReleaseCliShipPrAccessTest < ReleaseCliHarness
  # [integration] a dry-run ship with one unreadable repo warns at the preflight,
  # before ship authority, names what to grant, and still plans the rest of the ship.
  def test_a_dry_run_ship_warns_on_an_unreadable_repo_at_the_preflight
    setup = %(ENV["RELEASE_PR_UNREADABLE"] = "turf-monster"\n) + SHIP_STUB
    out = run_cli(["--dry-run"], call: "ship", setup: setup)

    warn_at = out.index("PR READ PREFLIGHT")
    preflight_at = out.index("ship preflight")
    authority_at = out.index("taking production authority")

    assert warn_at, "the unreadable repo must be named before the ship: #{out}"
    assert_operator preflight_at, :<, warn_at, "the warning is part of the ship preflight"
    assert_operator warn_at, :<, authority_at, "and it lands before ship authority"
    assert_match(/cannot read pull requests in 1 release repo\(s\): turf-monster$/, out)
    assert_includes out, "Pull requests: Read-only"
    refute_match(/PR READ PREFLIGHT[^\n]*mcritchie-studio/, out, "a readable repo is not listed")
    assert_includes out, "push heroku bbbbbbb:refs/heads/main", "a warning, never a stop: the plan goes on"
  end

  # THE CONTROL: every repo readable says so in one line and warns nothing.
  def test_a_dry_run_ship_with_every_repo_readable_warns_nothing
    out = run_cli(["--dry-run"], call: "ship", setup: SHIP_STUB)

    refute_includes out, "PR READ PREFLIGHT"
    assert_includes out, "reads pull requests in every app repo"
  end
end
