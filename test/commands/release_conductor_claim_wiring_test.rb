# frozen_string_literal: true

require "test_helper"

# Guards the WIRING of the per-release conductor claim into bin/release.rb (the seam
# that can't be unit-tested without booting a full prepare/ship against heroku+git):
# the assembler/deployer claim must be taken BEFORE the irreversible work, must STAND
# DOWN on a live different holder, and must be RELEASED on completion — and the retired
# `steffon` shift lane must be gone.
#
# The claim's BEHAVIOR (the atomic CAS, exit-code contract, detached renewer identity,
# holder_label/acquired_at reset, the two roles' independence) is proven behaviorally
# elsewhere:
#   test/models/release_conductor_claim_test.rb            (the lease math + CAS)
#   test/controllers/api/v1/release_conductor_claims_controller_test.rb (the endpoints)
#   test/lib/release_claim_cli_test.rb                     (the CLI, FakeApi)
#   test/lib/release_claim_renewer_integration_test.rb     (a REAL detached renewer + stub board)
# This file is the structural tripwire that those behaviors are actually invoked at the
# right place in the release lifecycle — the split ship_index_refresh_test.rb uses.
class ReleaseConductorClaimWiringTest < ActiveSupport::TestCase
  RELEASE_RB   = Rails.root.join("bin", "release.rb")
  DEVOPS_SHIFT = Rails.root.join("bin", "devops-shift")

  def release_lines = @release_lines ||= File.read(RELEASE_RB).lines

  def index(pattern)
    release_lines.index { |l| l =~ pattern }
  end

  # --- prepare: assembler claim BEFORE the irreversible promote ----------------
  test "prepare takes the assembler claim before promoting accepted → release" do
    acquire = index(/acquire_conductor_claim!\("assembler"/)
    # prepare's promote (label: slug) — NOT the `merge` command's earlier promote.
    promote = index(/promote_accepted_to_release!\(promote_repos, label: slug\)/)

    assert acquire, "bin/release prepare must acquire the `assembler` conductor claim"
    assert promote, "bin/release prepare must still promote accepted → release"
    assert acquire < promote,
           "the assembler claim must be taken BEFORE the irreversible promote, or two concurrent qa-release " \
           "sessions can both sweep the same release N-behind"
  end

  # --- ship: deployer claim BEFORE any deploy mutation -------------------------
  test "ship takes the deployer claim before the ship preflight/deploy" do
    acquire   = index(/acquire_conductor_claim!\("deployer", rel_slug\)/)
    preflight = index(/ship_preflight\(app_groups, gem_groups, ship_sha\)/)

    assert acquire, "bin/release ship must acquire the `deployer` conductor claim"
    assert preflight, "bin/release ship must still run ship_preflight"
    assert acquire < preflight,
           "the deployer claim must be taken BEFORE the frozen-SHA gate + deploy, or a second concurrent ship " \
           "double-deploys the release"
  end

  # --- the decision: stand down on a live holder, resume otherwise -------------
  test "acquire_conductor_claim! aborts (stands down) on a live different holder and records the claim on success" do
    src = File.read(RELEASE_RB)
    body = src[/^def acquire_conductor_claim!.*?^end$/m]
    assert body, "acquire_conductor_claim! must be defined"
    assert_match(/ReleaseClaimCli::STOOD_DOWN/, body, "it must branch on the stand-down exit code")
    assert_match(/abort!/, body, "a live DIFFERENT holder must ABORT the run (stand down)")
    assert_match(/ReleaseClaimCli::OK/, body, "and record the held claim on a successful acquire")
    assert_match(/return if @conductor_claim/, body, "idempotent per run — a resumed ship re-acquire is a no-op renew")
  end

  # --- the claim is dropped on completion (both success AND abort) -------------
  test "prepare and ship both release the conductor claim on completion" do
    assert_operator release_lines.count { |l| l =~ /release_conductor_claim!/ }, :>=, 4,
                    "prepare + ship must each release the claim on BOTH the success path and the abort rescue"
  end

  # --- transport: the claim runs over the fast HTTP CLI, not a heroku-run dyno --
  test "the conductor claim goes through the fast HTTP release_claim_cli, never a per-heartbeat heroku run" do
    src = File.read(RELEASE_RB)
    assert_match(%r{RELEASE_CLAIM_CLI = File\.expand_path\("lib/release_claim_cli\.rb"}, src,
                 "bin/release must shell out to the HTTP claim CLI")
    conductor_claim = src[/^def conductor_claim\b.*?^end$/m]
    assert conductor_claim, "conductor_claim helper must be defined"
    refute_match(/heroku/i, conductor_claim.to_s,
                 "the claim heartbeat must NOT go through `heroku run` — a dyno per 30s renew is unacceptable")
  end

  # --- retirement: the steffon shift lane is gone; avi stays -------------------
  test "the steffon shift lane is retired from DevopsShift and bin/devops-shift; avi stays" do
    refute_includes DevopsShift::LANES, "steffon",
                    "the qa-release lock moved onto the release record — steffon is no longer a shift lane"
    assert_includes DevopsShift::LANES, "avi", "clean-up still takes the avi shift, so the avi lane stays"

    shift_src = File.read(DEVOPS_SHIFT)
    assert_match(/LANES = %w\[avi alex\]\.freeze/, shift_src, "bin/devops-shift drops steffon from its default set")
  end

  # --- the model/table stays (avi lane still uses it) --------------------------
  test "the DevopsShift model + table are KEPT — only the steffon lane retired" do
    assert DevopsShift.table_exists?, "the devops_shifts table stays — the avi lane is still live"
    # A steffon row would still WORK (no inclusion validation) — retirement is about
    # nothing ACQUIRING it, not about forbidding the string.
    assert DevopsShift.new(lane: "avi").valid?, "the avi lane is a valid shift"
  end
end
