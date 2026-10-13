# frozen_string_literal: true

# `bin/release status` prints PROGRAM DRIFT: the release lane ships apps, never an
# on-chain program, so status also says when a cluster runs an older program than
# its source branch carries, and names the upgrade card that owns the gap.
#
# Part of the bin/release CLI suite (shared harness: test/lib/release_cli_harness.rb).
# The board and the ladder are stubbed exactly as release_cli_status_test.rb stubs
# them; ProgramDrift's reads are stubbed at its two seams (readings, board_lookup),
# so the REAL program_drift_report and the REAL status run.
#   ruby -Itest test/lib/release_cli_program_drift_test.rb

require_relative "release_cli_harness"

class ReleaseCliProgramDriftTest < ReleaseCliHarness
  LADDER = { pending: [], ahead: [{ "repo" => "mcritchie-studio", "ahead" => 0 }] }.freeze

  # Both clusters one minor behind, as on 2026-10-12 (chain v0.25.0, main v0.26.0).
  def drift_stub(cards:, readable: true)
    <<~RUBY
      module ProgramDrift
        def self.readings(**)
          programs.select { |p| p.name == "turf-vault" }.flat_map do |program|
            program.clusters.map do |cluster|
              classify(program: program, cluster: cluster, source_version: "0.26.0",
                       deployment: { version: "0.25.0", slot: 7 },
                       chain_slot: #{readable ? 7 : 'nil'}, chain_error: "connection refused")
            end
          end
        end

        def self.board_lookup(**)
          cards = #{cards.inspect}
          ->(slug) { cards[slug] && { "slug" => slug, "stage" => cards[slug] } }
        end
      end
    RUBY
  end

  def status_with(stub)
    run_cli(["status"], setup: status_stub(**LADDER) + stub, call: "status; puts('DONE-NO-ABORT')")
  end

  def test_status_names_the_upgrade_card_for_each_behind_cluster
    out = status_with(drift_stub(cards: { "devnet-v026-upgrade" => "designed", "mainnet-v026-upgrade" => "designed" }))

    assert_includes out, "PROGRAM DRIFT turf-vault devnet: chain runs v0.25.0 (slot 7), source is v0.26.0 — " \
                         "upgrade card devnet-v026-upgrade (designed)"
    assert_includes out, "PROGRAM DRIFT turf-vault mainnet: chain runs v0.25.0 (slot 7), source is v0.26.0 — " \
                         "upgrade card mainnet-v026-upgrade (designed)"
    assert_includes out, "DONE-NO-ABORT", "drift is reported, never a reason for status to abort"
  end

  def test_status_says_no_card_exists_when_none_is_on_the_board
    out = status_with(drift_stub(cards: {}))

    assert_match(/PROGRAM DRIFT turf-vault devnet: .* NO upgrade card: file devnet-v026-upgrade/, out)
    assert_match(/PROGRAM DRIFT turf-vault mainnet: .* NO upgrade card: file mainnet-v026-upgrade/, out)
  end

  def test_status_prints_cannot_confirm_when_the_chain_is_unreadable
    out = status_with(drift_stub(cards: {}, readable: false))

    assert_match(/PROGRAM DRIFT turf-vault devnet: cannot confirm the deployed version/, out)
    refute_match(/current at/, out, "an unread chain is never reported as current")
  end

  def test_a_failing_drift_check_never_breaks_status
    stub = "module ProgramDrift; def self.readings(**) = raise('kaboom'); end\n"
    out = status_with(stub)

    assert_includes out, "PROGRAM DRIFT: cannot confirm any program's deployed version — the check failed"
    assert_includes out, "DONE-NO-ABORT"
  end

  # Sealed: with no stub at all, the real reads hit the OutboundSeams floor (gh stub,
  # unroutable RPC) and status still finishes, reporting cannot confirm.
  def test_unstubbed_status_under_the_seal_fails_closed
    out = run_cli(["status"], setup: status_stub(**LADDER), call: "status; puts('DONE-NO-ABORT')")

    assert_match(/PROGRAM DRIFT turf-vault (devnet|mainnet): cannot confirm/, out)
    assert_match(/UPGRADE RESERVE turf-vault mainnet: cannot confirm/, out,
                 "an unread reserve is never reported as funded")
    assert_includes out, "DONE-NO-ABORT"
  end

  # The upgrade reserve (the mainnet Squad vault) prints under the same heading. Its
  # read is stubbed at the RPC seam (rpc_call), so the REAL reserve_readings reads the
  # REAL config and classifies it. The cache is bypassed by the harness's fresh tmpdir.
  def reserve_stub(balance:)
    <<~RUBY
      module ProgramDrift
        def self.rpc_call(_url, method, params)
          case method
          when "getAccountInfo"
            if params[1]["encoding"] == "jsonParsed"
              { "value" => { "owner" => UPGRADEABLE_LOADER,
                             "data" => { "parsed" => { "info" => { "programData" => "PD" } } } } }
            else
              { "value" => { "space" => 707_645 } }
            end
          when "getMinimumBalanceForRentExemption" then (params[0] + 128) * 5_080
          when "getBalance" then { "value" => #{balance} }
          end
        end
      end
    RUBY
  end

  def test_status_warns_when_the_upgrade_reserve_is_below_the_next_float
    stub = drift_stub(cards: { "devnet-v026-upgrade" => "designed", "mainnet-v026-upgrade" => "designed" })
    out = status_with(stub + reserve_stub(balance: 3_000_000_000))

    assert_includes out, "UPGRADE RESERVE SHORT turf-vault mainnet: mainnet Squad vault Bk9s… holds 3.0000 SOL, " \
                         "less than the next upgrade's float 3.5954 SOL"
    assert_includes out, "PROGRAM DRIFT turf-vault mainnet:", "the reserve line never displaces the drift lines"
    assert_includes out, "DONE-NO-ABORT", "a short reserve is a warning, never a reason for status to abort"
  end

  def test_status_reads_a_funded_reserve_as_a_plain_line
    out = status_with(drift_stub(cards: {}) + reserve_stub(balance: 10_304_529_006))

    assert_includes out, "upgrade reserve turf-vault mainnet: mainnet Squad vault Bk9s… holds 10.3045 SOL; " \
                         "next float 3.5954 SOL, minimum 4.5954 SOL"
    refute_match(/UPGRADE RESERVE (SHORT|LOW)/, out)
  end

  def test_a_failing_reserve_check_never_hides_the_drift_lines
    stub = drift_stub(cards: {}) + "module ProgramDrift; def self.reserve_readings(**) = raise('kaboom'); end\n"
    out = status_with(stub)

    assert_includes out, "UPGRADE RESERVE: cannot confirm — the check failed (RuntimeError: kaboom)"
    assert_match(/PROGRAM DRIFT turf-vault devnet:/, out)
    assert_includes out, "DONE-NO-ABORT"
  end
end
