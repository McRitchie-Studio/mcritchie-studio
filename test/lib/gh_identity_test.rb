# frozen_string_literal: true

# [unit] GhIdentity — which GitHub App speaks for this session.
#
# The privilege boundary between the two Apps is enforced by GitHub, but WHICH App
# a process asks for is decided here. Before this module every caller decided
# separately and two of the three hardcoded `agent`, so a ship session could hold
# GH_APP_ITEM=github.mcritchie-deployer and still be handed the App with
# `pull_requests: write`. These cases pin the resolution order that fixes that.
#
#   ruby -Itest test/lib/gh_identity_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/gh_identity"

class GhIdentityTest < Minitest::Test
  AGENT_ITEM = "github.mcritchie-agent"
  DEPLOYER_ITEM = "github.mcritchie-deployer"

  # THE BUG, at unit scale: a ship session exports the deployer ITEM and every
  # GitHub call it makes must follow. Ignoring this env var is what handed the ship
  # lane the PR-writing App.
  def test_gh_app_item_selects_the_ship_identity
    assert_equal "deployer", GhIdentity.resolve(nil, env: { "GH_APP_ITEM" => DEPLOYER_ITEM })
  end

  def test_gh_app_item_selects_the_build_identity
    assert_equal "agent", GhIdentity.resolve(nil, env: { "GH_APP_ITEM" => AGENT_ITEM })
  end

  # A caller that names its lane outright still wins — bin/ship genuinely needs the
  # PR-writing App even if launched from a shell with a stale ship export.
  def test_an_explicit_identity_outranks_the_environment
    assert_equal "agent", GhIdentity.resolve("agent", env: { "GH_APP_ITEM" => DEPLOYER_ITEM })
    assert_equal "deployer", GhIdentity.resolve("deployer", env: { "GH_APP_ITEM" => AGENT_ITEM })
  end

  def test_no_signal_at_all_is_the_build_identity
    assert_equal "agent", GhIdentity.resolve(nil, env: {})
    assert_equal "agent", GhIdentity.resolve("", env: { "GH_APP_ITEM" => "" })
    assert_equal "agent", GhIdentity.resolve(nil, env: { "GH_APP_ITEM" => "   " })
  end

  # An UNREADABLE instruction must not quietly become the most privileged answer.
  # Returning "agent" here would reproduce the original bug through a typo, so the
  # contract is nil and every caller aborts on it.
  def test_an_unknown_item_resolves_to_nil_rather_than_the_privileged_default
    assert_nil GhIdentity.resolve(nil, env: { "GH_APP_ITEM" => "github.mcritchie-typo" })
    refute_equal "agent", GhIdentity.resolve(nil, env: { "GH_APP_ITEM" => "github.mcritchie-typo" }),
                 "a typo'd item must never silently yield the PR-writing App"
  end

  def test_unknown_item_message_names_the_offender_and_the_valid_set
    msg = GhIdentity.unknown_item_message(env: { "GH_APP_ITEM" => "github.mcritchie-typo" })

    assert_includes msg, "github.mcritchie-typo"
    assert_includes msg, AGENT_ITEM
    assert_includes msg, DEPLOYER_ITEM
  end

  def test_known_and_item_for_round_trip
    assert GhIdentity.known?("agent")
    assert GhIdentity.known?("deployer")
    refute GhIdentity.known?("nobody")
    assert_equal DEPLOYER_ITEM, GhIdentity.item_for("deployer")
  end

  # The two lanes are DIFFERENT Apps. A refactor that collapsed them would pass every
  # test above by accident, so state the separation outright.
  def test_the_two_lanes_are_distinct_apps
    refute_equal GhIdentity.item_for("agent"), GhIdentity.item_for("deployer"),
                 "collapsing the identities would erase the privilege boundary"
  end
end
