# frozen_string_literal: true

# bin/dor-check's PROGRAM UPGRADE CARDS refusal: a PR that bumps an on-chain
# program's version (config/onchain_programs.yml) does not merge until every
# cluster's upgrade card is on the board. Standalone (no Rails):
#   ruby -Itest test/lib/dor_check_program_upgrade_cards_test.rb
#
# WHY. turf-vault v0.26 merged to main on 2026-10-11 with no upgrade card, and both
# clusters stayed on v0.25.0, because the release lane never ships a program. The
# check runs at the merge phase, so the builder's handoff and the reviewer's
# gate-zero (`--gate-role review`, run before every merge into `accepted`) both
# refuse the bump.
#
# The unit half drives the check class through a real Dor::Checks::Context with
# the board as a lambda. The integration half runs the real bin/dor-check
# subprocess, which proves the plugin glob loads the check and dor-check wires the
# board reader in (DOR_CHECK_BOARD_TASKS is that reader's seam).
require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../../bin/lib/dor/checks"
require_relative "../../bin/lib/dor/check_context"
require_relative "../../bin/lib/dor/checks/program_upgrade_cards"

class DorCheckProgramUpgradeCardsTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  VERSION_FILE = "programs/turf_vault/Cargo.toml"
  PR_URL = "https://github.com/McRitchie-Studio/turf-vault/pull/41"
  CARDS = { "devnet-v026-upgrade" => "designed", "mainnet-v026-upgrade" => "designed" }.freeze
  REFUSAL = /program version bump: turf-vault/

  def setup
    @saved = ENV.fetch(Dor::Checks::ProgramUpgradeCards::SEAM, nil)
  end

  def teardown
    ENV[Dor::Checks::ProgramUpgradeCards::SEAM] = @saved
  end

  # ── [unit] the check against a Context ──────────────────────────────────────

  def run_check(changed:, versions:, cards:)
    ENV[Dor::Checks::ProgramUpgradeCards::SEAM] = JSON.generate("turf-vault" => versions)
    asked = []
    board = lambda do |slug|
      asked << slug
      raise "board down" if cards == :down

      cards[slug] ? { "slug" => slug, "stage" => cards[slug] } : nil
    end
    ctx = Dor::Checks::Context.new(gate: "merge", gate_role: "review", task: {}, devops: { "pr_url" => PR_URL },
                                   slug: "bump-task", diff_root: nil, diff_base: nil, pr_url: PR_URL,
                                   changed_files: changed, board_task: board)
    if cards == :down
      run_through_registry(ctx) # a raising check is contained by the registry
    else
      Dor::Checks::ProgramUpgradeCards.new.call(ctx)
    end
    [ctx.errors, asked]
  end

  # The registry's own containment, with ONLY this check registered (and the global
  # registry restored), so no sibling check reaches for gh or git from a unit test.
  def run_through_registry(ctx)
    saved = Dor::Checks.registry.dup
    Dor::Checks.instance_variable_set(:@registry, [Dor::Checks::ProgramUpgradeCards])
    Dor::Checks.run(:merge, ctx)
  ensure
    Dor::Checks.instance_variable_set(:@registry, saved)
  end

  def test_a_bump_with_no_cards_is_refused_naming_both
    errors, = run_check(changed: [VERSION_FILE], versions: %w[0.25.0 0.26.0], cards: {})

    assert_equal 1, errors.size
    assert_match REFUSAL, errors.first
    assert_includes errors.first, "missing: devnet-v026-upgrade, mainnet-v026-upgrade"
    assert_includes errors.first, "docs/agents/agents/steffon/sops/program-upgrade.md"
  end

  def test_a_bump_with_both_cards_passes
    errors, asked = run_check(changed: [VERSION_FILE], versions: %w[0.25.0 0.26.0], cards: CARDS)

    assert_empty errors, "the control: a bump that owns its cards merges"
    assert_equal %w[devnet-v026-upgrade mainnet-v026-upgrade], asked
  end

  def test_an_archived_card_does_not_count
    errors, = run_check(changed: [VERSION_FILE], versions: %w[0.25.0 0.26.0],
                        cards: CARDS.merge("mainnet-v026-upgrade" => "archived"))

    assert_includes errors.first, "missing: mainnet-v026-upgrade"
  end

  def test_a_patch_bump_owes_its_own_cards
    errors, = run_check(changed: [VERSION_FILE], versions: %w[0.26.0 0.26.1], cards: CARDS)

    assert_includes errors.first, "missing: devnet-v026p1-upgrade, mainnet-v026p1-upgrade",
                    "the v0.26.0 cards do not cover v0.26.1"
  end

  def test_no_version_change_asks_the_board_nothing
    errors, asked = run_check(changed: ["programs/turf_vault/src/lib.rs"], versions: %w[0.25.0 0.26.0], cards: {})
    assert_empty errors
    assert_empty asked, "a PR that leaves the version file alone is not a bump"

    errors, asked = run_check(changed: [VERSION_FILE], versions: %w[0.26.0 0.26.0], cards: {})
    assert_empty errors, "an edit to Cargo.toml that keeps the version is not a bump"
    assert_empty asked
  end

  def test_an_unreadable_new_version_refuses
    errors, = run_check(changed: [VERSION_FILE], versions: ["0.25.0", nil], cards: CARDS)

    assert_match(/new version could not be read/, errors.first)
  end

  def test_an_unreadable_board_refuses_through_the_registry
    errors, = run_check(changed: [VERSION_FILE], versions: %w[0.25.0 0.26.0], cards: :down)

    assert(errors.any? { |e| e.include?("check program_upgrade_cards FAILED to run") && e.include?("board down") },
           "a board outage is an error, never a pass: #{errors.inspect}")
  end

  # ── [integration] the real gate, end to end ─────────────────────────────────

  def task_json
    {
      "slug" => "bump-turf-vault", "title" => "Bump", "stage" => "submitted",
      "metadata" => { "devops" => {
        "kind" => "chore", "shape" => "onchain", "pr_url" => PR_URL,
        "acceptance" => ["bump the crate"], "repositories" => ["turf-vault"], "risk_tags" => ["solana"],
        "test_plan" => ["[unit] x"], "checks_run" => ["[unit] x"], "post_deploy_cmd" => "none"
      } }
    }
  end

  def dor_check(cards)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(task_json))
      env = SessionEnv.neutralized(
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => "#{VERSION_FILE}\nCargo.lock",
        "DOR_CHECK_PR_FILES" => "#{VERSION_FILE}\nCargo.lock",
        "DOR_CHECK_PR_MIGRATIONS" => "", "DOR_CHECK_SIBLING_PRS" => "[]",
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_PROGRAM_VERSIONS" => JSON.generate("turf-vault" => %w[0.25.0 0.26.0]),
        "DOR_CHECK_BOARD_TASKS" => JSON.generate(cards)
      )
      out = IO.popen(env, [BIN, "--file", path, "--gate-role", "review", "--json"], err: File::NULL, &:read)
      JSON.parse(out)
    end
  end

  def test_integration_the_gate_refuses_a_bump_without_cards_and_passes_it_with_them
    refused = dor_check({})
    assert(Array(refused["errors"]).any? { |e| e.match?(REFUSAL) }, "refused: #{refused['errors'].inspect}")
    refute refused["ready"]

    passed = dor_check(CARDS)
    refute(Array(passed["errors"]).any? { |e| e.match?(REFUSAL) },
           "with both cards the bump is not refused: #{passed['errors'].inspect}")
  end
end
