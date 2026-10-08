# frozen_string_literal: true

# `bin/release prepare` publishes a gem's RELEASE CANDIDATE (x.y.z.rcN) and never its
# final version; `bin/release ship` publishes the final after QA. This file holds the
# prepare half. Standalone:
#   ruby -Itest test/lib/release_gems_after_qa_test.rb
#
# Every case drives the real script with `sh`, git and RubyGems stubbed: nothing is
# built, pushed or tagged outside the test process.
require_relative "release_cli_harness"

class ReleaseGemsAfterQaTest < ReleaseCliHarness
  # Names what each `gem push` and tag push carried, and answers the two `rc-` tag
  # reads. Prepended, so the harness stub underneath still does the rest.
  def candidate_world(tip_tags: [], all_tags: [])
    %(TIP_TAGS = #{tip_tags.inspect}\nALL_TAGS = #{all_tags.inspect}\n) + <<~'RUBY'
      self.singleton_class.prepend(Module.new do
        def sh(*a, **k)
          puts("PUSHED " + File.basename(a[2].to_s)) if a[0] == "gem" && a[1] == "push"
          puts("TAG-PUSHED " + a.last.to_s) if a[0] == "git" && a.include?("push") && a.last.to_s.match?(/\A(rc-|v\d)/)
          super
        end

        def git_capture(*a)
          j = a.join(" ")
          return [TIP_TAGS.join("\n"), true] if j.include?("tag --points-at")
          return [ALL_TAGS.join("\n"), true] if j.include?("tag --list")
          super
        end
      end)
    RUBY
  end

  def test_prepare_never_pushes_a_final_version
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "1.0.0") + candidate_world)

    assert_equal ["PUSHED release-studio-engine-1.0.0.rc1.gem"], out.lines.grep(/^PUSHED /).map(&:strip),
                 "prepare pushes exactly one artifact, the candidate: #{out}"
    assert_equal ["TAG-PUSHED rc-1.0.0.rc1"], out.lines.grep(/^TAG-PUSHED /).map(&:strip),
                 "and tags it `rc-`, never the `v*` tag the allocation reads"
    assert_includes out, "the final 1.0.0 is pushed by `bin/release ship`"
    assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=1.0.0.rc1"
    assert_includes out, "QA-DEPLOY", "and QA still deploys, on the candidate"
  end

  # An in-range candidate: the commit is the lock alone. The exact requirement is on
  # the Gemfile only while bundle resolves.
  def test_an_in_range_candidate_commits_no_gemfile_change
    seen = <<~'RUBY'
      self.singleton_class.prepend(Module.new do
        def bundle_lock(path, gem, **kw)
          puts("GEMFILE-AT-RESOLVE " + File.read(File.join(path, "Gemfile")).strip)
          super
        end
      end)
    RUBY
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "0.11.0") + candidate_world + seen)

    assert_includes out, %(GEMFILE-AT-RESOLVE gem "studio-engine", "~> 0.10", "0.11.0.rc1"), out
    assert_includes out, "settle the lock on the committed Gemfile"
    assert_includes out, %(GEMFILE-AFTER gem "studio-engine", "~> 0.10"\n)
    assert_includes out, "committed studio-engine 0.11.0.rc1"
  end

  # The settle step is a read-back: a lock that left the candidate is never committed.
  def test_a_lock_that_drops_the_candidate_on_the_committed_gemfile_is_refused
    drift = <<~'RUBY'
      self.singleton_class.prepend(Module.new do
        def sh(*a, **k)
          if a[0, 2] == %w[bundle lock] && a.size == 2
            lock = File.join(k[:chdir], "Gemfile.lock")
            File.write(lock, File.read(lock).sub("(0.11.0.rc1)", "(0.10.0)"))
          end
          super
        end
      end)
    RUBY
    out = run_cli(["--yes"], setup: gem_publish_stub(version: "0.11.0") + candidate_world + drift,
                  call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})

    assert_match(/ABORTED: .*the lock did not hold studio-engine 0\.11\.0\.rc1 on the committed Gemfile \(it resolves studio-engine 0\.10\.0\)/, out)
    refute_includes out, "LOCK-PUSH"
    refute_includes out, "QA-DEPLOY"
  end

  # A QA bounce moves the gem's tip. The next sweep keeps the allocated 1.0.0 and
  # publishes a NEW candidate of it: the bounced one is never locked again.
  def test_red_qa_leaves_version_free
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: [{ "number" => "1.0.0.rc1" }]) +
                         candidate_world(all_tags: ["rc-1.0.0.rc1"]))

    assert_includes out, "gem studio-engine: 1.0.0 already advanced past 0.10.0 — allocated already",
                    "the version stays the one already allocated: #{out}"
    assert_equal ["PUSHED release-studio-engine-1.0.0.rc2.gem"], out.lines.grep(/^PUSHED /).map(&:strip)
    assert_includes out, "BUNDLE-LOCK studio-engine conservative=true expect=1.0.0.rc2"
    assert_includes out, %(GEMFILE-AFTER gem "studio-engine", ">= 1.0.0.rc2", "< 2"),
                    "1.0.0 escapes the fixture's `~> 0.10`, so the committed line admits the candidate"
    refute_match(/PUSHED release-studio-engine-1\.0\.0\.gem/, out, "no final is pushed on the way")
  end

  # The pure half of the same claim: a candidate on RubyGems is not a published
  # version, so it neither blocks nor advances the allocation.
  def test_a_live_candidate_does_not_consume_its_final_in_the_allocation
    out = eval_helper(<<~RUBY)
      Release::GemVersion.allocation(current: "0.10.0", tag_version: "0.10.0",
                                     live_versions: ["0.10.0", "0.11.0.rc1", "0.11.0.rc2"],
                                     ahead_commits: ["abc fix"], members: [{ "kind" => "feature" }])
                         .then { |d| [d.action, d.version].join(" ") }
    RUBY

    assert_equal "allocate 0.11.0", out, "the bounced candidates' final is allocated again"
  end

  def test_a_rerun_at_the_same_tip_reuses_the_candidate
    out = run_cli(["--yes"], call: "prepare",
                  setup: gem_publish_stub(version: "1.0.0", live: [{ "number" => "1.0.0.rc1" }], lock_dirty: false) +
                         candidate_world(tip_tags: ["rc-1.0.0.rc1"], all_tags: ["rc-1.0.0.rc1"]))

    assert_includes out, "candidate 1.0.0.rc1 is already live and tagged at", out
    assert_empty out.lines.grep(/^(PUSHED|TAG-PUSHED) /), "a re-run publishes nothing"
    refute_includes out, "GEM-BUILD"
    assert_includes out, "lock verified at studio-engine 1.0.0.rc1 — nothing to commit"
    assert_includes out, "QA-DEPLOY"
  end

  # A gem repo's own lock never takes a candidate; the ship bumps it to the final.
  def test_prepare_leaves_producer_locks_to_the_ship
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "1.0.0") + candidate_world)

    refute_includes out, "bump PRODUCER locks", out
    assert_includes out, "lock drift: none"
  end

  def test_the_dry_run_names_the_candidate_and_no_final_push
    out = run_cli(["--dry-run"], call: "prepare", setup: gem_publish_stub)

    assert_includes out, "gem push (candidate) <version>.rc<n>"
    assert_empty out.lines.grep(/gem push/).reject { |l| l.include?("(candidate)") },
                 "the only push a prepare previews is the candidate's"
  end

  # ── the candidate build ────────────────────────────────────────────────────

  # A real workspace on disk; `sh` records what the version file read at build time.
  def candidate_build(version_text, artifact_version: nil)
    <<~RUBY
      WS = Dir.mktmpdir("candidate-ws")
      FileUtils.mkdir_p(File.join(WS, "lib/studio"))
      VERSION_FILE = File.join(WS, "lib/studio/version.rb")
      File.write(VERSION_FILE, #{version_text.inspect})
      def repo_path(_repo) = WS
      def with_ship_workspace(_repo) = yield
      def ship_workspace!(_repo, _sha) = WS
      def checkout_detached(*) = nil
      def restore_gem_primary(*) = nil
      def gem_release_check!(*) = nil
      def gem_artifact_version(artifact) = #{artifact_version.inspect} || File.basename(artifact, ".gem").split("-").last
      def sh(*a, **k)
        puts("BUILT-WITH " + File.read(VERSION_FILE).strip) if a[0] == "gem" && a[1] == "build"
        puts("PUSHED " + File.basename(a[2])) if a[0] == "gem" && a[1] == "push"
        ["", true]
      end
    RUBY
  end

  DRIVE_CANDIDATE = %{begin; publish_gem_candidate("studio-engine", "abc1234", "0.96.0", "0.96.0.rc1"); } +
                    %{rescue SystemExit => e; puts("REFUSED: " + e.message); end; puts("AFTER " + File.read(VERSION_FILE).strip)}

  def test_the_candidate_is_built_at_its_own_version_and_the_tree_is_put_back
    out = run_cli(["--yes"], setup: candidate_build(%(VERSION = "0.96.0"\n)), call: DRIVE_CANDIDATE)

    assert_includes out, %(BUILT-WITH VERSION = "0.96.0.rc1"), out
    assert_includes out, "PUSHED release-studio-engine-0.96.0.rc1.gem"
    assert_includes out, %(AFTER VERSION = "0.96.0"), "the workspace declares the final again"
  end

  def test_a_tree_that_does_not_declare_the_final_builds_no_candidate
    out = run_cli(["--yes"], setup: candidate_build(%(VERSION = "0.95.0"\n)), call: DRIVE_CANDIDATE)

    assert_match(/REFUSED: .*does not declare exactly 0\.96\.0/, out)
    refute_includes out, "BUILT-WITH"
    refute_includes out, "PUSHED"
  end

  # The built artifact is read before the push: a build that came out as the final
  # is exactly the push this change exists to prevent.
  def test_an_artifact_that_is_not_the_candidate_is_never_pushed
    out = run_cli(["--yes"], setup: candidate_build(%(VERSION = "0.96.0"\n), artifact_version: "0.96.0"), call: DRIVE_CANDIDATE)

    assert_match(/REFUSED: .*carries version "0\.96\.0", not 0\.96\.0\.rc1/, out)
    refute_includes out, "PUSHED"
    assert_includes out, %(AFTER VERSION = "0.96.0")
  end

  # ── a candidate nobody is finalizing ───────────────────────────────────────

  STRAY = <<~'RUBY'
    def repo_path(_repo) = Dir.tmpdir
    def git_capture(*a)
      j = a.join(" ")
      return ["GEM\n  remote: https://rubygems.org/\n  specs:\n    studio-engine (0.96.0.rc1)\n", true] if j.end_with?(":Gemfile.lock")
      return [%(gem "studio-engine", "~> 0.95", "0.96.0.rc1"\n), true] if j.end_with?(":Gemfile")
      ["", true]
    end
  RUBY

  def stray(published)
    run_cli(["--yes"], setup: STRAY,
            call: %{begin; refuse_stray_candidates!([{ "repo" => "mcritchie-studio" }], #{published.inspect}); puts("PASSED"); } +
                  %{rescue SystemExit => e; puts("REFUSED: " + e.message); end})
  end

  def test_a_consumer_on_a_candidate_this_sweep_does_not_carry_is_refused
    out = stray({})

    assert_match(/REFUSED: .*mcritchie-studio locks studio-engine 0\.96\.0\.rc1 .*does not carry studio-engine/, out)
    assert_includes out, "A prerelease must never reach production"
    refute_includes out, "PASSED"
  end

  def test_a_consumer_on_another_candidate_than_this_sweeps_is_refused
    assert_match(/REFUSED: .*carries studio-engine 0\.96\.0\.rc2/, stray("studio-engine" => "0.96.0.rc2"))
  end

  # THE CONTROL: the candidate this sweep locked is the normal state.
  def test_the_candidate_this_sweep_locked_passes
    assert_includes stray("studio-engine" => "0.96.0.rc1"), "PASSED"
  end

  # ── a candidate needs a ship that finalizes it ─────────────────────────────

  # The machine's ship entry points, as the test names them. `:self` reads the script
  # under test, so it carries the flow by construction.
  def entry_points(points)
    rows = points.map do |label, text|
      body = text == :self ? "File.read(#{BIN.inspect})" : text.inspect
      %(#{label.inspect} => [-> { #{body} }, "bring #{label} up to date"])
    end
    "def release_entry_points = { #{rows.join(', ')} }\n"
  end

  OLD_SCRIPT = "#!/usr/bin/env ruby\n# a release.rb from before the candidate flow\ndef ship; end\n"

  def prepare_with(points, stub = {})
    run_cli(["--yes"], setup: gem_publish_stub(version: "1.0.0", **stub) + candidate_world + entry_points(points),
            call: %{begin; prepare; puts("NO-ABORT"); rescue SystemExit => e; puts("ABORTED: " + e.message); end})
  end

  # NEW prepare, OLDER ship present: refused before any candidate exists.
  def test_prepare_refuses_a_candidate_while_an_older_ship_can_follow_it
    out = prepare_with({ "the fixed-path install" => OLD_SCRIPT, "the hub primary" => :self })

    assert_match(/ABORTED: .*gem publish preflight FAILED — NOTHING was published/, out)
    assert_includes out, "the fixed-path install does not carry the candidate flow"
    assert_includes out, "would publish the final and deploy consumers still locked to the candidate"
    assert_includes out, "Fix: bring the fixed-path install up to date"
    refute_includes out, "the hub primary does not", "only the entry point that lacks it is named"
    assert_empty out.lines.grep(/^(PUSHED|TAG-PUSHED) /), "no candidate is published: #{out}"
    refute_includes out, "LOCK-PUSH"
    refute_includes out, "NO-ABORT"
  end

  def test_an_entry_point_nobody_can_read_refuses_too
    out = prepare_with({ "the fixed-path install" => nil, "the hub primary" => :self })

    assert_includes out, "the fixed-path install could not be read", out
    assert_empty out.lines.grep(/^PUSHED /)
  end

  def test_an_entry_point_on_another_flow_number_refuses
    out = prepare_with({ "the hub primary" => %(GEM_CANDIDATE_FLOW = "0"\n) })

    assert_includes out, "the hub primary carries candidate flow 0, not 1", out
    assert_empty out.lines.grep(/^PUSHED /)
  end

  # THE CONTROL: every entry point carries the flow, and the candidate publishes.
  def test_prepare_publishes_when_every_entry_point_carries_the_flow
    out = prepare_with({ "the fixed-path install" => :self, "the hub primary" => :self })

    assert_includes out, "NO-ABORT", out
    assert_equal ["PUSHED release-studio-engine-1.0.0.rc1.gem"], out.lines.grep(/^PUSHED /).map(&:strip)
  end

  # A sweep that publishes no candidate (the final is live) is the old flow's shape,
  # which an older ship handles: it is not held up.
  def test_a_sweep_with_no_candidate_does_not_ask
    out = prepare_with({ "the fixed-path install" => OLD_SCRIPT },
                       { live: [{ "number" => "1.0.0" }], lock_dirty: false, tag: "v1.0.0", ahead: "" })

    assert_includes out, "NO-ABORT", out
    assert_includes out, "consumers lock the final"
  end

  def test_the_real_entry_points_are_the_fixed_path_install_and_the_hub_primary
    out = eval_helper(%(release_entry_points.keys.join("\n")))

    assert_match(%r{the fixed-path install \(.*/\.agents/bin/release\.rb\)}, out)
    # The checkout directory is named by whoever cloned it (consumer CI uses mcritchie_studio).
    assert_match(%r{the hub primary's working tree \(/.+/bin/release\.rb\)}, out)
    assert_includes out, "the hub primary's origin/main"
  end

  # The marker other checkouts read as text: one line, in the form the reader matches.
  def test_the_script_carries_the_flow_line_exactly_once
    assert_equal 1, File.read(BIN).scan(/^GEM_CANDIDATE_FLOW = "\d+"$/).size
  end

  # The stamp lands before any consumer is locked to the candidate.
  def test_the_release_is_stamped_with_its_candidates_before_the_bump
    stamped = <<~'RUBY'
      self.singleton_class.prepend(Module.new do
        def conductor(ruby, **kw)
          puts("STAMP " + ruby[/'gem_candidates' => (\{.*?\}\})/, 1].to_s) if ruby.include?("'gem_candidates' =>")
          super
        end
      end)
    RUBY
    out = run_cli(["--yes"], call: "prepare", setup: gem_publish_stub(version: "1.0.0") + candidate_world + stamped)

    assert_match(/^STAMP \{"flow" ?=> ?"1", "gems" ?=> ?\{"studio-engine" ?=> ?"1\.0\.0\.rc1"\}\}/, out)
    assert_operator out.index("STAMP"), :<, out.index("LOCK-PUSH"), "stamped before a lock names the candidate"
    assert_operator out.index("PUSHED"), :<, out.index("STAMP"), "and after the candidate exists"
  end
end
