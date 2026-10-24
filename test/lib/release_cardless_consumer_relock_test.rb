require "minitest/autorun"
require "open3"
require "tmpdir"

# The ship's CARDLESS re-lock, driven for real: the step that moves every live
# engine app the release did NOT carry to the published final, on its `accepted`.
#
# THE DEFECT THIS FILE EXISTS FOR. bump_consumer_locks_for_qa and repin_consumers
# walk app_groups, the apps with a member card in the release. An engine app with
# no card was in neither loop, so each engine publish left it one release further
# behind: on 2026-10-24 moms-app locked studio-engine 0.101.0 and rantly 0.87.0
# while the hub locked 0.112.0.
#
# A file of its own, as config/test_health.yml asks of new release-CLI work. Same
# pattern as test/lib/release_producer_lock_bump_test.rb: the REAL function runs
# against the real registries (config/release_repos.yml, config/apps.yml), with
# `sh`/`git_capture` and the workspace stubbed.
class ReleaseCardlessConsumerRelockTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  STUB = <<~'RUBY'
    PUSH_FAILS_FOR = [] unless defined?(PUSH_FAILS_FOR)

    require "fileutils"
    $ROOT = Dir.mktmpdir
    $INFLIGHT = 0
    $MAX_INFLIGHT = 0
    $GUARD = Mutex.new

    # Each repo gets its own checkout and workspace directory, so the repo's name
    # rides every recorded command's path.
    def repo_path(repo) = File.join($ROOT, repo.to_s).tap { |p| FileUtils.mkdir_p(p) }
    def with_ship_workspace(_repo, &block) = block.call
    def ship_workspace!(repo, _sha)
      ws = File.join($ROOT, "#{repo}-ship")
      FileUtils.mkdir_p(ws)
      File.write(File.join(ws, "Gemfile"), %(gem "studio-engine", "~> 0.86"\n))
      ws
    end
    # Holds each lock open briefly and records how many ran at once: a serial loop
    # never exceeds one.
    def bundle_lock(path, gem, **k)
      $GUARD.synchronize { $INFLIGHT += 1; $MAX_INFLIGHT = [$MAX_INFLIGHT, $INFLIGHT].max }
      sleep 0.2
      $GUARD.synchronize { $INFLIGHT -= 1 }
      $stdout.puts("LOCKED: #{File.basename(path)} #{gem} expect=#{k[:expect]}")
    end
    def install_engine_migrations!(workspace, *) = $stdout.puts("MIGRATIONS: #{File.basename(workspace)}")

    def sh(*a, **k)
      cmd = a.reject { |x| x.is_a?(Hash) }.join(" ")
      $stdout.puts("RAN: #{cmd}")
      return ["", PUSH_FAILS_FOR.none? { |r| cmd.include?("/#{r}-ship ") }] if cmd.include?(" push ")
      ["", true]
    end

    def git_capture(*a)
      j = a.join(" ")
      return ["deadbeef", true] if j.include?("rev-parse")
      return [" M Gemfile.lock", true] if j.include?("status --porcelain")
      ["", true]
    end
  RUBY

  def run_release(setup, call)
    script = %(ARGV.replace(["--yes"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             setup +
             %(begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message.to_s); end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  # The hub rides the release (it has a card); moms-app and rantly do not.
  CALL = %(relock_cardless_consumers([{ "repo" => "mcritchie-studio" }], { "studio-engine" => "0.113.0" }); ) +
         %(puts("MAX_INFLIGHT=" + $MAX_INFLIGHT.to_s); puts("CONTINUED"))

  def test_a_cardless_engine_consumer_gets_the_final_lock_commit_on_accepted
    out = run_release(STUB, CALL)

    %w[moms-app rantly].each do |repo|
      assert_includes out, "LOCKED: #{repo}-ship studio-engine expect=0.113.0",
                      "#{repo} has no card and must still be locked to the final: #{out}"
      assert_match %r{RAN: git -C \S+/#{repo}-ship push origin HEAD:refs/heads/accepted}, out,
                   "#{repo}'s lock commit lands on accepted, where its CI runs: #{out}"
      assert_includes out, "MIGRATIONS: #{repo}-ship", "#{repo}'s engine migrations ride the lock commit: #{out}"
    end
    refute_match %r{-ship push origin HEAD:refs/heads/release}, out,
                 "a cardless app is not in this release; its re-lock never touches release: #{out}"
  end

  def test_the_carried_app_is_left_to_the_swept_loop
    out = run_release(STUB, CALL)

    refute_includes out, "mcritchie-studio-ship", "the carried hub is re-locked by repin_consumers, not here: #{out}"
  end

  # THE CONTROL: dads-app is a release-managed app with `engine: false`.
  def test_an_engine_false_app_is_left_alone
    out = run_release(STUB, CALL)

    refute_includes out, "dads-app", "an app that does not run on the engine is never re-locked: #{out}"
    refute_includes out, "weekly-lock", "nor is any other engine-free showcase app: #{out}"
  end

  def test_the_cardless_relocks_run_in_parallel
    out = run_release(STUB, CALL)

    max = out[/MAX_INFLIGHT=(\d+)/, 1].to_i
    assert_operator max, :>, 1, "the cardless re-locks must overlap, not run one after another: #{out}"
  end

  # A failure in one app never stops the others, nor the ship that has deployed.
  def test_one_failed_push_warns_and_the_others_still_land
    out = run_release(%(PUSH_FAILS_FOR = ["moms-app"]\n) + STUB, CALL)

    assert_includes out, "CONTINUED", "a cardless failure must not abort a deployed ship: #{out}"
    assert_includes out, "cardless re-lock not settled — moms-app", "and it must be loud: #{out}"
    assert_includes out, "rantly: committed studio-engine 0.113.0 onto origin/accepted",
                    "while rantly still lands: #{out}"
  end

  def test_nothing_published_means_nothing_relocked
    out = run_release(STUB, %(relock_cardless_consumers([], {}); puts("CONTINUED")))

    assert_includes out, "CONTINUED"
    refute_includes out, "LOCKED:", "no publish, no re-lock: #{out}"
  end
end
