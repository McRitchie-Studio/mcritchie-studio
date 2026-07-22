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

  # --- ship (FIX B): deployer claim BEFORE the mutable snapshot AND the deploy -
  test "ship resolves rel_slug with a minimal read, takes the deployer claim before its mutable snapshot + the preflight" do
    src = File.read(RELEASE_RB)
    ship = src[/^def ship\b.*?^end$/m]
    assert ship, "ship must be defined"

    lines = ship.lines
    minimal   = lines.index { |l| l =~ /puts\(\{slug: r\.slug\}\.to_json\)/ }              # the minimal STABLE read
    acquire   = lines.index { |l| l =~ /acquire_conductor_claim!\("deployer", rel_slug\)/ }
    snapshot  = lines.index { |l| l =~ /Release::Conductor\.repo_plan\(r\)/ }               # the MUTABLE decision snapshot
    preflight = lines.index { |l| l =~ /ship_preflight\(app_groups, gem_groups, ship_sha\)/ }

    assert [minimal, acquire, snapshot, preflight].all?, "all ship ordering anchors must be present"
    assert minimal < acquire,
           "rel_slug is resolved by a MINIMAL, STABLE read (just r.slug) BEFORE the claim — existence/slug don't drift"
    assert acquire < snapshot,
           "the deployer claim precedes the MUTABLE decision snapshot (repo_plan/state/qa_shas) — snapshot-under-claim, " \
           "so a concurrent ship/finalize can't change it between the read and the deploy"
    assert acquire < preflight,
           "the deployer claim must be held BEFORE the frozen-SHA gate + deploy, or a second concurrent ship double-deploys"
  end

  # --- the decision: stand down on a live holder, resume otherwise -------------
  test "acquire_conductor_claim! aborts (stands down) on a live different holder and records the claim on success" do
    src = File.read(RELEASE_RB)
    body = src[/^def acquire_conductor_claim!.*?^end$/m]
    assert body, "acquire_conductor_claim! must be defined"
    assert_match(/ReleaseClaimCli::STOOD_DOWN/, body, "it must branch on the stand-down exit code")
    assert_match(/abort!/, body, "a live DIFFERENT holder must ABORT the run (stand down)")
    assert_match(/ReleaseClaimCli::OK/, body, "and record the held claim on a successful acquire")
    assert_match(/return if holding_conductor_claim\?\(role, s\)/, body,
                 "idempotent per (role, slug) — no second renewer for a claim already held this run")
  end

  # --- the helper is MULTI-SLOT (sentinel + real held at once during hand-off) --
  test "the claim helpers track MULTIPLE held claims and support a targeted (role, slug) release" do
    src = File.read(RELEASE_RB)
    assert_match(/def held_conductor_claims\b/, src, "held claims are a LIST — a fresh prepare holds sentinel + real at once")
    assert_match(/@conductor_claims \|\|= \[\]/, src, "the list is the tracking slot, not a single ivar")
    release = src[/^def release_conductor_claim!.*?^end$/m]
    assert release, "release_conductor_claim! must be defined"
    assert_match(/def release_conductor_claim!\(role: nil, slug: nil\)/, release,
                 "release must support a TARGETED (role, slug) drop — the sentinel hand-off frees only the sentinel")
  end

  # --- ROUND-2 regression: bin/release is STANDALONE — no Rails-model constants ----
  # bin/release.rb never boots Rails, so a `ReleaseConductorClaim::…` reference would be
  # a NameError the instant that line executes (only surfaced by the subprocess CLI
  # test). The sentinel value comes from ReleaseClaimCli::FORMING_SLUG, defined in the
  # standalone CLI bin/release requires.
  test "bin/release.rb references NO Rails-model constant (it runs standalone, without Rails)" do
    src = File.read(RELEASE_RB)
    refute_match(/ReleaseConductorClaim/, src,
                 "bin/release runs standalone (no Rails) — a ReleaseConductorClaim reference is a runtime NameError; " \
                 "use ReleaseClaimCli::FORMING_SLUG (defined in the standalone CLI) instead")
  end

  # --- GAP 1 (FIX B): fresh assembly — the real claim is held the INSTANT rel_slug exists
  test "prepare guards a fresh promote with the FORMING sentinel, then hands off to the real claim the instant rel_slug exists" do
    src = File.read(RELEASE_RB)
    prepare = src[/^def prepare\b.*?^end$/m]
    assert prepare, "prepare must be defined"

    # A fresh create has no real slug at 2c, so it falls back to the FORMING sentinel.
    assert_match(/ReleaseClaimCli::FORMING_SLUG if assembler_slug\.empty\?/, prepare,
                 "a blank slug at 2c must fall back to the FORMING sentinel so the promote is still guarded")
    # FIX B: the hand-off runs only for a REAL created release, never the rel-pending fallback.
    assert_match(/if result\["slug"\]\.to_s\.strip != ""/, prepare,
                 "the hand-off is guarded to a real created release, not the rel-pending fallback")

    lines = prepare.lines
    sentinel_acquire = lines.index { |l| l =~ /acquire_conductor_claim!\("assembler", assembler_slug/ }
    promote          = lines.index { |l| l =~ /promote_accepted_to_release!\(promote_repos, label: slug\)/ }
    rel_slug_resolve = lines.index { |l| l =~ /rel_slug = result\["slug"\] \|\| slug \|\| "rel-pending"/ }
    real_acquire     = lines.index { |l| l =~ /acquire_conductor_claim!\("assembler", rel_slug/ }
    handoff          = lines.index { |l| l =~ /release_conductor_claim!\(role: "assembler", slug: ReleaseClaimCli::FORMING_SLUG\)/ }
    repos_print      = lines.index { |l| l =~ /say\("  release #\{rel_slug\}/ }
    record_event     = lines.index { |l| l =~ /record_release_event\(rel_slug, "assemble_release", "started"\)/ }

    assert [sentinel_acquire, promote, rel_slug_resolve, real_acquire, handoff, repos_print, record_event].all?,
           "all sentinel / hand-off / window anchors must be present"
    assert sentinel_acquire < promote,
           "the (sentinel-or-real) assembler claim must be held BEFORE the promote — the fresh-create gap the review flagged"
    assert promote < rel_slug_resolve, "rel_slug resolves after the sweep/promote"
    # THE CLOSED WINDOW: the real claim is taken the INSTANT rel_slug names a real
    # release — before the repos.empty? check, the 'release … N repos' print, and
    # record_release_event — so a session keying on rel_slug directly is excluded at once.
    assert rel_slug_resolve < real_acquire, "the real (rel_slug, assembler) claim is taken RIGHT AFTER rel_slug resolves"
    assert real_acquire < handoff,
           "acquire the real claim BEFORE freeing the sentinel — ownership is CONTINUOUS across the hand-off"
    assert real_acquire < repos_print,
           "the real claim precedes the 'release … N repos' print — the fresh-create window carl flagged is closed"
    assert real_acquire < record_event, "and precedes record_release_event — no rel_slug work runs unguarded"
  end

  # --- GAP 2 (FIX A): finalize — the deployer claim guards the MUTABLE decision snapshot
  test "finalize resolves rel_slug with a minimal read, then takes the deployer claim BEFORE the mutable snapshot, releasing in an ensure" do
    src = File.read(RELEASE_RB)
    finalize = src[/^def finalize\b.*?^end$/m]
    assert finalize, "finalize must be defined"

    lines = finalize.lines
    minimal  = lines.index { |l| l =~ /puts\(\{slug: r\.slug\}\.to_json\)/ }      # the minimal STABLE read
    acquire  = lines.index { |l| l =~ /acquire_conductor_claim!\("deployer", rel_slug\)/ }
    begin_i  = lines.index { |l| l =~ /^  begin$/ }
    snapshot = lines.index { |l| l =~ /sealed: r\.smoke_sealed\?/ }              # the MUTABLE decision snapshot
    pending  = lines.index { |l| l =~ /Release::ShipSequence\.finalize_pending\?/ }
    ship_mut = lines.index { |l| l =~ /Release::Conductor\.ship!/ }
    ensure_i = lines.index { |l| l =~ /^  ensure$/ }
    release  = lines.index { |l| l =~ /release_conductor_claim!/ }

    assert [minimal, acquire, begin_i, snapshot, pending, ship_mut, ensure_i, release].all?,
           "all finalize ordering anchors must be present"
    assert minimal < acquire,
           "rel_slug is resolved by a MINIMAL, STABLE read (just r.slug) BEFORE the claim — existence/slug don't drift"
    assert acquire < snapshot,
           "the deployer claim precedes the MUTABLE decision snapshot — snapshot-under-claim, so a concurrent " \
           "finalizer cannot complete the pending steps in the gap and leave us replaying stale work"
    assert acquire < pending, "and precedes finalize_pending? — the decision is computed UNDER the claim"
    assert acquire < begin_i, "the acquire is taken before the begin/ensure"
    assert begin_i < snapshot && snapshot < ensure_i, "the mutable snapshot read lives INSIDE the begin/ensure (under the claim)"
    assert acquire < ship_mut, "the claim is held before the record mutations"
    assert release > ensure_i, "the release lives in the ensure — EVERY finalize exit (returns, aborts, completion) frees the claim"
  end

  # --- GAP 3 (FIX 1): merge — the THIRD assembler seam is guarded too ----------
  # `merge` runs the SAME promote (accepted→release) + sweep! prepare guards, and
  # prepare routes operators to it (`bin/release merge --override`). Guard it or the
  # "no two assemblers on one release" invariant is false. Same sentinel→real hand-off.
  test "merge takes the assembler claim before its promote+sweep, hands off to the real slug, releases in an ensure" do
    src = File.read(RELEASE_RB)
    merge = src[/^def merge\b.*?^end$/m]
    assert merge, "merge must be defined"

    lines = merge.lines
    acquire  = lines.index { |l| l =~ /acquire_conductor_claim!\("assembler", assembler_slug\)/ }
    promote  = lines.index { |l| l =~ /promote_accepted_to_release!\(promote_repos\)/ }
    sweep    = lines.index { |l| l =~ /batch_sweep_ruby\(swept/ }
    real     = lines.index { |l| l =~ /acquire_conductor_claim!\("assembler", result\["slug"\]\)/ }
    handoff  = lines.index { |l| l =~ /release_conductor_claim!\(role: "assembler", slug: ReleaseClaimCli::FORMING_SLUG\)/ }
    ensure_i = lines.index { |l| l =~ /^  ensure$/ }
    release  = lines.index { |l| l =~ /^\s*release_conductor_claim!$/ }

    assert [acquire, promote, sweep, real, handoff, ensure_i, release].all?, "all merge claim anchors must be present"
    assert_match(/ReleaseClaimCli::FORMING_SLUG if assembler_slug\.empty\?/, merge,
                 "merge falls back to the FORMING sentinel when there is no active release")
    assert acquire < promote, "the assembler claim is held BEFORE the irreversible promote"
    assert promote < sweep, "promote then sweep! (the record that resolves the real slug)"
    assert sweep < real, "the real-slug claim is taken AFTER sweep! resolves it"
    assert real < handoff, "acquire the real claim BEFORE freeing the sentinel — continuous ownership across promote+sweep"
    assert release > ensure_i, "merge releases the claim in an ensure — a discrete op frees it on EVERY exit"
  end

  # --- FIX 3: prepare + ship free the claim on a NON-SystemExit error too ------
  # The rescue arms catch only SystemExit; a raw StandardError after the acquire would
  # escape with the renewer still holding the claim. An additive method-level ensure
  # frees it on ANY exception.
  test "prepare and ship free the conductor claim via a method-level ensure (any exception, not only SystemExit)" do
    src = File.read(RELEASE_RB)
    %w[prepare ship].each do |m|
      body = src[/^def #{m}\b.*?^end$/m]
      assert body, "#{m} must be defined"
      lines = body.lines
      rescue_i = lines.index { |l| l =~ /^rescue\b/ }                       # the method-level SystemExit rescue
      ensure_i = lines.index { |l| l =~ /^ensure$/ }                        # the additive method-level ensure
      release  = lines.rindex { |l| l =~ /^\s*release_conductor_claim!$/ }  # the ensure's release
      assert rescue_i, "#{m} keeps its rescue-SystemExit arm"
      assert ensure_i, "#{m} adds a method-level ensure (so a raw StandardError, not only SystemExit, releases)"
      assert rescue_i < ensure_i, "the ensure FOLLOWS the rescue — additive, not replacing the gate-close logic"
      assert release && release > ensure_i, "the method-level ensure frees the claim on ANY exception"
    end
  end

  # --- the claim is dropped on completion (success AND abort) across all paths --
  test "prepare, ship, merge, and finalize all release the conductor claim on completion/abort" do
    assert_operator release_lines.count { |l| l =~ /release_conductor_claim!/ }, :>=, 9,
                    "prepare (success/abort/hand-off/empty + ensure), ship (success/abort + ensure), merge (hand-off + " \
                    "ensure), and finalize (ensure) all free the claim"
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
