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
    assert_equal "agent", GhIdentity.resolve(nil, env: { "GH_APP_ITEM" => "" })
    assert_equal "agent", GhIdentity.resolve(nil, env: { "GH_APP_ITEM" => "   " })
  end

  # AN OMISSION AND A CALLER ERROR ARE DIFFERENT INSTRUCTIONS, and this module is the
  # only place that can tell them apart. `nil` means the caller said nothing about its
  # lane, so the env and the default answer for it — that is the case above. An empty
  # STRING means the caller reached for a lane and handed over nothing: `bin/gh-token
  # --identity "$VAR"` with VAR unset, which is ordinary shell and requires no mistake
  # beyond a typo'd variable name.
  #
  # This case used to be pinned the other way — `resolve("", env: {"GH_APP_ITEM" => ""})`
  # asserted "agent" — and that pin is what let the CLIs regress: they turn a missing
  # flag value into "" via `.to_s.strip`, the empty string read as "no explicit", and a
  # command that used to abort with `unknown identity ""` began silently minting the App
  # that holds `pull_requests: write`. An unreadable instruction resolving to the MOST
  # privileged identity is the exact failure this module exists to end, and an empty
  # explicit value is unreadable in precisely the way a typo'd GH_APP_ITEM is. So it
  # takes the same contract: nil, and every caller aborts.
  def test_an_explicit_but_empty_identity_refuses_rather_than_defaulting
    assert_nil GhIdentity.resolve("", env: {}),
               "an empty --identity is a caller error, not an omission"
    assert_nil GhIdentity.resolve("   ", env: {}), "whitespace is just as empty"
    assert_nil GhIdentity.resolve("", env: { "GH_APP_ITEM" => AGENT_ITEM }),
               "a caller that named its lane and lost the value must not silently inherit the env's"
    assert_nil GhIdentity.resolve("", env: { "GH_APP_ITEM" => DEPLOYER_ITEM })
  end

  # Stated as the privilege property rather than as `assert_nil`, so a future refactor
  # that returns some other falsy-ish default still fails here.
  def test_an_empty_identity_never_yields_the_pr_writing_app
    [{}, { "GH_APP_ITEM" => "" }, { "GH_APP_ITEM" => DEPLOYER_ITEM }].each do |env|
      refute_equal "agent", GhIdentity.resolve("", env: env),
                   "an empty identity must never resolve to the App holding pull_requests: write"
    end
  end

  # Two DIFFERENT causes reach the same nil, and the operator gets one line to act on.
  # Reporting "GH_APP_ITEM names no known identity" to someone who never set GH_APP_ITEM
  # sends them to the wrong knob.
  def test_the_unresolved_reason_names_the_actual_cause
    empty = GhIdentity.unresolved_reason("", env: { "GH_APP_ITEM" => "" })
    assert_match(/empty/i, empty)
    refute_match(/GH_APP_ITEM/, empty, "the caller's flag is at fault here, not the environment")

    unknown = GhIdentity.unresolved_reason(nil, env: { "GH_APP_ITEM" => "github.mcritchie-typo" })
    assert_includes unknown, "github.mcritchie-typo"
    assert_includes unknown, "GH_APP_ITEM"
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
