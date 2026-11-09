require "minitest/autorun"
require "open3"
require "tmpdir"

# The prepare's LOCK-ONLY read, driven for real: an engine app no card names, whose
# `accepted` carries only the release tooling's lock bumps, rides the sweep (task
# release-ships-lock-only-consumers). On 2026-11-09 commercial-welding (0.135.2) and
# alex-build (0.137.0) sat behind in production with only bumps on `accepted`. The
# REAL bin/release functions, the real registry and catalog; git, the fetch and the
# CI read stubbed. Pattern from test/lib/release_cardless_consumer_relock_test.rb.
class ReleaseLockOnlyConsumersTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  BUMP = "\x1e%<sha>s\x1fparent\x1fbump studio-engine 0.141.1\n\nGemfile.lock\ndb/schema.rb\n".freeze
  HUMAN = "\x1ehuman1\x1fparent\x1fFix the quote form\n\napp/views/quotes/new.html.erb\n".freeze

  # LOGS: { repo => git log text for origin/release..<accepted> }. A repo absent
  # from LOGS has an empty range (nothing ahead). RED: repos whose CI is red.
  STUB = <<~'RUBY'
    LOGS = {} unless defined?(LOGS)
    RED = [] unless defined?(RED)
    require "fileutils"
    $ROOT = Dir.mktmpdir
    def repo_path(repo) = File.join($ROOT, repo.to_s).tap { |p| FileUtils.mkdir_p(p) }
    def sh(*a, **k)
      $stdout.puts("RAN: #{a.reject { |x| x.is_a?(Hash) }.join(' ')}")
      ["", true]
    end
    def git_capture(*a)
      repo = File.basename(a[1].to_s)
      j = a.join(" ")
      return ["sha-#{repo}\n", true] if j.include?("rev-parse")
      return [LOGS.fetch(repo, ""), true] if j.include?(" log ")
      ["", true]
    end
    def ci_verdict(repo, _sha) = RED.include?(repo) ? { state: :red } : { state: :green }
  RUBY

  def run_release(setup, call, argv: %w[--yes])
    script = %(ARGV.replace(#{argv.inspect}); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             setup +
             %(begin; #{call}; rescue SystemExit => e; puts("ABORTED: " + e.message.to_s); end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  def logs(map) = "LOGS = #{map.inspect}\n"

  CALL = %(r = lock_only_consumer_repos(["mcritchie-studio"]); puts("RIDES=" + r.join(",")); ) +
         %(puts("PINS=" + swept_shas.sort.map { |k, v| k + "@" + v }.join(",")))

  def test_an_app_whose_accepted_carries_only_lock_bumps_rides_and_is_pinned
    out = run_release(logs("commercial-welding" => format(BUMP, sha: "b1") + format(BUMP, sha: "b2"),
                           "alex-build" => format(BUMP, sha: "b3")) + STUB, CALL)

    rides = out[/RIDES=(.*)/, 1].to_s.split(",")
    assert_equal %w[commercial-welding alex-build].sort, rides.sort, out
    assert_includes out, "PINS=alex-build@sha-alex-build,commercial-welding@sha-commercial-welding", out
    assert_includes out, "commercial-welding: `accepted` carries only lock bumps", out
    assert_match %r{RAN: git -C \S+/commercial-welding fetch origin release accepted --quiet}, out
  end

  def test_an_app_with_a_human_commit_does_not_ride
    out = run_release(logs("commercial-welding" => format(BUMP, sha: "b1") + HUMAN) + STUB, CALL)

    assert_equal "", out[/RIDES=(.*)/, 1].to_s, "a commit with no card needs a task, not a lock-only ride: #{out}"
  end

  def test_an_app_with_nothing_ahead_does_not_ride
    out = run_release(STUB, CALL)

    assert_equal "", out[/RIDES=(.*)/, 1].to_s, out
  end

  def test_a_member_repo_is_never_judged
    out = run_release(logs("mcritchie-studio" => format(BUMP, sha: "b1")) + STUB, CALL)

    refute_includes out[/RIDES=(.*)/, 1].to_s, "mcritchie-studio", "a member repo is promoted by its card: #{out}"
  end

  # The control on the registry: an app with `engine: false` (dads-app) never rides.
  def test_an_engine_false_app_never_rides
    out = run_release(logs("dads-app" => format(BUMP, sha: "b1")) + STUB, CALL)

    refute_includes out[/RIDES=(.*)/, 1].to_s, "dads-app", out
  end

  def test_a_red_lock_bump_stays_behind_with_a_warning_and_does_not_abort
    out = run_release(%(RED = ["alex-build"]\n) + logs("alex-build" => format(BUMP, sha: "b3"),
                                                       "commercial-welding" => format(BUMP, sha: "b1")) + STUB, CALL)

    assert_equal %w[commercial-welding], out[/RIDES=(.*)/, 1].to_s.split(","), out
    assert_includes out, "alex-build: `accepted` carries only lock bumps, but its CI is RED", out
    refute_includes out, "ABORTED", out
  end

  def test_a_dry_run_judges_without_fetching
    out = run_release(logs("commercial-welding" => format(BUMP, sha: "b1")) + STUB, CALL, argv: %w[--yes --dry-run])

    assert_equal %w[commercial-welding], out[/RIDES=(.*)/, 1].to_s.split(","), out
    refute_match(/RAN: git .* fetch/, out, "a dry run takes no fetch: #{out}")
    assert_equal "", out[/PINS=(.*)/, 1].to_s, "a dry run pins nothing: #{out}"
  end

  # The record: the lock-only repos ride the sweep's own transaction, before repo_plan.
  def test_the_sweep_record_writes_the_lock_only_repos_before_the_repo_plan
    out = run_release("", %(puts batch_sweep_with_plan_ruby(["t1"], "rel-x", lock_only: ["commercial-welding"])))

    record = out.index('Release::LockOnlyConsumers.record(r.metadata || {}, ["commercial-welding"])')
    plan = out.index("Release::Conductor.repo_plan(r)")
    refute_nil record, out
    assert_operator record, :<, plan, out
  end

  def test_a_sweep_with_no_lock_only_repo_writes_no_record
    out = run_release("", %(puts batch_sweep_with_plan_ruby(["t1"], "rel-x")))

    refute_includes out, "LockOnlyConsumers", out
  end

  # bin/release status: the lag lines.
  def test_status_lists_each_app_a_minor_or_more_behind
    reads = { reference: "0.141.1",
              live: { "commercial-welding" => "0.135.2", "alex-build" => "0.137.0", "moms-app" => "0.141.0" },
              accepted: { "commercial-welding" => "0.141.1", "alex-build" => "0.141.1" } }
    out = run_release("", %(engine_lag_report(reads: #{reads.inspect})))

    assert_includes out, "LAGS commercial-welding: production locks studio-engine 0.135.2, the last shipped is 0.141.1"
    assert_includes out, "LAGS alex-build: production locks studio-engine 0.137.0"
    refute_includes out, "LAGS moms-app", "a patch behind is not a lag: #{out}"
  end
end
