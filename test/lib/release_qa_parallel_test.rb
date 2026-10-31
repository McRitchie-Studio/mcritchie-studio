# frozen_string_literal: true

# [unit] prepare's QA deploys run concurrently, and Turf's devnet gauntlet starts as
# soon as Turf QA boots (task release-pins-swept-sha, part 2; run_qa_deploys).
#
# Before: Turf QA deploy, its boot poll, then the hub's qa-deploy.yml run and its
# boot poll, then the gauntlet — the release log of 2026-10-30 spent minutes waiting
# on a hub deploy the gauntlet never needed. These stub every outside seam in the
# child (the deploy commands, the boot poll, the hooks, the gauntlet, the board) and
# read the ORDER the threads printed in.
#
#   ruby -Itest test/lib/release_qa_parallel_test.rb
require_relative "release_cli_harness"

class ReleaseQaParallelTest < ReleaseCliHarness
  HUB = { "repo" => "mcritchie-studio", "kind" => "app", "qa_app" => "mcritchie-studio",
          "prod_deploy" => { "strategy" => "github_actions" }, "members" => [{ "slug" => "t-hub" }] }.freeze
  TURF = { "repo" => "turf-monster", "kind" => "app", "qa_app" => "turf-monster",
           "members" => [{ "slug" => "t-turf" }] }.freeze
  VAULT = { "repo" => "turf-vault", "kind" => "gem", "members" => [] }.freeze

  def run_qa(groups:, hub: "ok", turf_boot: true, dry: false, repos: nil)
    setup = <<~RUBY
      def repo_path(_repo) = #{self.class.stub_repo.inspect}
      def say_event(text) = $stdout.puts(text)
      def sh(*a, **k)
        repo = Release::ParallelDeploy.current_repo.to_s
        return ["sha-" + (repo.empty? ? "solo" : repo), true] if a[0] == "git" && a.include?("rev-parse")
        return ["", true] if a[0] == "git"
        if a[0] == "bin/qa-server"
          say_event("TURF-DEPLOY")
          sleep 0.2
          return ["", true]
        end
        ["", true]
      end
      def dispatch_and_watch(_wf, inputs = {}, chdir: nil)
        say_event("HUB-DEPLOY-START " + inputs["sha"].to_s)
        abort!("hub dispatch exploded") if #{(hub == 'abort').inspect}
        sleep 1.5
        say_event("HUB-DEPLOY-END")
        #{hub == 'ok'}
      end
      def wait_for_boot(url)
        booted = url.include?("turf") ? #{turf_boot} : true
        say_event("BOOT " + url + " " + booted.to_s)
        booted
      end
      def run_post_deploy(groups, target:)
        say_event("HOOKS " + groups.map { |g| g["repo"] }.join(",") + " " + target.to_s)
      end
      def prepare_devnet_gauntlet!(rel, repos, skip:, shas:)
        say_event("GAUNTLET-START " + JSON.generate(shas.sort.to_h))
        :completed
      end
      def record_release_event(slug, step, status, attrs = {}) = say_event("EVENT " + step + ":" + status)
    RUBY
    call = "begin; r = run_qa_deploys(#{groups.inspect}, 'rel-q', repos: #{(repos || groups).inspect}, " \
           "qa_shas: { 'turf-vault' => 'vault1' }, skip_gauntlet: false); " \
           "puts('RESULT ' + JSON.generate(r)); rescue SystemExit => e; puts('ABORTED ' + e.message); end"
    run_cli(dry ? ["--dry-run"] : [], setup: setup, call: call)
  end

  def result(out)
    line = out.lines.find { |l| l.start_with?("RESULT ") }
    line && JSON.parse(line.delete_prefix("RESULT "))
  end

  def test_both_deploys_run_at_once_and_the_gauntlet_starts_before_the_hub_finishes
    out = run_qa(groups: [HUB, TURF], repos: [HUB, TURF, VAULT])
    r = result(out)

    refute_nil r, out
    assert_equal [true, true], r["deployed"].map { |d| d["ok"] }
    assert_equal %w[mcritchie-studio turf-monster], r["deployed"].map { |d| d["repo"] }, "group order is kept"
    assert_equal "completed", r["gauntlet"]
    assert_equal ["turf-monster"], r["hooks_ran"]
    assert r["qa_smoke_started"]

    hub_start = out.index("HUB-DEPLOY-START")
    hub_end = out.index("HUB-DEPLOY-END")
    turf = out.index("TURF-DEPLOY")
    gauntlet = out.index("GAUNTLET-START")
    assert hub_start && hub_end && turf && gauntlet, out
    assert turf < hub_end, "Turf deploys while the hub's deploy is still running"
    assert out.index("HOOKS turf-monster qa") < gauntlet, "Turf's own hooks run before its gauntlet"
    assert gauntlet < hub_end, "the gauntlet waits on Turf's boot only, never on the hub's deploy"
    assert_equal 1, out.scan("EVENT qa_smoke:started").size, "qa_smoke starts once, whichever app is first"
  end

  def test_the_gauntlet_is_bound_to_turf_and_the_frozen_vault_sha
    out = run_qa(groups: [HUB, TURF], repos: [HUB, TURF, VAULT])

    shas = JSON.parse(out[/GAUNTLET-START (\{.*\})/, 1])
    assert_equal({ "turf-monster" => "sha-turf-monster", "turf-vault" => "vault1" }, shas)
  end

  def test_each_line_names_its_repo_and_the_batch_is_summarised
    out = run_qa(groups: [HUB, TURF])

    assert_includes out, "[turf-monster] TURF-DEPLOY"
    assert_includes out, "[mcritchie-studio] HUB-DEPLOY-START"
    assert_includes out, "qa deploy: 2 apps CONCURRENTLY (mcritchie-studio, turf-monster)"
    assert_includes out, "QA deploys (2/2 finished):"
  end

  def test_a_turf_boot_failure_runs_no_gauntlet_and_leaves_the_hub_green
    out = run_qa(groups: [HUB, TURF], turf_boot: false)
    r = result(out)

    assert_equal({ "mcritchie-studio" => true, "turf-monster" => false },
                 r["deployed"].to_h { |d| [d["repo"], d["ok"]] }, "the failed repo is named by its own row")
    assert_nil r["gauntlet"]
    refute_includes out, "GAUNTLET-START", "a Turf QA that never booted is never rehearsed"
    refute_includes out, "HOOKS", "no hook runs on an app that did not boot"
  end

  def test_an_aborted_deploy_stops_prepare_naming_the_repo_after_the_others_finish
    out = run_qa(groups: [HUB, TURF], hub: "abort")

    assert_includes out, "ABORTED ✗ QA deploy ABORTED in mcritchie-studio: mcritchie-studio — hub dispatch exploded"
    assert_includes out, "GAUNTLET-START", "the other app's thread ran to its own end"
    assert out.index("GAUNTLET-START") < out.index("ABORTED"), "the abort waits for every thread"
    refute_includes out, "RESULT"
  end

  def test_one_app_deploys_inline_with_its_gauntlet_and_no_prefix
    out = run_qa(groups: [TURF])
    r = result(out)

    refute_includes out, "CONCURRENTLY"
    refute_includes out, "[turf-monster]"
    assert_equal "completed", r["gauntlet"]
    assert_equal ["turf-monster"], r["hooks_ran"]
  end

  def test_a_dry_run_previews_in_order_and_leaves_the_gauntlet_to_its_old_place
    out = run_qa(groups: [HUB, TURF], dry: true)
    r = result(out)

    refute_includes out, "CONCURRENTLY", "a preview prints in a fixed order"
    assert_nil r["gauntlet"], "prepare previews the gauntlet after the deploys, as it always did"
    assert_empty r["hooks_ran"]
  end
end
