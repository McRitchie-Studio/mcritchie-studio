# frozen_string_literal: true

# [unit] Release::DevnetGauntletRun: the unattended contest-rehearsal bin/release
# prepare runs on a Turf release. Every effect is a fake (the driver, the manifest,
# the devnet getTransaction), so nothing here reaches QA, devnet or 1Password.
#
#   bin/rails test test/models/release/devnet_gauntlet_run_test.rb
#
# A Rails test, not a bare test/lib one: requiring the file directly would define
# `class Release` before the model autoloads, and every Release test after it in
# the same process would find a plain class.
require "test_helper"

class Release::DevnetGauntletRunTest < ActiveSupport::TestCase
  Run = Release::DevnetGauntletRun

  SETTLE = "5settleSig111"
  CLOSE = "4closeSig222"
  ESCROW = "VaultPda1111"
  MACK = "MackWallet11"
  TURF = "TurfWallet11"
  MINT = "USDCmint1111"

  # What each real step prints (turf-monster lib/turf_monster/qa_rehearsal/driver.rb).
  GREEN = {
    "seed" => "Step 0 · seed\n  roster:  parked_one, parked_two\n  elapsed: 25s (seed)\n",
    "create" => "Step 1 · create\n  contest:  rehearsal-abc (Rehearsal)\n" \
                "  on-chain: yes · pool $500 · payouts {\"1\" => 30000, \"2\" => 10000}\n  elapsed: 48s (create)\n",
    "enter" => "Step 2 · enter\n    entered · entry 1 · tx abc…\n  all 2 entered\n  elapsed: 16s (enter)\n",
    "play" => "replay: done\nreplay: caught up — 246 plays on the board, 32 games final, …\n  elapsed: 240s (play)\n",
    "conclude" => "  broadcast: #{SETTLE}\n  confirmed: {\"status\" => \"confirmed\", \"contest_status\" => \"settled\", " \
                  "\"onchain_settled\" => true, \"tx_signature\" => \"#{SETTLE}\"}\n  elapsed: 140s (conclude)\n",
    "close" => "  closed: {\"already_closed\" => false, \"signature\" => \"#{CLOSE}\"}\n  elapsed: 75s (close)\n"
  }.freeze

  WINNERS = [
    { "rank" => 1, "user" => "mack", "wallet" => MACK, "payout_cents" => 30_000 },
    { "rank" => 2, "user" => "turf", "wallet" => TURF, "payout_cents" => 10_000 }
  ].freeze

  def balance(owner, amount) = { "owner" => owner, "mint" => MINT, "uiTokenAmount" => { "amount" => amount.to_s, "decimals" => 6 } }

  # USDC has 6 decimals: a cent is 10_000 base units.
  def settle_tx(escrow_fall: 400_000_000, mack_rise: 300_000_000, turf_rise: 100_000_000)
    { "meta" => { "err" => nil,
                  "preTokenBalances" => [balance(ESCROW, 500_000_000), balance(MACK, 1_000), balance(TURF, 0)],
                  "postTokenBalances" => [balance(ESCROW, 500_000_000 - escrow_fall), balance(MACK, 1_000 + mack_rise),
                                          balance(TURF, turf_rise)] } }
  end

  # `step_seconds` is how long each step takes on the fake clock; `budgets` collects
  # what the run hands the driver as the overall deadline's remaining seconds.
  def gauntlet(outputs: {}, codes: {}, winners: WINNERS, tx: settle_tx, deadline: nil, step_seconds: {}, budgets: [])
    calls = []
    now = 0.0
    driver = lambda do |argv, budget|
      calls << argv
      budgets << budget
      label = argv.first
      now += step_seconds.fetch(label, 0)
      [outputs.fetch(label, GREEN.fetch(label)), codes.fetch(label, true)]
    end
    result = Run.new(driver: driver, manifest: -> { { "contest_slug" => "rehearsal-abc", "winners" => winners } },
                     transaction: ->(sig) { sig == SETTLE ? tx : nil }, deadline: deadline,
                     deadline_env: "RELEASE_GAUNTLET_DEADLINE", clock: -> { now }).call
    [result, calls]
  end

  def test_green_path_runs_every_step_unattended_and_carries_the_record
    result, calls = gauntlet

    assert result.ok?
    assert_equal [%w[seed], %w[create], %w[enter], %w[play], %w[conclude --cosign agent], %w[close]], calls,
                 "the SOP's unattended order: a bare play, conclude co-signed by the agent key"
    meta = result.metadata
    assert_equal "rehearsal-abc", meta["contest"]
    assert_equal SETTLE, meta["settle_signature"]
    assert_equal CLOSE, meta["close_signature"]
    assert_equal({ "paid_cents" => 40_000, "escrow_owner" => ESCROW, "winners" => 2 }, meta["arithmetic"])
    assert_equal 240, meta.dig("steps", "play", "elapsed")
  end

  def test_old_ruby_inspect_spacing_still_parses
    result, = gauntlet(outputs: {
                    "conclude" => "  confirmed: {\"onchain_settled\"=>true, \"tx_signature\"=>\"#{SETTLE}\"}\n",
                    "close" => "  closed: {\"already_closed\"=>false, \"signature\"=>\"#{CLOSE}\"}\n"
                  })
    assert result.ok?, result.reason
  end

  def test_a_red_step_stops_the_run_and_names_the_step
    result, calls = gauntlet(outputs: { "play" => "replay: CATCH-UP FAILED — game x reads 3, its plays sum 7\n" },
                        codes: { "play" => false })

    refute result.ok?
    assert_equal "play", result.step
    assert_includes result.reason, "CATCH-UP FAILED — game x"
    assert_equal "play", result.metadata["failed_step"]
    assert_equal "rehearsal-abc", result.metadata["contest"], "what was learned before the red step rides the fail"
    refute_includes calls, %w[conclude --cosign agent], "nothing after a red step runs"
  end

  def test_a_driver_stop_is_red_even_when_it_reads_like_success
    result, = gauntlet(outputs: { "create" => "STOPPED — the devnet VaultState cannot be read\n" }, codes: { "create" => false })
    assert_equal "create", result.step
    assert_includes result.reason, "VaultState cannot be read"
  end

  def test_a_non_zero_exit_names_the_real_error_not_the_trailing_elapsed_line
    result, = gauntlet(outputs: { "enter" => "RuntimeError: wallet session refused\n  elapsed: 3s (enter)\n" },
                       codes: { "enter" => false })
    assert_equal "enter", result.step
    assert_includes result.reason, "RuntimeError: wallet session refused"
    refute_includes result.reason, "elapsed"
  end

  def test_a_non_zero_exit_is_red_without_a_stop_line
    result, = gauntlet(codes: { "seed" => false })
    assert_equal "seed", result.step
    assert_includes result.reason, "exited non-zero"
  end

  def test_each_step_check_holds_on_its_own
    {
      "create" => "  contest:  rehearsal-abc\n  on-chain: no · pool $500\n",
      "enter" => "  1 of 2 FAILED\n",
      "play" => "replay: done — 246 plays\n",
      "conclude" => "  confirmed: {\"onchain_settled\" => false, \"tx_signature\" => \"x\"}\n",
      "close" => "  closed: {\"already_closed\" => true}\n"
    }.each do |label, output|
      result, = gauntlet(outputs: { label => output })
      refute result.ok?, "#{label} should go red on #{output.inspect}"
      assert_equal label, result.step
    end
  end

  def test_the_escrow_must_fall_by_exactly_the_sum_paid
    result, = gauntlet(tx: settle_tx(escrow_fall: 410_000_000))
    assert_equal "arithmetic", result.step
    assert_includes result.reason, "prize escrow fell by 410000000"
  end

  def test_each_winner_must_rise_by_exactly_its_rank_payout
    result, = gauntlet(tx: settle_tx(turf_rise: 90_000_000))
    assert_equal "arithmetic", result.step
    assert_includes result.reason, "winner #{TURF} rose by 90000000"
  end

  def test_a_failed_settle_or_missing_transaction_is_red
    result, = gauntlet(tx: { "meta" => { "err" => { "InstructionError" => [0, "Custom"] } } })
    assert_equal "arithmetic", result.step
    assert_includes result.reason, "failed on chain"

    result, = gauntlet(tx: nil)
    assert_equal "arithmetic", result.step
  end

  def test_a_raising_effect_is_red_not_an_exception
    driver = ->(_argv, _budget) { raise IOError, "pipe closed" }
    result = Run.new(driver: driver, manifest: -> { {} }, transaction: ->(_) { }).call
    refute result.ok?
    assert_equal "seed", result.step
    assert_includes result.reason, "IOError: pipe closed"
  end

  # --- the overall deadline: six steps at a 1200s step bound must not hold prepare
  # for two hours ---------------------------------------------------------------

  def test_without_an_overall_deadline_the_driver_gets_no_budget
    budgets = []
    result, = gauntlet(budgets: budgets)
    assert result.ok?
    assert_equal [nil] * 6, budgets
  end

  def test_each_step_is_handed_what_the_overall_deadline_leaves
    budgets = []
    result, = gauntlet(deadline: 1800, step_seconds: { "seed" => 30, "create" => 50, "play" => 240 }, budgets: budgets)
    assert result.ok?, result.reason
    assert_equal [1800, 1770, 1720, 1720, 1480, 1480], budgets.map(&:round)
  end

  def test_the_deadline_running_out_between_steps_is_red_naming_the_next_step
    result, calls = gauntlet(deadline: 1800, step_seconds: { "play" => 1800 })

    refute result.ok?
    assert_equal "conclude", result.step, "the step that could not start is the one named"
    assert_includes result.reason, "overall deadline of 1800s ran out before step `conclude` started"
    assert_includes result.reason, "RELEASE_GAUNTLET_DEADLINE sets it"
    assert_equal "conclude", result.metadata["failed_step"]
    refute_includes calls, %w[conclude --cosign agent], "no step starts once the deadline has passed"
  end

  def test_a_step_killed_by_the_overall_deadline_is_the_deadlines_red_not_the_steps
    result, = gauntlet(deadline: 600, step_seconds: { "play" => 600 },
                       outputs: { "play" => "replay: polling\n✗ `bin/qa-contest-rehearsal play` gave no answer within 600s\n" },
                       codes: { "play" => false })

    assert_equal "play", result.step
    assert_includes result.reason, "overall deadline of 600s ran out during step `play`"
  end

  def test_a_step_that_fails_inside_the_deadline_keeps_its_own_reason
    result, = gauntlet(deadline: 1800, step_seconds: { "enter" => 10 }, codes: { "enter" => false },
                       outputs: { "enter" => "RuntimeError: wallet session refused\n" })

    assert_equal "enter", result.step
    assert_includes result.reason, "wallet session refused"
    refute_includes result.reason, "deadline"
  end
end
