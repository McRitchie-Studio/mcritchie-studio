require "test_helper"
require "tmpdir"
require "fileutils"

class Release
  # Regression: rel-20260925-3b1f5c — the post-ship seal ran bin/prod-smoke from
  # the hub PRIMARY, which still held the PRE-ship tree, so it smoked the old
  # specs against the new prod and recorded a false red. Release::SealTree decides
  # where the seal runs (the ship workspace at the frozen SHA, never the primary)
  # and refuses — UNSEALED, not red — when the shipped specs cannot run.
  class SealTreeTest < ActiveSupport::TestCase
    FROZEN = "cafebabe11111111111111111111111111111111".freeze

    # A runnable ship workspace: the smoke script and the playwright runner.
    def with_workspace(script: true, playwright: true)
      Dir.mktmpdir do |dir|
        if script
          FileUtils.mkdir_p(File.join(dir, "bin"))
          File.write(File.join(dir, SealTree::SCRIPT), "#!/bin/sh\n")
          File.chmod(0o755, File.join(dir, SealTree::SCRIPT))
        end
        if playwright
          FileUtils.mkdir_p(File.join(dir, "node_modules", ".bin"))
          File.write(File.join(dir, SealTree::PLAYWRIGHT), "#!/bin/sh\n")
          File.chmod(0o755, File.join(dir, SealTree::PLAYWRIGHT))
        end
        File.write(File.join(dir, SealTree::LOCKFILE), "{}\n")
        SealTree.stamp_deps!(dir) if playwright
        yield dir
      end
    end

    test "[unit] a workspace pinned at the frozen SHA is where the seal runs" do
      with_workspace do |dir|
        verdict = SealTree.resolve(workspace: dir, frozen_sha: FROZEN, head_sha: FROZEN)
        assert_predicate verdict, :runnable?
        assert_equal dir, verdict.root, "the seal runs from the ship workspace itself"
      end
    end

    test "[unit] an abbreviated frozen SHA names the same commit" do
      with_workspace do |dir|
        assert_predicate SealTree.resolve(workspace: dir, frozen_sha: FROZEN[0, 7], head_sha: "#{FROZEN}\n"), :runnable?
      end
    end

    test "[unit] a workspace at another SHA refuses and names both SHAs" do
      with_workspace do |dir|
        verdict = SealTree.resolve(workspace: dir, frozen_sha: FROZEN, head_sha: "deadbeef" * 5)
        refute_predicate verdict, :runnable?
        assert_nil verdict.root, "a refusal offers no tree — not even a fallback to the primary"
        assert_includes verdict.reason, "deadbee"
        assert_includes verdict.reason, "cafebab"
      end
    end

    test "[unit] a blank frozen SHA or HEAD refuses" do
      with_workspace do |dir|
        assert_includes SealTree.resolve(workspace: dir, frozen_sha: " ", head_sha: FROZEN).reason, "no frozen ship SHA"
        refute_predicate SealTree.resolve(workspace: dir, frozen_sha: FROZEN, head_sha: ""), :runnable?
      end
    end

    test "[unit] a missing workspace refuses" do
      verdict = SealTree.resolve(workspace: "/nonexistent/_ship", frozen_sha: FROZEN, head_sha: FROZEN)
      assert_equal "the ship workspace is missing", verdict.reason
      assert_equal "the ship workspace is missing", SealTree.resolve(workspace: nil, frozen_sha: FROZEN, head_sha: FROZEN).reason
    end

    test "[unit] a shipped tree without bin/prod-smoke refuses" do
      with_workspace(script: false) do |dir|
        assert_includes SealTree.resolve(workspace: dir, frozen_sha: FROZEN, head_sha: FROZEN).reason, "bin/prod-smoke"
      end
    end

    test "[unit] a workspace without playwright refuses rather than smoking red" do
      with_workspace(playwright: false) do |dir|
        assert_includes SealTree.resolve(workspace: dir, frozen_sha: FROZEN, head_sha: FROZEN).reason, "playwright"
      end
    end

    test "[unit] the unsealed summary says the specs could not run, never FAILED" do
      summary = SealTree.summary("the ship workspace is missing")
      assert_equal "unsealed: could not run the shipped specs — the ship workspace is missing", summary
      refute_includes summary, "FAILED"
      refute_includes SmokeSeal::STATUSES, SealTree::UNSEALED,
                      "unsealed is the ABSENCE of a seal, never a stored seal status"
    end

    test "[unit] same_commit? matches prefixes and never a blank" do
      assert SealTree.same_commit?(FROZEN, FROZEN[0, 7].upcase)
      refute SealTree.same_commit?(FROZEN, "")
      refute SealTree.same_commit?("", "")
      refute SealTree.same_commit?(FROZEN, "deadbeef")
    end
    # --- reseal_plan (bin/release reseal) ------------------------------------
    HUB_GROUP = { "repo" => "mcritchie-studio", "kind" => "app" }.freeze

    def plan(**overrides)
      SealTree.reseal_plan(**{ state: "shipped", repos: [HUB_GROUP], qa_shas: { "mcritchie-studio" => FROZEN },
                               deployed_sha: "deadbeef", app: "mcritchie-studio" }.merge(overrides))
    end

    test "[unit] a shipped hub release re-seals at its QA-frozen SHA" do
      p = plan
      assert_nil p.refusal
      assert_equal FROZEN, p.frozen_sha, "the QA-frozen SHA wins over deployed_sha"
      assert_equal HUB_GROUP, p.group
      assert_equal "re-sealed from the shipped tree", p.note
    end

    test "[unit] reseal falls back to deployed_sha, never to a moving branch" do
      assert_equal "deadbeef", plan(qa_shas: {}).frozen_sha
      assert_includes plan(qa_shas: nil, deployed_sha: nil).refusal, "no frozen mcritchie-studio SHA"
    end

    test "[unit] reseal refuses a release that is not shipped" do
      assert_includes plan(state: "assembled").refusal, "not shipped"
    end

    test "[unit] reseal refuses a release that did not deploy the hub" do
      assert_includes plan(repos: [{ "repo" => "turf-monster", "kind" => "app" }]).refusal, "nothing to seal"
      assert_includes plan(repos: [{ "repo" => "mcritchie-studio", "kind" => "gem" }]).refusal, "nothing to seal"
    end

    test "[unit] a superseded release still re-seals, and its note says prod moved" do
      p = plan(superseded_by: "rel-20260926-abc123")
      assert_nil p.refusal
      assert_equal "re-sealed from the shipped tree; prod has since moved to rel-20260926-abc123", p.note
    end

    # --- the node-deps stamp (stale deps are a false red) ----------------------
    test "[unit] deps are current only when the stamp names the shipped lockfile" do
      with_workspace do |dir|
        assert SealTree.deps_current?(dir)
        File.write(File.join(dir, SealTree::LOCKFILE), %({"playwright":"2"}\n))
        refute SealTree.deps_current?(dir), "a bumped lockfile makes the installed deps stale"
        verdict = SealTree.resolve(workspace: dir, frozen_sha: FROZEN, head_sha: FROZEN)
        assert_includes verdict.reason, "node deps do not match the shipped package-lock.json"
        SealTree.stamp_deps!(dir)
        assert SealTree.deps_current?(dir), "a successful reinstall re-stamps"
      end
    end

    test "[unit] no stamp, no lockfile, or no playwright means reinstall" do
      with_workspace do |dir|
        File.delete(File.join(dir, SealTree::DEPS_STAMP))
        refute SealTree.deps_current?(dir), "deps installed by something other than the seal are not trusted"
      end
      with_workspace do |dir|
        File.delete(File.join(dir, SealTree::LOCKFILE))
        refute SealTree.deps_current?(dir)
      end
      with_workspace(playwright: false) { |dir| refute SealTree.deps_current?(dir) }
    end

    test "[unit] npm ci is bounded at 600s unless overridden" do
      assert_equal 600, SealTree::NPM_CI_TIMEOUT_SECONDS
      ENV[SealTree::NPM_CI_TIMEOUT_ENV] = "2"
      assert_in_delta 2.0, SealTree.npm_ci_timeout
    ensure
      ENV.delete(SealTree::NPM_CI_TIMEOUT_ENV)
    end
  end
end
