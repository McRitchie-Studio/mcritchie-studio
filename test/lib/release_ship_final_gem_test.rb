# frozen_string_literal: true

# `bin/release ship` publishes a gem's FINAL version, and only for the tree QA ran as
# a candidate. This file holds the ship half of publish-gems-after-qa. Standalone:
#   ruby -Itest test/lib/release_ship_final_gem_test.rb
#
# The gems compared here are real .gem files built in the test; `gem push`, the
# RubyGems listing, the CDN download and every git push to a real remote are stubbed
# or pointed at a fixture on disk. Nothing is published.
require_relative "release_cli_harness"
require "rubygems/package"

class ReleaseShipFinalGemTest < ReleaseCliHarness
  GEM = "studio-engine"
  VERSION_FILE = "lib/studio/version.rb"

  # Build studio-engine at `version` into `dir`, as `name` (default: the CDN's name).
  def build_gem(dir, version, body: "module Studio; end\n", name: nil)
    src = Dir.mktmpdir("final-gem-src")
    FileUtils.mkdir_p(File.join(src, "lib/studio"))
    File.write(File.join(src, "lib/studio.rb"), body)
    File.write(File.join(src, VERSION_FILE), %(module Studio\n  VERSION = "#{version}"\nend\n))
    spec = Gem::Specification.new do |s|
      s.name = GEM
      s.version = version
      s.summary = "fixture"
      s.authors = ["test"]
      s.files = ["lib/studio.rb", VERSION_FILE]
    end
    out = File.join(dir, name || "#{GEM}-#{version}.gem")
    Gem::DefaultUserInteraction.use_ui(Gem::SilentUI.new) { Dir.chdir(src) { Gem::Package.build(spec, true, false, out) } }
    out
  ensure
    FileUtils.remove_entry(src) if src
  end

  # The ship's world around ship_gem: `cdn` is what RubyGems serves, `built` is what
  # `gem build` produces at the frozen SHA, and a push "publishes" `served` (default:
  # the pushed artifact itself) into the CDN.
  def ship_world(cdn:, built:, live: [], served: nil)
    <<~RUBY
      ENV["RELEASE_GEM_FETCH"] = #{cdn.inspect}
      @ship_live = []
      def rubygems_versions(_gem) = #{live.inspect}
      def repo_path(_repo) = Dir.tmpdir
      def checkout_detached(*) = puts("CHECKOUT")
      def gem_release_check!(*) = nil
      def push_frozen_main(repo, sha) = puts("MAIN-PUSHED " + repo)
      def restore_gem_primary(*) = nil
      def record_merged_main(*) = nil
      def sh(*a, **k)
        if a[0] == "gem" && a[1] == "build"
          FileUtils.cp(#{built.inspect}, a[a.index("--output") + 1])
        elsif a[0] == "gem" && a[1] == "push"
          puts("PUSHED " + Gem::Package.new(a[2]).spec.version.to_s)
          FileUtils.cp(#{(served || "").inspect}.empty? ? a[2] : #{(served || "").inspect}, File.join(#{cdn.inspect}, "#{GEM}-0.96.0.gem"))
        elsif a[0] == "git" && a.include?("push")
          puts("TAG-PUSHED " + a.last.to_s)
        end
        ["", true]
      end
    RUBY
  end

  def ship_gem_call(candidate)
    %{begin; ship_gem("#{GEM}", "0.96.0", "f" * 40, ["t-gem"], candidate: #{candidate.inspect}); puts("SHIPPED"); } +
      %{rescue SystemExit => e; puts("REFUSED: " + e.message); end}
  end

  def with_gems
    Dir.mktmpdir("final-gem-cdn") do |cdn|
      Dir.mktmpdir("final-gem-built") do |built|
        yield cdn, built
      end
    end
  end

  # ── before the push: the final must carry the candidate's contents ─────────

  def test_ship_aborts_on_checksum_mismatch
    with_gems do |cdn, built|
      build_gem(cdn, "0.96.0.rc1")
      final = build_gem(built, "0.96.0", body: "module Studio; LATE_EDIT = 1; end\n")

      out = run_cli(["--yes"], setup: ship_world(cdn: cdn, built: final), call: ship_gem_call("0.96.0.rc1"))

      assert_match(/REFUSED: ✗ studio-engine 0\.96\.0 built from fffffff does NOT match 0\.96\.0\.rc1, the candidate QA ran: lib\/studio\.rb differs/, out)
      assert_includes out, "NOTHING was published or deployed"
      refute_includes out, "PUSHED", "a final that is not the candidate's tree is never pushed: #{out}"
      refute_includes out, "MAIN-PUSHED"
      refute_includes out, "SHIPPED"
    end
  end

  # THE CONTROL: the same world with the same tree publishes, tags, confirms what
  # RubyGems serves, and only then advances the gem's main.
  def test_a_final_that_matches_its_candidate_is_published_and_confirmed
    with_gems do |cdn, built|
      build_gem(cdn, "0.96.0.rc1")
      final = build_gem(built, "0.96.0")

      out = run_cli(["--yes"], setup: ship_world(cdn: cdn, built: final), call: ship_gem_call("0.96.0.rc1"))

      assert_includes out, "SHIPPED", out
      assert_includes out, "checksum: studio-engine 0.96.0 carries the same 2 file(s) and dependencies as 0.96.0.rc1"
      assert_match(/checksum: RubyGems serves studio-engine 0\.96\.0 with SHA-256 \h{12}…, the artifact this ship built/, out)
      order = %w[CHECKOUT PUSHED\ 0.96.0 TAG-PUSHED\ v0.96.0 MAIN-PUSHED].map { |marker| out.index(marker) }
      assert_equal order.compact.sort, order, "build, push, tag, then main: #{out}"
    end
  end

  # ── after the push: what RubyGems serves must be what was pushed ───────────

  def test_a_served_gem_that_is_not_the_pushed_artifact_stops_before_any_ref_moves
    with_gems do |cdn, built|
      build_gem(cdn, "0.96.0.rc1")
      final = build_gem(built, "0.96.0")
      other = build_gem(built, "0.96.0", body: "module Studio; SOMEONE_ELSE = 1; end\n", name: "other.gem")

      out = run_cli(["--yes"], setup: ship_world(cdn: cdn, built: final, served: other), call: ship_gem_call("0.96.0.rc1"))

      assert_includes out, "PUSHED 0.96.0", "the push happened; this is the read after it"
      assert_match(/REFUSED: ✗ studio-engine 0\.96\.0 was PUBLISHED, but RubyGems serves SHA-256/, out)
      assert_includes out, "Nothing is deployed"
      refute_includes out, "MAIN-PUSHED"
    end
  end

  # ── no candidate, no final ─────────────────────────────────────────────────

  def test_a_gem_with_no_candidate_is_never_published
    with_gems do |cdn, built|
      final = build_gem(built, "0.96.0")

      out = run_cli(["--yes"], setup: ship_world(cdn: cdn, built: final), call: ship_gem_call(nil))

      assert_match(/REFUSED: ✗ gem studio-engine 0\.96\.0 is not on RubyGems and NO candidate of it was found/, out)
      assert_includes out, "NOTHING was published or deployed"
      refute_includes out, "CHECKOUT", "nothing is even built"
      refute_includes out, "PUSHED"
    end
  end

  def test_a_candidate_the_cdn_does_not_serve_stops_the_publish
    with_gems do |cdn, built|
      final = build_gem(built, "0.96.0")

      out = run_cli(["--yes"], setup: ship_world(cdn: cdn, built: final), call: ship_gem_call("0.96.0.rc1"))

      assert_match(/REFUSED: ✗ could not download studio-engine 0\.96\.0\.rc1 from RubyGems/, out)
      refute_includes out, "PUSHED"
    end
  end

  # ── the re-run after "final published, lock not bumped" ────────────────────

  # The final is live. The re-run does not push again and does not skip in silence:
  # it compares the live gem with the candidate and carries on to the gem's main.
  def test_a_rerun_with_the_final_live_resumes_without_a_second_push
    with_gems do |cdn, built|
      build_gem(cdn, "0.96.0.rc1")
      build_gem(cdn, "0.96.0")

      out = run_cli(["--yes"], setup: ship_world(cdn: cdn, built: File.join(built, "unused.gem"), live: [{ "number" => "0.96.0" }]),
                    call: ship_gem_call("0.96.0.rc1"))

      assert_includes out, "already live on RubyGems — skip publish (idempotent)", out
      assert_includes out, "checksum: the live studio-engine 0.96.0 carries the same contents as 0.96.0.rc1"
      assert_includes out, "MAIN-PUSHED studio-engine"
      assert_includes out, "SHIPPED"
      refute_includes out, "PUSHED 0.96.0"
      refute_includes out, "CHECKOUT"
    end
  end

  def test_a_live_final_that_is_not_the_candidate_is_not_shipped
    with_gems do |cdn, built|
      build_gem(cdn, "0.96.0.rc1")
      build_gem(cdn, "0.96.0", body: "module Studio; HAND_PUBLISHED = 1; end\n")

      out = run_cli(["--yes"], setup: ship_world(cdn: cdn, built: File.join(built, "unused.gem"), live: [{ "number" => "0.96.0" }]),
                    call: ship_gem_call("0.96.0.rc1"))

      assert_match(/REFUSED: ✗ studio-engine 0\.96\.0 is LIVE on RubyGems and does NOT match 0\.96\.0\.rc1/, out)
      refute_includes out, "MAIN-PUSHED"
    end
  end

  def test_the_dry_run_names_both_checksum_reads
    out = run_cli(["--dry-run"], call: %{ship_gem("#{GEM}", "0.96.0", "f" * 40, [])})

    assert_includes out, "verify its contents equal the candidate QA ran"
    assert_includes out, "verify the served .gem checksum"
  end

  # ── which candidate did QA run ─────────────────────────────────────────────

  # The locks at the frozen SHAs, by repo. A nil lock is a repo with no Gemfile.lock.
  def candidates_world(locks, tags: "")
    %(LOCKS = #{locks.inspect}\nTAGS = #{tags.inspect}\n) + <<~'RUBY'
      ROOT = Dir.mktmpdir("candidates-world")
      at_exit { FileUtils.remove_entry(ROOT) }
      def repo_path(repo) = File.join(ROOT, repo).tap { |path| FileUtils.mkdir_p(path) }
      def gem_version_for(_repo, _group, _ref = nil) = "0.96.0"
      def git_capture(*a)
        j = a.join(" ")
        repo = File.basename(a[1])
        return [TAGS, true] if j.include?("tag --points-at")
        if j.end_with?(":Gemfile.lock")
          version = LOCKS[repo]
          return version ? ["GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (#{version})\n", true] : ["", false]
        end
        ["", true]
      end
    RUBY
  end

  CANDIDATES_CALL = %{c, problems = ship_gem_candidates([{ "repo" => "studio-engine" }], } +
                    %{[{ "repo" => "mcritchie-studio" }, { "repo" => "turf-monster" }], } +
                    %{{ "studio-engine" => "a" * 40, "mcritchie-studio" => "b" * 40, "turf-monster" => "c" * 40 }); } +
                    %{puts("CANDIDATE=" + c["studio-engine"].inspect); puts("PROBLEMS=" + problems.join(" | "))}

  def test_the_candidate_is_read_from_the_locks_qa_ran
    out = run_cli(["--yes"], setup: candidates_world({ "mcritchie-studio" => "0.96.0.rc2", "turf-monster" => "0.96.0.rc2" }),
                  call: CANDIDATES_CALL)

    assert_includes out, %(CANDIDATE="0.96.0.rc2"), out
    assert_match(/^PROBLEMS=$/, out)
  end

  def test_consumers_on_different_candidates_refuse_the_ship
    out = run_cli(["--yes"], setup: candidates_world({ "mcritchie-studio" => "0.96.0.rc1", "turf-monster" => "0.96.0.rc2" }),
                  call: CANDIDATES_CALL)

    assert_includes out, "CANDIDATE=nil", out
    assert_includes out, "consumers lock different candidates"
  end

  def test_a_consumer_still_on_the_old_version_refuses_the_ship
    out = run_cli(["--yes"], setup: candidates_world({ "mcritchie-studio" => "0.96.0.rc1", "turf-monster" => "0.95.0" }),
                  call: CANDIDATES_CALL)

    assert_includes out, "turf-monster locks 0.95.0, not 0.96.0 or a candidate of it", out
  end

  # A gem-only release has no consumer lock: the candidate is the tag at the frozen SHA.
  def test_a_gem_only_release_reads_its_candidate_from_the_tag
    out = run_cli(["--yes"], setup: candidates_world({}, tags: "rc-0.96.0.rc1\nrc-0.96.0.rc3\nrc-0.95.0.rc9\n"),
                  call: CANDIDATES_CALL)

    assert_includes out, %(CANDIDATE="0.96.0.rc3"), out
  end

  # A candidate of a gem this release does not carry: the app would deploy a prerelease.
  def test_an_app_on_a_candidate_of_a_gem_the_release_does_not_carry_refuses_the_ship
    out = run_cli(["--yes"], setup: candidates_world({ "mcritchie-studio" => "0.96.0.rc1" }),
                  call: %{_, problems = ship_gem_candidates([], [{ "repo" => "mcritchie-studio" }], { "mcritchie-studio" => "b" * 40 }); } +
                        %{puts("PROBLEMS=" + problems.join(" | "))})

    assert_match(/PROBLEMS=mcritchie-studio locks studio-engine 0\.96\.0\.rc1 at bbbbbbb, and this release does not carry studio-engine/, out)
  end

  # ── the re-lock commit ─────────────────────────────────────────────────────

  PINNED   = %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.9", "0.10.0.rc1"\n)
  UNPINNED = %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.9"\n)
  def lock_at(version) = "GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (#{version})\n"

  # A consumer whose `release` is frozen on the candidate, as prepare leaves it.
  def build_candidate_fixture(dir)
    clone = build_sibling_fixture(dir)
    run_git(clone, "checkout", "-q", "release")
    File.write(File.join(clone, "Gemfile"), PINNED)
    File.write(File.join(clone, "Gemfile.lock"), lock_at("0.10.0.rc1"))
    run_git(clone, "add", "-A")
    run_git(clone, "commit", "-q", "-m", "bump studio-engine 0.10.0.rc1 for QA")
    run_git(clone, "push", "-q", "origin", "release")
    frozen = git_out(clone, "rev-parse", "HEAD")
    run_git(clone, "checkout", "-q", "main")
    [clone, frozen]
  end

  # `bundle lock` as Bundler does it once the final is served: the lock takes it.
  LOCKS_FINAL = <<~'RUBY'
    def bundle_lock(path, gem, attempts: 3, conservative: false, expect: nil)
      puts("BUNDLE-LOCK #{gem} conservative=#{conservative} expect=#{expect}")
      File.write(File.join(path, "Gemfile.lock"), "GEM\n  remote: https://rubygems.org/\n  specs:\n    #{gem} (#{expect})\n")
    end
  RUBY

  RELOCK_CALL = %{@ship_live = []; sha = { "sibling" => FROZEN }; } +
                %{begin; repin_consumers([{ "repo" => "sibling" }], { "studio-engine" => "0.10.0" }, sha); } +
                %{puts("SHIPPING " + sha["sibling"]); puts("RELOCKED " + relocked.inspect); } +
                %{rescue SystemExit => e; puts("REFUSED: " + e.message); end}

  def relock(clone, frozen, extra)
    run_cli(["--yes"], setup: %(def repo_path(_repo) = #{clone.inspect}\nFROZEN = #{frozen.inspect}\n) + extra, call: RELOCK_CALL)
  end

  def test_the_relock_commit_changes_only_the_gemfile_and_its_lock
    Dir.mktmpdir do |dir|
      clone, frozen = build_candidate_fixture(dir)
      origin = File.join(dir, "origin.git")

      out = relock(clone, frozen, LOCKS_FINAL)

      head = git_out(origin, "rev-parse", "release")
      refute_equal frozen, head, out
      assert_includes out, "SHIPPING #{head}", "the ship SHA moves to the re-lock commit"
      assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=0.10.0"
      assert_equal frozen, git_out(origin, "rev-parse", "release^"), "one commit, on top of the SHA QA froze"
      assert_equal "Gemfile\nGemfile.lock", git_out(origin, "diff", "--name-only", frozen, head)
      assert_equal UNPINNED.strip, git_out(origin, "show", "#{head}:Gemfile")
      assert_includes git_out(origin, "show", "#{head}:Gemfile.lock"), "studio-engine (0.10.0)"
      assert_equal "relock studio-engine 0.10.0 (QA ran 0.10.0.rc1)", git_out(origin, "log", "-1", "--format=%s", head)
      assert_match(/RELOCKED .*#{frozen}.*#{head}/, out, "and the gate is told which commit to read")
    end
  end

  # A re-run after the re-lock was pushed reuses it, and still hands it to the gate.
  def test_a_rerun_reuses_the_relock_and_still_names_it_for_the_gate
    Dir.mktmpdir do |dir|
      clone, frozen = build_candidate_fixture(dir)
      origin = File.join(dir, "origin.git")
      relock(clone, frozen, LOCKS_FINAL)
      first = git_out(origin, "rev-parse", "release")

      out = relock(clone, frozen, LOCKS_FINAL)

      assert_includes out, "ALREADY on origin/release", out
      assert_includes out, "SHIPPING #{first}"
      assert_equal first, git_out(origin, "rev-parse", "release"), "no second commit"
      assert_match(/RELOCKED .*#{first}/, out, "the reused commit is still gated on its CI")
    end
  end

  # The right Gemfile over a lock still on the candidate is not this run's re-lock.
  def test_a_pushed_commit_whose_lock_kept_the_candidate_is_not_reused
    Dir.mktmpdir do |dir|
      clone, frozen = build_candidate_fixture(dir)
      origin = File.join(dir, "origin.git")
      run_git(clone, "checkout", "-q", "--detach", frozen)
      File.write(File.join(clone, "Gemfile"), UNPINNED)
      File.write(File.join(clone, "Gemfile.lock"), lock_at("0.10.0.rc1") + "\n")
      run_git(clone, "add", "-A")
      run_git(clone, "commit", "-q", "-m", "relock by hand, lock not updated")
      run_git(clone, "push", "-q", "origin", "HEAD:refs/heads/release")
      wrong = git_out(clone, "rev-parse", "HEAD")
      run_git(clone, "checkout", "-q", "main")

      out = relock(clone, frozen, LOCKS_FINAL)

      assert_match(/REFUSED: ✗ sibling origin\/release .* drifted past the QA-frozen SHA/, out)
      assert_equal wrong, git_out(origin, "rev-parse", "release")
      refute_includes out, "SHIPPING"
    end
  end

  # The real bundle_lock, with a `bundle` that leaves the candidate in the lock (the
  # final not yet resolvable): the ladder runs out and nothing is pushed.
  def test_a_lock_that_stays_on_the_candidate_is_never_committed
    Dir.mktmpdir do |dir|
      clone, frozen = build_candidate_fixture(dir)
      origin = File.join(dir, "origin.git")
      inert_bundle = <<~'RUBY'
        ENV["RELEASE_BUNDLE_LOCK_BACKOFF"] = "0"
        self.singleton_class.prepend(Module.new do
          def sh(*a, **k) = a[0] == "bundle" ? ["", true] : super
        end)
      RUBY

      out = relock(clone, frozen, inert_bundle)

      assert_match(/REFUSED: ✗ bundle lock --update studio-engine --conservative did not land .*resolves 0\.10\.0\.rc1, wanted 0\.10\.0/m, out)
      assert_equal frozen, git_out(origin, "rev-parse", "release"), "release still carries the tree QA ran"
    end
  end

  # ── the gate on the re-lock commit ─────────────────────────────────────────

  RELOCK_GATE = <<~'RUBY'
    relocked["mcritchie-studio"] = { "from" => "f" * 40, "to" => "e" * 40, "pins" => ["studio-engine 0.10.0 (QA ran 0.10.0.rc1)"] }
    def repo_path(_repo) = Dir.tmpdir
    def gate_sop(sop, cmd, ok, *) = puts("SOP #{sop} #{ok}")
    def resolve_release_ci_verdict(repo, _path, sha, **)
      puts("CI-READ #{repo} #{sha[0, 7]}")
      { ci: CiStatus.for_sha("", sha, ENV["RELEASE_CI_STATUS"]), credited: false, diagnostic: nil, diverged: true }
    end
  RUBY

  def relock_gate(status)
    run_cli(["--yes"], setup: %(ENV["RELEASE_CI_STATUS"] = #{status.inspect}\n) + RELOCK_GATE,
            call: %{begin; run_relock_gate([{ "repo" => "mcritchie-studio" }, { "repo" => "turf-monster" }], } +
                  %{{ "mcritchie-studio" => "e" * 40, "turf-monster" => "c" * 40 }); puts("GATE-PASSED"); } +
                  %{rescue SystemExit => e; puts("REFUSED: " + e.message); end})
  end

  def test_a_red_relock_commit_refuses_the_ship_and_names_the_recovery
    out = relock_gate("red")

    assert_includes out, "CI-READ mcritchie-studio eeeeeee", "the gate reads the RE-LOCK commit, not the frozen SHA: #{out}"
    assert_includes out, "SOP ship_test_gate false"
    assert_match(/REFUSED: ✗ test gate FAILED for mcritchie-studio: GitHub CI called frozen eeeeeee RED/, out)
    assert_includes out, "THIS IS THE RE-LOCK COMMIT eeeeeee (QA-frozen fffffff + studio-engine 0.10.0 (QA ran 0.10.0.rc1))"
    assert_includes out, "the final gem version is published and tagged"
    assert_includes out, "NOTHING is deployed"
    assert_includes out, "gh run rerun"
    assert_includes out, "the gem skips as live, the re-lock is reused, and this gate reads again"
    refute_includes out, "GATE-PASSED"
  end

  def test_a_pending_relock_commit_does_not_pass_either
    out = relock_gate("pending")

    assert_match(/REFUSED: ✗ test gate HELD for mcritchie-studio/, out)
    assert_includes out, "THIS IS THE RE-LOCK COMMIT"
  end

  # THE CONTROL: green passes, and only the re-locked repo is read.
  def test_a_green_relock_commit_passes_and_an_untouched_consumer_is_not_read
    out = relock_gate("green")

    assert_includes out, "GATE-PASSED", out
    assert_includes out, "SOP ship_test_gate true"
    assert_equal 1, out.scan("CI-READ").size, "turf-monster was not re-locked, so the pre-authority read stands"
  end

  # ── the order of the ship ──────────────────────────────────────────────────

  # ship() itself, with each act named as it runs: publish, re-lock, the re-lock
  # gate, then deploy. A red gate must leave the deploy unreached.
  ORDER = <<~'RUBY'
    def ship_preflight(*) = nil
    def whats_live(*) = nil
    Release::ShipSequence.define_singleton_method(:missing_deploy_commands) { |*| [] } # the SHAs here are not commits
    def run_ship_gate(*) = puts("ACT frozen-gate")
    def ship_gem_candidates(*) = [{ "studio-engine" => "0.9.0.rc1" }, []]
    def ship_gem(repo, version, *_rest, candidate: nil) = puts("ACT publish-final #{repo} #{version} after #{candidate}")
    def repin_consumers(app_groups, published, ship_sha)
      puts("ACT relock")
      relocked["mcritchie-studio"] = { "from" => ship_sha["mcritchie-studio"], "to" => "e" * 40, "pins" => ["studio-engine 0.9.0"] }
      ship_sha["mcritchie-studio"] = "e" * 40
    end
    def test_gate(repo, frozen_sha:, relock: nil)
      puts("ACT relock-gate #{repo} #{frozen_sha[0, 7]}")
      abort("✗ red") if ENV["GATE"] == "red"
    end
    def deploy_app(group, sha) = puts("ACT deploy #{group['repo']} #{sha[0, 7]}")
    def run_post_deploy(*) = nil
    def production_smoke_seal(*) = nil
    def settle_producer_locks(*) = puts("ACT producer-locks")
    def restore_primaries(*) = nil
    def sync_agent_docs = nil
    def git_capture(*) = ["", true]
    def sh(*) = ["", true]
  RUBY

  def ship_order(gate)
    run_cli(["--yes"], setup: SHIP_STUB + ORDER + %(ENV["GATE"] = #{gate.inspect}\n),
            call: %{begin; ship; rescue SystemExit; puts("ABORTED"); end}).lines.grep(/^(ACT|ABORTED)/).map(&:strip)
  end

  def test_the_ship_publishes_relocks_and_gates_before_any_deploy
    acts = ship_order("green")

    assert_equal ["ACT frozen-gate", "ACT publish-final studio-engine 0.9.0 after 0.9.0.rc1", "ACT relock",
                  "ACT relock-gate mcritchie-studio eeeeeee", "ACT deploy mcritchie-studio eeeeeee",
                  "ACT deploy turf-monster ccccccc", "ACT producer-locks"], acts
  end

  def test_a_red_relock_gate_reaches_no_deploy
    acts = ship_order("red")

    assert_equal ["ACT frozen-gate", "ACT publish-final studio-engine 0.9.0 after 0.9.0.rc1", "ACT relock",
                  "ACT relock-gate mcritchie-studio eeeeeee", "ABORTED"], acts
  end
end
