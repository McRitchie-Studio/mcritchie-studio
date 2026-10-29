# frozen_string_literal: true

# THE FINAL FLOW (the default): `bin/release prepare` publishes a gem's final x.y.z,
# consumers lock it before the pre-QA gate, and `bin/release ship` deploys those
# gated SHAs with no re-lock and no fresh consumer CI.
# docs/agents/system/gem-release-flow.md. Standalone:
#   ruby -Itest test/lib/release_gem_final_at_prepare_test.rb
#
# `gem push`, RubyGems, the CDN and every remote are stubbed. Nothing is published.
require_relative "release_cli_harness"
require "rubygems/package"

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
  # The reuse path still checks what RubyGems serves against this tree, and puts
  # back the tag a stopped run never pushed.
  def test_a_rerun_at_the_same_tip_reuses_the_live_final
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: [{ "number" => "1.0.0" }], lock_dirty: false,
                                          tag: "v1.0.0", ahead: "") + PUSH_LEDGER + ReleaseCliStubs::REUSED_FINAL)

    assert_includes out, "1.0.0 is already live on RubyGems — consumers lock the final", out
    assert_empty out.lines.grep(/^(PUSHED|TAG-PUSHED) /), "a re-run publishes nothing"
    assert_includes out, "REUSE-VERIFIED studio-engine 1.0.0", "the served gem is compared with this tree"
    assert_includes out, "TAG-ENSURED studio-engine v1.0.0", "a tag a stopped run never pushed is put back"
    assert_operator out.index("REUSE-VERIFIED"), :<, out.index("TAG-ENSURED"), "verified before it is tagged"
    assert_includes out, "QA-DEPLOY"
  end

  # The listing cannot be read: prepare stops with the named error, and publishes
  # nothing, rather than reading it as empty and pushing a version RubyGems holds.
  def test_an_unreadable_listing_stops_prepare_before_any_publish
    unreadable = <<~'RUBY'
      def rubygems_versions(gem_name) = abort!("#{Release::GemFlow::LISTING_UNREADABLE} for #{gem_name} (HTTP 503)")
    RUBY
    out = run_cli(["--yes"], call: guarded("prepare"), setup: gem_publish_stub(version: "1.0.0") + PUSH_LEDGER + unreadable)

    assert_includes out, "RubyGems listing unreadable for studio-engine", out
    assert_empty out.lines.grep(/^(PUSHED|TAG-PUSHED) /), "nothing is published"
    refute_includes out, "GEM-PUSH"
    refute_includes out, "yanked"
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

  # ── the RubyGems listing read ──────────────────────────────────────────────

  # curl answers with the body and then the HTTP code on its own line.
  def listing_world(body:, code:, exit_ok: true)
    <<~RUBY
      def Open3.capture2e(*a) = [#{body.inspect} + "\n" + #{code.inspect}, Struct.new(:ok) { def success? = ok }.new(#{exit_ok})]
    RUBY
  end

  def test_the_listing_reads_live_versions_and_a_404_as_never_published
    out = run_cli(["--yes"], setup: listing_world(body: %([{"number":"1.0.0"}]), code: "200"),
                  call: %(puts rubygems_versions("studio-engine").to_json))
    assert_includes out, %([{"number":"1.0.0"}]), out

    out = run_cli(["--yes"], setup: listing_world(body: "not found", code: "404"),
                  call: %(puts rubygems_versions("studio-engine").to_json))
    assert_includes out, "[]", out
  end

  def test_an_unreadable_listing_is_a_named_abort_never_empty
    [listing_world(body: "", code: "000", exit_ok: false), listing_world(body: "<html>", code: "503"),
     listing_world(body: "<html>", code: "200")].each do |world|
      out = run_cli(["--yes"], setup: world, call: guarded(%(p rubygems_versions("studio-engine"))))

      assert_includes out, "REFUSED: ✗ RubyGems listing unreadable for studio-engine", out
      assert_includes out, "NOTHING was published"
      refute_includes out, "PASSES"
    end
  end

  # ── burned versions ────────────────────────────────────────────────────────

  # 1.0.0 was published at a prepare and burned; 1.0.1 shipped, so main is past it.
  BURNED_WORLD = <<~'RUBY'
    def repo_path(_repo) = Dir.tmpdir
    def sh(*) = ["", true]
    def gem_version_from_ref(_repo, ref) = ref == "origin/main" ? "1.0.1" : "1.0.0"
    def git_capture(*a)
      j = a.join(" ")
      return ["GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (1.0.0)\n", true] if j.include?(":Gemfile.lock")
      return [%(gem "studio-engine", "~> 1.0"\n), true] if j.include?(":Gemfile")
      return ["burned-v1.0.0\n", true] if j.include?("tag --list burned-v*")
      ["", true]
    end
  RUBY

  def test_prepare_refuses_a_lock_on_a_burned_version_below_main
    out = run_cli(["--yes"], setup: BURNED_WORLD,
                  call: guarded(%(refuse_stray_candidates!([{ "repo" => "turf-monster" }], {}))))

    assert_includes out, "REFUSED: ", out
    assert_includes out, "turf-monster locks studio-engine 1.0.0, a BURNED version"
  end

  def test_the_ship_refuses_to_deploy_a_burned_version_below_main
    out = run_cli(["--yes"], setup: BURNED_WORLD,
                  call: guarded(%(refuse_unshipped_final_deploy!([{ "repo" => "turf-monster" }], { "turf-monster" => "c" * 40 }, {}))))

    assert_includes out, "REFUSED: ✗ REFUSING TO DEPLOY an unshipped gem version", out
    assert_includes out, "a BURNED version"
  end

  def test_the_same_lock_without_a_burn_record_passes
    out = run_cli(["--yes"], setup: BURNED_WORLD + %(def burned_gem_versions(_gem) = []\n),
                  call: guarded(%(refuse_stray_candidates!([{ "repo" => "turf-monster" }], {}))))

    assert_includes out, "PASSES", "the record is what refuses it: below main, nothing else would"
  end

  # The prepare that carries 1.0.2 while 1.0.0 and 1.0.1 are tagged above main (0.10.0)
  # records both as burned, on the commits their v tags name.
  RECORD_WORLD = <<~'RUBY'
    def repo_path(_repo) = Dir.tmpdir
    def gem_version_from_ref(_repo, ref) = "0.10.0"
    def git_capture(*a)
      j = a.join(" ")
      return ["v0.9.0\nv0.10.0\nv1.0.0\nv1.0.1\n", true] if j.include?("tag --list v*")
      return ["burned-v1.0.0\n", true] if j.include?("tag --list burned-v*")
      ["", true]
    end
    PUSH_OK = !ENV["RECORD_PUSH_FAILS"]
    def sh(*a, **k)
      if a[0] == "git" && a.include?("tag") && a.include?("-a")
        puts("BURN-TAG #{a[a.index('-a') + 1]} at #{a.last}")
        return ["", true]
      end
      if a[0] == "git" && a.include?("push")
        puts("BURN-PUSH #{a.last}")
        return ["", PUSH_OK]
      end
      ["", true]
    end
  RUBY

  def test_prepare_records_each_final_this_release_supersedes
    out = run_cli(["--yes"], setup: RECORD_WORLD,
                  call: guarded(%(record_burned_finals!([{ "repo" => "studio-engine", "version" => "1.0.2" }]))))

    assert_includes out, "PASSES", out
    assert_includes out, "BURN-TAG burned-v1.0.1 at v1.0.1^{}"
    assert_includes out, "BURN-PUSH refs/tags/burned-v1.0.1"
    refute_includes out, "BURN-TAG burned-v1.0.0", "an existing record is not written twice"
    refute_match(/BURN-TAG burned-v(0\.9\.0|0\.10\.0|1\.0\.2)/, out, "shipped and carried versions are not burned")
  end

  def test_a_burn_that_cannot_be_recorded_stops_prepare
    ENV["RECORD_PUSH_FAILS"] = "1"
    out = run_cli(["--yes"], setup: RECORD_WORLD,
                  call: guarded(%(record_burned_finals!([{ "repo" => "studio-engine", "version" => "1.0.2" }]))))

    assert_includes out, "REFUSED: ✗ could not push burned-v1.0.1", out
    assert_includes out, "NOTHING was published"
  ensure
    ENV.delete("RECORD_PUSH_FAILS")
  end

  # ── the stray-lock refusal runs before any publish ─────────────────────────

  # The swept consumer's origin/release locks solana-studio 2.0.0, a registered gem
  # this release does not carry, above its main (1.0.0 in this world).
  STRAY_LOCK = <<~'RUBY'
    self.singleton_class.prepend(Module.new do
      def git_capture(*a)
        if a.join(" ").include?("origin/release:Gemfile.lock")
          return ["GEM\n  remote: https://rubygems.org/\n  specs:\n    solana-studio (2.0.0)\n    studio-engine (0.10.0)\n", true]
        end
        super
      end
    end)
  RUBY

  def test_a_stray_lock_refuses_before_any_gem_is_published
    out = run_cli(["--yes"], call: guarded("prepare"), setup: gem_publish_stub(version: "1.0.0") + PUSH_LEDGER + STRAY_LOCK)

    assert_includes out, "REFUSED: ✗ a consumer is locked to a published gem version no release has shipped", out
    assert_includes out, "locks solana-studio 2.0.0, a version past solana-studio's main"
    assert_includes out, "NOTHING was published"
    assert_empty out.lines.grep(/^PUSHED /), "zero gem pushes: the refusal comes first"
    refute_includes out, "GEM-PUSH"
    refute_includes out, "QA-DEPLOY"
  end

  # A lock on the gem this release carries is the consumer bump's to rewrite, so
  # it does not refuse before the publish.
  def test_a_lock_the_consumer_bump_rewrites_does_not_refuse_before_the_publish
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "1.0.0") + PUSH_LEDGER)

    assert_includes out, "PUSHED release-studio-engine-1.0.0.gem", out
    refute_includes out, "NOTHING was published"
  end

  # ── the reuse path's served check, on real .gem files ──────────────────────

  def build_fixture_gem(dir, body)
    src = File.join(dir, "src-#{body.hash.abs}")
    FileUtils.mkdir_p(File.join(src, "lib"))
    File.write(File.join(src, "lib/fixture_gem.rb"), body)
    spec = Gem::Specification.new do |s|
      s.name = "fixture_gem"
      s.version = "1.0.0"
      s.summary = "fixture"
      s.authors = ["test"]
      s.files = ["lib/fixture_gem.rb"]
      s.license = "MIT"
      s.homepage = "https://example.invalid"
      s.required_ruby_version = ">= 3.0"
    end
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) do
      Dir.chdir(src) { File.join(src, Gem::Package.build(spec)) }
    end
  end

  def reuse_world(built, served_dir)
    %(ENV["RELEASE_GEM_FETCH"] = #{served_dir.inspect}\n) +
      %(def build_gem_artifact(_repo, _tip, _version) = #{built.inspect}\n) +
      %(def gem_meta_for(_repo) = { "version_file" => "lib/fixture_gem/version.rb" }\n)
  end

  def test_the_reuse_path_passes_when_the_served_gem_is_this_tree
    Dir.mktmpdir do |dir|
      served = File.join(dir, "served")
      FileUtils.mkdir_p(served)
      FileUtils.cp(build_fixture_gem(dir, "module FixtureGem; end\n"), File.join(served, "fixture_gem-1.0.0.gem"))
      built = build_fixture_gem(dir, "module FixtureGem; end\n")

      out = run_cli(["--yes"], setup: reuse_world(built, served),
                    call: guarded(%(verify_reused_final!("fixture_gem", "a" * 40, "1.0.0"))))
      assert_includes out, "PASSES", out
      assert_includes out, "carries the same contents as"
    end
  end

  def test_the_reuse_path_refuses_a_served_gem_from_another_tree
    Dir.mktmpdir do |dir|
      served = File.join(dir, "served")
      FileUtils.mkdir_p(served)
      FileUtils.cp(build_fixture_gem(dir, "module FixtureGem; HAND = 1; end\n"), File.join(served, "fixture_gem-1.0.0.gem"))
      built = build_fixture_gem(dir, "module FixtureGem; end\n")

      out = run_cli(["--yes"], setup: reuse_world(built, served),
                    call: guarded(%(verify_reused_final!("fixture_gem", "a" * 40, "1.0.0"))))
      assert_includes out, "REFUSED: ✗ fixture_gem 1.0.0 is LIVE on RubyGems and does NOT match", out
      assert_includes out, "lib/fixture_gem.rb differs"
    end
  end

  def test_the_reuse_path_refuses_when_the_served_gem_cannot_be_read
    Dir.mktmpdir do |dir|
      out = run_cli(["--yes"], setup: reuse_world(File.join(dir, "never.gem"), dir),
                    call: guarded(%(verify_reused_final!("fixture_gem", "a" * 40, "1.0.0"))))
      assert_includes out, "REFUSED: ✗ could not download fixture_gem 1.0.0", out
    end
  end
end
