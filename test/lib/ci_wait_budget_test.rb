# frozen_string_literal: true

# [unit] bin/submit's CI wait budget, bin/lib/ci_wait_budget.rb: the p90 of the repo's
# recent green PR CI plus a margin, between the old 900 s floor and release's structural
# ceiling. Pure: no clock, no gh. The integration half (bin/submit reads the history,
# prints the budget, and records a timeout on the board) is in test/lib/submit_test.rb.
# History: task ci-retry-killers.
require "minitest/autorun"
require "json"
require_relative "../../bin/lib/ci_wait_budget"

class CiWaitBudgetTest < Minitest::Test
  T0 = Time.utc(2026, 11, 6, 12, 0, 0)

  def run_row(sha, start_offset, end_offset)
    { "head_sha" => sha, "run_started_at" => (T0 + start_offset).iso8601,
      "updated_at" => (T0 + end_offset).iso8601 }
  end

  def runs_json(*rows) = JSON.generate("workflow_runs" => rows)

  # ── settle times ───────────────────────────────────────────────────────────

  def test_one_sha_settles_when_its_last_parallel_workflow_ends
    json = runs_json(run_row("a", 0, 300), run_row("a", 10, 1_200), run_row("a", 5, 600))

    assert_equal [1_200], CiWaitBudget.settle_seconds(json)
  end

  def test_each_sha_is_its_own_sample
    json = runs_json(run_row("a", 0, 600), run_row("b", 0, 900))

    assert_equal [600, 900], CiWaitBudget.settle_seconds(json).sort
  end

  def test_rows_without_timestamps_and_unparseable_text_yield_nothing
    json = runs_json({ "head_sha" => "a", "run_started_at" => nil, "updated_at" => T0.iso8601 })

    assert_empty CiWaitBudget.settle_seconds(json)
    assert_empty CiWaitBudget.settle_seconds("not json")
    assert_empty CiWaitBudget.settle_seconds("")
  end

  # ── percentile ─────────────────────────────────────────────────────────────

  def test_nearest_rank_p90
    assert_equal 9, CiWaitBudget.percentile((1..10).to_a)
    assert_equal 18, CiWaitBudget.percentile((1..20).to_a.shuffle(random: Random.new(1)))
    assert_equal 5, CiWaitBudget.percentile([5])
    assert_nil CiWaitBudget.percentile([])
  end

  # ── the budget ─────────────────────────────────────────────────────────────

  def test_the_budget_is_measured_p90_plus_margin
    samples = [600, 700, 800, 900, 1_000, 1_100, 1_200, 1_300, 1_400, 1_500]
    budget = CiWaitBudget.budget(samples, ceiling: 7_200)

    assert budget.measured?
    assert_equal 1_400, budget.p90_s
    assert_equal 1_400 + CiWaitBudget::MARGIN_S, budget.timeout_s
    assert_equal 10, budget.samples
  end

  def test_a_fast_repo_never_waits_less_than_the_old_floor
    budget = CiWaitBudget.budget([60] * 10, ceiling: 7_200)

    assert_equal CiWaitBudget::FLOOR_S, budget.timeout_s
  end

  def test_the_structural_ceiling_bounds_a_freak_history
    budget = CiWaitBudget.budget([20_000] * 10, ceiling: 2_400)

    assert_equal 2_400, budget.timeout_s
  end

  def test_too_few_samples_keep_the_floor
    budget = CiWaitBudget.budget([3_000] * (CiWaitBudget::MIN_SAMPLES - 1), ceiling: 7_200)

    refute budget.measured?
    assert_equal CiWaitBudget::FLOOR_S, budget.timeout_s
    assert_match(/fewer than #{CiWaitBudget::MIN_SAMPLES}/, CiWaitBudget.describe(budget))
  end

  # The case the task was filed over: engine PR CI p50 ~15.5 min, so 900 s cut the wait
  # off before green on about half the submits.
  def test_engine_shaped_history_waits_past_the_old_900s
    samples = [840, 900, 930, 960, 1_000, 1_020, 1_100, 1_200, 1_260, 1_380]
    budget = CiWaitBudget.budget(samples, ceiling: 7_200)

    assert_operator budget.timeout_s, :>, 1_260, "the budget must outlast the p90 run"
    assert_match(/p90 1260s over 10/, CiWaitBudget.describe(budget))
  end

  # ── the ceiling reuses release's structural budget ─────────────────────────

  def test_the_ceiling_is_release_s_needs_chain_budget
    workflow = <<~YAML
      on: [pull_request]
      jobs:
        a:
          runs-on: ubuntu-24.04
          timeout-minutes: 20
        b:
          needs: a
          runs-on: ubuntu-24.04
          timeout-minutes: 10
    YAML
    expected = CiPollBudget.budget_s({ "ci.yml" => workflow }, floor: CiWaitBudget::FLOOR_S,
                                                               ceiling: CiWaitBudget::CEILING_S)

    assert_equal expected, CiWaitBudget.ceiling_s({ "ci.yml" => workflow })
    assert_equal (30 * 60) + CiPollBudget::HEADROOM_S, expected
    assert_equal CiWaitBudget::CEILING_S, CiWaitBudget.ceiling_s({})
  end

  def test_repo_from_pr_url
    assert_equal "McRitchie-Studio/studio-engine",
                 CiWaitBudget.repo_from_pr_url("https://github.com/McRitchie-Studio/studio-engine/pull/812")
    assert_nil CiWaitBudget.repo_from_pr_url("")
  end

  def test_the_timeout_note_names_the_state_budget_and_resume
    note = CiWaitBudget.timeout_note(state: :pending, waited_s: 1_502.4, budget_s: 1_500, basis: "measured",
                                     pr_url: "https://github.com/o/r/pull/1", resume: "bin/submit demo")

    assert_match(/SUBMIT CI WAIT TIMED OUT/, note)
    assert_match(/still pending on https:\/\/github.com\/o\/r\/pull\/1 after 1502s/, note)
    assert_match(/budget 1500s, measured/, note)
    assert_match(/bin\/submit demo\z/, note)
  end
end
