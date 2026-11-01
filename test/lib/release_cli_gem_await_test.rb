# frozen_string_literal: true

# bin/release.rb's PUBLISH → INSTALL window. `gem push` returns before RubyGems can SERVE the
# version, so a lock bump committed at once triggers CI whose `bundle install` exits 7. WHY THE
# COMPACT INDEX AND NOT THE VERSIONS API: they disagree during exactly this window, and the
# compact index is the surface BUNDLER resolves from, so waiting on the other is a gate that
# cannot observe what it gates. A FILE OF ITS OWN: the release CLI files are frozen at their
# size by `config/test_health.yml`.
# History: task await-gem-before-lock-bump.
require "minitest/autorun"
require "open3"
require "tmpdir"

class ReleaseCliGemAwaitTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # Drive the REAL script with the injection seams set, then evaluate `call`.
  def run_release(call, env = {}, argv: ["--help"])
    script = %(ARGV.replace(#{argv.inspect}); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             %(begin; #{call}; rescue SystemExit; puts "REFUSED"; end)
    out, = Open3.capture2e({ "RELEASE_GEM_POLL_INTERVAL" => "0", "RELEASE_GEM_INSTALLED" => "yes", "RELEASE_GEM_SETTLE_S" => "0" }.merge(env), RbConfig.ruby, "-e", script)
    out
  end

  # ── A DRY RUN MUST NOT REACH THE NETWORK ──────────────────────────────────
  #
  # The dry run previews the plan with no git/gh call so it stays hermetic, and this
  # wait reaches the RubyGems index. Without the `unless DRY` guard a --dry-run polls
  # the live index for up to RELEASE_GEM_POLL_TIMEOUT seconds PER GEM — the meta-tests
  # that drive --dry-run hung for an hour on exactly that. This is the test that keeps
  # it from coming back, and it is deliberately driven with the seam saying NOT
  # indexed: under DRY that must still not refuse and must not wait.
  def test_a_dry_run_neither_waits_nor_refuses
    call = <<~RUBY
      bump_consumer_locks_for_qa([], { "studio-engine" => "0.49.0" })
      puts "DRY_PROCEEDED"
    RUBY
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "no", "RELEASE_GEM_POLL_TIMEOUT" => "0" },
                      argv: ["--dry-run"])

    assert_includes out, "DRY_PROCEEDED", "a dry run must not refuse on an unindexed gem"
    refute_includes out, "REFUSED"
    refute_match(/await:/, out, "a dry run must not even ANNOUNCE the wait — it makes no network call")
  end

  # ── [unit] the index parser, against the REAL payload shape ────────────────

  # Verified live against https://index.rubygems.org/info/studio-engine, whose lines
  # read "0.49.0 aws-sdk-s3:~> 1.218,faker:< 4.0&>= 2.0,...|checksum:...".
  def test_the_parser_matches_a_whole_version_never_a_prefix
    out = run_release(<<~RUBY)
      sample = "0.47.2 aws-sdk-s3:~> 1.218|checksum:abc\\n0.48.0 aws-sdk-s3:~> 1.218|checksum:def\\n"
      hit = ->(v) { sample.lines.any? { |l| l.split(" ", 2).first.to_s.strip == v } }
      puts "present=" + hit.call("0.48.0").to_s
      puts "absent=" + hit.call("0.49.0").to_s
      puts "prefix=" + hit.call("0.4").to_s
    RUBY

    assert_includes out, "present=true"
    assert_includes out, "absent=false"
    assert_includes out, "prefix=false", "0.4 must NOT satisfy a wait for 0.47.2 — that would bump too early"
  end

  # ── [unit] the wait returns as soon as the version is fetchable ────────────

  def test_it_returns_immediately_once_the_version_is_indexed
    out = run_release(%(await_published_gems!({ "studio-engine" => "0.49.0" }); puts "PROCEEDED"),
                      { "RELEASE_GEM_INDEXED" => "yes" })

    assert_includes out, "PROCEEDED", "an indexed gem must not delay the bump at all"
    assert_match(/is on the index/, out, "and it must SAY what it waited for")
    refute_includes out, "REFUSED"
  end

  # ── [unit] a bounded timeout REFUSES rather than bumping the lock ──────────

  def test_it_refuses_before_bumping_when_the_gem_never_appears
    out = run_release(%(await_published_gems!({ "studio-engine" => "0.49.0" }); puts "PROCEEDED"),
                      { "RELEASE_GEM_INDEXED" => "no", "RELEASE_GEM_POLL_TIMEOUT" => "0" })

    assert_includes out, "REFUSED", "an unavailable gem must stop the release BEFORE the lock bump"
    refute_includes out, "PROCEEDED"
    assert_match(/NOTHING was bumped/, out,
                 "the refusal must say the locks are untouched, or the operator cannot tell it is safe to re-run")
    assert_match(/bundler exits 7/, out, "and it must name the failure it is preventing")
  end

  # THE CONTROL. A release with no gem must not wait, or every app-only release pays
  # for a window it does not have.
  def test_a_release_with_no_published_gem_does_not_wait
    out = run_release(%(await_published_gems!({}); puts "PROCEEDED"), { "RELEASE_GEM_INDEXED" => "no" })

    assert_includes out, "PROCEEDED"
    refute_match(/await:/, out, "no gem, no wait, no noise")
  end

  # ── [integration] the guard is on the function that COMMITS ───────────────

  # The placement is the point. bump_consumer_locks_for_qa is what makes the commit
  # that triggers CI, so the wait lives inside IT rather than at a call site — the
  # same lesson this file's sibling learned when a guard wired in front of one of two
  # callers never ran. Driven here through the real function.
  def test_the_bump_itself_refuses_an_unavailable_gem
    # A heredoc, not %(...): that literal BALANCES parentheses, so a call split across
    # two fragments silently swallows the closing paren and ships a malformed script.
    call = <<~RUBY
      bump_consumer_locks_for_qa([{ "repo" => "mcritchie-studio" }], { "studio-engine" => "0.49.0" })
      puts "COMMITTED"
    RUBY
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "no", "RELEASE_GEM_POLL_TIMEOUT" => "0" })

    assert_includes out, "REFUSED", "the bump must not proceed when the gem is not installable"
    refute_includes out, "COMMITTED"
    assert_match(/GEM_NOT_SERVED: published studio-engine 0\.49\.0/, out, "the refusal must carry its name")
    assert_match(/re-run `bin\/release prepare`/, out, "and tell the operator the re-run resumes")
    refute_match(/bundle lock|git push/, out, "nothing reaches a lock or a push before the refusal")
  end

  # ── [integration] an already-live version from before the monthly rebuild ──
  #
  # Carl's bounce: the ship awaits every final, pushed this run or not, and a
  # version older than the /versions tail sits in the rebuilt BASE line. Through the
  # real probe: the Range read misses, ONE full read finds it, and a second probe
  # reuses that hit instead of downloading 25 MB again.
  def test_an_already_live_version_outside_the_tail_is_served
    fixture = File.expand_path("../fixtures/files/rubygems_versions_rebuilt.txt", __dir__)
    call = <<~RUBY
      $full = 0
      rebuilt = File.read(#{fixture.inspect})
      status = Struct.new(:ok) { def success? = ok }
      Open3.define_singleton_method(:capture2e) do |*cmd|
        url = cmd.last
        if url.include?("/info/") then ["0.82.0 a:~> 1|checksum:x\n", status.new(true)]
        elsif url.end_with?("/versions") && cmd.include?("-r") then [rebuilt[-2000..], status.new(true)]
        elsif url.end_with?("/versions") then ($full += 1; [rebuilt, status.new(true)])
        else ["", status.new(true)]
        end
      end
      first = gem_version_indexed?("studio-engine", "0.82.0")
      second = gem_version_indexed?("studio-engine", "0.82.0")
      puts "SERVED=" + first.to_s + "," + second.to_s + " FULL=" + $full.to_s
    RUBY
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "" })

    assert_includes out, "SERVED=true,true FULL=1", out
  end

  # ── [integration] the settle window, through the real wait ─────────────────
  #
  # rel-20261029-00560a: one served read from this edge let the bump go, and a
  # runner's edge 62s later still lacked the version. The real await must HOLD a
  # served answer for RELEASE_GEM_SETTLE_S before the bump runs. Fake clock: each
  # sleep advances it, so a 10s hold at a 5s interval takes exactly three reads.
  def test_a_served_gem_is_held_for_the_settle_window_before_the_bump
    call = <<~RUBY
      $clock = 0.0
      $reads = 0
      def monotonic_s = $clock
      def sleep(seconds) = $clock += seconds
      def gem_version_miss(_gem, _version) = ($reads += 1; nil) # the probe await reads (nil = served)
      await_published_gems!({ "studio-engine" => "0.49.0" })
      puts "READS=" + $reads.to_s + " AT=" + $clock.to_i.to_s
      puts "PROCEEDED"
    RUBY
    out = run_release(call, { "RELEASE_GEM_SETTLE_S" => "10", "RELEASE_GEM_POLL_INTERVAL" => "5" })

    assert_includes out, "PROCEEDED", out
    assert_includes out, "READS=3 AT=10", "served at t=0, 5, 10: the hold must span the window: #{out}"
    assert_match(/served it for 10s/, out)
  end

  def test_the_bump_proceeds_past_the_wait_when_the_gem_is_indexed
    call = <<~RUBY
      bump_consumer_locks_for_qa([], { "studio-engine" => "0.49.0" })
      puts "PASSED_WAIT"
    RUBY
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "yes" })

    assert_includes out, "PASSED_WAIT", "an indexed gem must let the bump run: #{out}"
    assert_match(/is on the index/, out)
  end

  # ── the deadline is WALL time ─────────────────────────────────────────────

  # Every index read costs 40 fake seconds and the sleeps cost nothing, so only a
  # deadline that counts the curl time can expire: 100s is passed on the third read.
  CLOCKED_CURL = <<~RUBY
    $clock = 0.0
    $curls = []
    def monotonic_s = $clock
    def sleep(_seconds) = nil
    status = Struct.new(:ok) { def success? = ok }
    Open3.define_singleton_method(:capture2e) do |*cmd|
      $curls << cmd
      $clock += 40
      ["", status.new(false)]
    end
  RUBY

  def test_elapsed_counts_curl_time
    call = CLOCKED_CURL + %(at_exit { puts "READS=" + $curls.size.to_s }\n) +
           %(await_published_gems!({ "studio-engine" => "0.49.0" }); puts "PROCEEDED")
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "", "RELEASE_GEM_POLL_TIMEOUT" => "100" })

    assert_includes out, "REFUSED", out
    assert_includes out, "READS=3", "the wait must end on the read that crosses 100s of wall time: #{out}"
    refute_includes out, "PROCEEDED"
  end

  def test_index_probe_passes_max_time
    call = CLOCKED_CURL + %(gem_version_indexed?("studio-engine", "0.49.0"); puts $curls.first.inspect)
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "" })

    assert_match(/"--max-time", "\d+"/, out, "a stalled read must be bounded, or the deadline never fires: #{out}")
  end

  # The .gem read is the second curl; it needs the same bound.
  def test_the_artifact_probe_passes_max_time_too
    call = <<~RUBY
      $curls = []
      status = Struct.new(:ok) { def success? = ok }
      Open3.define_singleton_method(:capture2e) do |*cmd|
        $curls << cmd
        body = cmd.last.end_with?("/versions") ? "ine 0.1.0 cut\nstudio-engine 0.48.0,0.49.0 md5\n" : "0.49.0 a:~> 1|checksum:x\n"
        [body, status.new(true)]
      end
      puts "SERVED=" + gem_version_indexed?("studio-engine", "0.49.0").to_s
      puts "BOUNDED=" + $curls.all? { |c| c.include?("--max-time") }.to_s + " " + $curls.size.to_s
    RUBY
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "" })

    assert_includes out, "SERVED=true", out
    assert_includes out, "BOUNDED=true 3", out
  end

  # ── [integration] GEM_NOT_SERVED names the surface, and its remedy follows it ──
  #
  # task release-gem-doc-followups: the refusal used to send the operator to /info
  # whatever was stale. Through the seam: a .gem miss names ".gem" and the .gem check.
  def test_the_refusal_names_the_surface_that_missed
    out = run_release(%(await_published_gems!({ "studio-engine" => "0.49.0" }); puts "PROCEEDED"),
                      { "RELEASE_GEM_INDEXED" => "no:.gem", "RELEASE_GEM_POLL_TIMEOUT" => "0" })

    assert_includes out, "REFUSED", out
    assert_match(/GEM_NOT_SERVED: published studio-engine 0\.49\.0 .*the last poll missed on \.gem/, out)
    assert_includes out, "curl -sfIL -o /dev/null https://rubygems.org/gems/studio-engine-0.49.0.gem"
  end

  # Through the REAL probe: /info lists it, the tail misses, the whole-file read
  # fails (its cap), and the refusal says so and names the override, which the
  # full read's curl carries as its --max-time.
  def test_a_failed_full_read_is_named_and_its_cap_takes_the_env_override
    call = <<~RUBY
      $full_argv = nil
      status = Struct.new(:ok) { def success? = ok }
      Open3.define_singleton_method(:capture2e) do |*cmd|
        url = cmd.last
        if url.include?("/info/") then ["0.49.0 a:~> 1|checksum:x\n", status.new(true)]
        elsif url.end_with?("/versions") && cmd.include?("-r") then ["cut\nrantly 1.0 x\n", status.new(true)]
        elsif url.end_with?("/versions") then ($full_argv = cmd; ["", status.new(false)])
        else ["", status.new(true)]
        end
      end
      at_exit { puts "FULL_MAX_TIME=" + $full_argv[$full_argv.index("--max-time") + 1].to_s }
      await_published_gems!({ "studio-engine" => "0.49.0" })
      puts "PROCEEDED"
    RUBY
    out = run_release(call, { "RELEASE_GEM_INDEXED" => "", "RELEASE_GEM_POLL_TIMEOUT" => "0",
                              "RELEASE_GEM_VERSIONS_FULL_MAX_TIME" => "600" })

    assert_includes out, "REFUSED", out
    assert_includes out, "the last poll missed on /versions full read (failed)", out
    assert_includes out, "raise RELEASE_GEM_VERSIONS_FULL_MAX_TIME", out
    assert_includes out, "FULL_MAX_TIME=600", "the 120s full-read cap must take RELEASE_GEM_VERSIONS_FULL_MAX_TIME"
  end
end
