# frozen_string_literal: true

# [unit] QaIdlPair — the EXPECTED_IDL_HASH allow-list bin/qa-server derives for a
# QA app, and the set comparison its heal uses (/tasks/qa-server-idl-pair-heal).
#
# THE INCIDENT. turf-monster-qa runs SOLANA_VAULT_GOVERNANCE=on and was pinned to
# {v0.25, v0.26}. The registry declared `sha256:config/turf_vault.idl.json` (the
# v0.25 file alone), the deploy heal called the pair "drift", PATCHed the lone
# hash over it, and every boot raised IdlMismatchError. These pin the rule that
# replaced it: turf-monster's lib/solana/idl_selection.rb, mirrored.
#
#   ruby -Itest test/lib/qa_idl_pair_test.rb

require "minitest/autorun"
require "digest"
require "json"
require_relative "../../bin/lib/qa_idl_pair"

class QaIdlPairTest < Minitest::Test
  V025 = JSON.dump("instructions" => [{ "name" => "deposit" }])
  V026 = JSON.dump("instructions" => [{ "name" => "deposit" }, { "name" => "init_governance" }])
  MAINNET_V025 = JSON.dump("instructions" => [{ "name" => "deposit" }, { "name" => "mainnet" }])
  MAINNET_V026 = JSON.dump("instructions" => [{ "name" => "init_governance" }, { "name" => "mainnet" }])

  TREE = {
    "config/turf_vault.idl.json" => V025,
    "config/turf_vault.v026.idl.json" => V026,
    "config/turf_vault.mainnet.idl.json" => MAINNET_V025,
    "config/turf_vault.mainnet.v026.idl.json" => MAINNET_V026
  }.freeze

  def h(bytes) = Digest::SHA256.hexdigest(bytes)

  def value(env, tree = TREE)
    QaIdlPair.value(env, stem: "config/turf_vault", read: ->(path) { tree[path] })
  end

  # The regression: governance ON must pin BOTH shapes, selected file first —
  # exactly turf bin/deploy's "$LOCAL_HASH,$SIBLING_HASH".
  def test_governance_on_pins_the_v026_file_and_its_v025_sibling
    pinned = value("SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "on")

    assert_equal "#{h(V026)},#{h(V025)}", pinned
    refute_equal h(V025), pinned, "the lone v0.25 hash is the value that broke turf-monster-qa"
  end

  # Governance off with no sibling shipped: one hash, the selected file.
  def test_governance_off_without_a_sibling_writes_one_hash
    tree = { "config/turf_vault.idl.json" => V025 }

    assert_equal h(V025), value({ "SOLANA_NETWORK" => "devnet" }, tree)
  end

  # Governance off WITH the v0.26 file shipped keeps the sibling, as turf's
  # bin/deploy does: it is what the forward flip `SOLANA_VAULT_GOVERNANCE=on`
  # boots against without a deploy.
  def test_governance_off_keeps_the_shipped_sibling_like_turf_bin_deploy
    assert_equal "#{h(V025)},#{h(V026)}", value("SOLANA_NETWORK" => "devnet")
    assert_equal "#{h(V025)},#{h(V026)}", value("SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "off")
  end

  def test_mainnet_selects_the_mainnet_files
    assert_equal "#{h(MAINNET_V026)},#{h(MAINNET_V025)}",
                 value("SOLANA_NETWORK" => "mainnet-beta", "SOLANA_VAULT_GOVERNANCE" => "true")
  end

  # turf's IdlSelection.governance?: presence then parse, so an EMPTY switch
  # refuses rather than quietly meaning "off".
  def test_an_empty_or_unreadable_switch_refuses
    assert_raises(QaIdlPair::Refused) { value("SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "") }
    assert_raises(QaIdlPair::Refused) { value("SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "maybe") }
  end

  def test_an_empty_network_refuses
    assert_raises(QaIdlPair::Refused) { value("SOLANA_VAULT_GOVERNANCE" => "on") }
  end

  def test_a_missing_selected_file_refuses
    error = assert_raises(QaIdlPair::Refused) do
      value({ "SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "on" },
            { "config/turf_vault.idl.json" => V025 })
    end
    assert_includes error.message, "turf_vault.v026.idl.json"
  end

  # Solana::Config.verify_governance_alignment!, read ahead: a switch that
  # disagrees with the shape of the file it selects refuses.
  def test_a_switch_that_disagrees_with_the_file_shape_refuses
    swapped = TREE.merge("config/turf_vault.v026.idl.json" => V025)

    assert_raises(QaIdlPair::Refused) do
      value({ "SOLANA_NETWORK" => "devnet", "SOLANA_VAULT_GOVERNANCE" => "on" }, swapped)
    end
  end

  # ── the allow-list as a set ─────────────────────────────────────────────────

  def test_a_live_pin_that_covers_the_declared_pair_in_any_order_is_covered
    assert QaIdlPair.covers?("b,a", "a,b")
    assert QaIdlPair.covers?("a, b ,c", "a,b"), "an extra live hash still accepts every declared one"
    refute QaIdlPair.covers?("a", "a,b"), "a pin missing the sibling must heal"
  end

  def test_widen_keeps_live_first_and_adds_only_what_is_missing
    assert_equal "old,a,b", QaIdlPair.widen("old,a", "a,b")
  end

  def test_same_set_ignores_order_and_repeats
    assert QaIdlPair.same_set?("a,b,a", "b,a")
    refute QaIdlPair.same_set?("a,b,old", "a,b")
  end
end
