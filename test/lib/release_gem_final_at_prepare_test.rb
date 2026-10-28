# frozen_string_literal: true

# THE FINAL FLOW (the default): `bin/release prepare` publishes a gem's final x.y.z,
# consumers lock it before the pre-QA gate, and `bin/release ship` deploys those
# gated SHAs with no re-lock and no fresh consumer CI.
# docs/agents/system/gem-release-flow.md. Standalone:
#   ruby -Itest test/lib/release_gem_final_at_prepare_test.rb
#
# `gem push`, RubyGems, the CDN and every remote are stubbed. Nothing is published.
require_relative "release_cli_harness"

class ReleaseGemFinalAtPrepareTest < ReleaseCliHarness
  def setup
    super
    @gem_flow_was = ENV.delete("RELEASE_GEM_FLOW")
  end

  def teardown
    ENV["RELEASE_GEM_FLOW"] = @gem_flow_was if @gem_flow_was
    super
  end

  # Names each `gem push` and tag push.
  PUSH_LEDGER = <<~'RUBY'
    self.singleton_class.prepend(Module.new do
      def sh(*a, **k)
        puts("PUSHED " + File.basename(a[2].to_s)) if a[0] == "gem" && a[1] == "push"
        puts("TAG-PUSHED " + a.last.to_s) if a[0] == "git" && a.include?("push") && a.last.to_s.match?(/\A(rc-|v\d)/)
        super
      end
    end)
  RUBY

  # ── prepare: which version publishes, which lock commits happen ────────────

  def test_prepare_publishes_the_final_and_consumers_lock_it_before_the_gate
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "1.0.0") + PUSH_LEDGER)

    assert_equal ["PUSHED release-studio-engine-1.0.0.gem"], out.lines.grep(/^PUSHED /).map(&:strip),
                 "prepare pushes exactly one artifact, the final: #{out}"
    assert_equal ["TAG-PUSHED v1.0.0"], out.lines.grep(/^TAG-PUSHED /).map(&:strip),
                 "tagged v*, the tag the allocation and the stranded guard read; no rc- tag"
    assert_includes out, "CHECKSUM-CONFIRMED studio-engine 1.0.0 true", "the served bytes are checked against the build"
    assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=1.0.0", "consumers lock the final"
    refute_match(/\.rc\d/, out.lines.grep(/PUSHED|BUNDLE-LOCK|committed studio-engine/).join, "no candidate anywhere")

    publish = out.index("PUSHED release-studio-engine-1.0.0.gem")
    lock    = out.index("LOCK-PUSH")
    gate    = out.index("pre-QA gate mcritchie-studio")
    deploy  = out.index("QA-DEPLOY")
    assert publish && lock && gate && deploy, out
    assert_operator publish, :<, lock, "the final is live before any consumer locks it"
    assert_operator lock, :<, gate, "the lock commit is what the pre-QA gate and QA read"
    assert_operator gate, :<, deploy
  end

  # A re-run at the same gem tip: the final is live and tagged there, so nothing is
  # pushed and the version is not burned.
  def test_a_rerun_at_the_same_tip_reuses_the_live_final
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: [{ "number" => "1.0.0" }], lock_dirty: false,
                                          tag: "v1.0.0", ahead: "") + PUSH_LEDGER)

    assert_includes out, "1.0.0 is already live on RubyGems — consumers lock the final", out
    assert_empty out.lines.grep(/^(PUSHED|TAG-PUSHED) /), "a re-run publishes nothing"
    refute_includes out, "GEM-BUILD"
    assert_includes out, "QA-DEPLOY"
  end

  # A red QA whose fix moves the gem's tree: the allocation reads commits past the
  # v1.0.0 tag prepare pushed and allocates the next patch. 1.0.0 is burned, not reused.
  def test_a_red_qa_that_moves_the_gem_burns_the_final_and_allocates_the_next_patch
    out = eval_helper(<<~RUBY)
      Release::GemVersion.allocation(current: "1.0.0", tag_version: "1.0.0", live_versions: ["0.10.0", "1.0.0"],
                                     ahead_commits: ["abc fix the engine"], members: [{ "kind" => "bug" }])
                         .then { |d| [d.action, d.version].join(" ") }
    RUBY

    assert_equal "allocate 1.0.1", out
  end

  def test_the_dry_run_names_the_final_and_no_candidate
    out = run_cli(["--dry-run"], call: "prepare", setup: STUB_CONDUCTOR)

    assert_includes out, "gem final publish (producer-first", out
    assert_includes out, "gem push <version> (the FINAL) → tag v<version>"
    assert_includes out, "the ship re-locks nothing"
    refute_includes out, "gem push (candidate)"
  end

  # ── the unshipped-final guard ──────────────────────────────────────────────

  # A consumer's tree locks 1.0.0; the gem's main (the last shipped) is 0.10.0.
  UNSHIPPED_WORLD = <<~'RUBY'
    def repo_path(_repo) = Dir.tmpdir
    def sh(*) = ["", true]
    def gem_version_from_ref(_repo, ref) = ref == "origin/main" ? "0.10.0" : "1.0.0"
    def git_capture(*a)
      return ["GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (1.0.0)\n", true] if a.join(" ").include?(":Gemfile.lock")
      return [%(gem "studio-engine", "~> 1.0"\n), true] if a.join(" ").include?(":Gemfile")
      ["", true]
    end
  RUBY

  def guarded(call)
    %{begin; #{call}; puts("PASSES"); rescue SystemExit => e; puts("REFUSED: " + e.message); end}
  end

  def test_prepare_refuses_a_consumer_locked_to_a_final_this_release_does_not_carry
    out = run_cli(["--yes"], setup: UNSHIPPED_WORLD,
                  call: guarded(%(refuse_stray_candidates!([{ "repo" => "turf-monster" }], {}))))

    assert_includes out, "REFUSED: ", out
    assert_includes out, "turf-monster locks studio-engine 1.0.0, a version past studio-engine's main (0.10.0)"
    assert_includes out, "Do not yank it"
  end

  def test_the_release_that_carries_that_final_passes
    out = run_cli(["--yes"], setup: UNSHIPPED_WORLD,
                  call: guarded(%(refuse_stray_candidates!([{ "repo" => "turf-monster" }], { "studio-engine" => "1.0.0" }))))

    assert_includes out, "PASSES", out
  end

  def test_the_ship_refuses_to_deploy_an_unshipped_final
    out = run_cli(["--yes"], setup: UNSHIPPED_WORLD,
                  call: guarded(%(refuse_unshipped_final_deploy!([{ "repo" => "turf-monster" }], { "turf-monster" => "c" * 40 }, {}))))

    assert_includes out, "REFUSED: ✗ REFUSING TO DEPLOY an unshipped gem version", out
    assert_includes out, "No app has been deployed"
  end

  # ── ship: nothing to re-lock, nothing to re-gate ───────────────────────────

  # The frozen tree QA ran already locks the live final: repin_consumers makes no
  # commit, the ship SHA does not move, and the re-lock gate reads no CI.
  def test_the_ship_makes_no_relock_commit_and_reads_no_relock_ci
    Dir.mktmpdir do |dir|
      clone = build_sibling_fixture(dir)
      File.write(File.join(clone, "Gemfile"), %(source "https://rubygems.org"\ngem "studio-engine", "~> 1.0"\n))
      File.write(File.join(clone, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (1.0.0)\n")
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "release: prepare locked the final")
      run_git(clone, "push", "-q", "origin", "main")
      frozen = git_out(clone, "rev-parse", "HEAD")

      setup = %(def repo_path(_repo) = #{clone.inspect}\n) +
              %(def test_gate(repo, **) = puts("RELOCK-CI-READ " + repo)\n) +
              %(def bundle_lock(*) = puts("BUNDLE-LOCK-RAN")\n)
      out = run_cli(["--yes"], setup: setup,
                    call: %{@ship_live = []; sha = { "sibling" => #{frozen.inspect} }; } +
                          %{repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "1.0.0" }, sha); } +
                          %{run_relock_gate([{ "repo" => "sibling" }], sha); puts("SHIPPING " + sha["sibling"])})

      assert_includes out, "already pinned for studio-engine — no re-pin", out
      assert_includes out, "SHIPPING #{frozen}", "the SHA that deploys is the SHA QA and CI gated"
      refute_includes out, "BUNDLE-LOCK-RAN"
      refute_includes out, "RELOCK-CI-READ", "no fresh consumer CI is waited on"
      assert_equal frozen, git_out(File.join(dir, "origin.git"), "rev-parse", "main")
    end
  end
end
