# frozen_string_literal: true

# bin/release.rb's PUBLISH → INSTALL window. Standalone:
#   ruby -Itest test/lib/release_cli_gem_await_test.rb
#
# THE INCIDENT, 2026-08-15. `gem push` returns before RubyGems can SERVE the version.
# prepare published studio-engine, immediately committed the consumer lock bump, and
# that commit triggered CI — whose Ruby setup ran `bundle install` against a lock
# pinning a version the index did not carry yet. Bundler exited 7, a lane went red,
# and the pre-QA gate aborted the release. It happened twice in a row, reddening
# scan_ruby on one attempt and lint on the next: the same bundler exit 7 both times,
# never a code regression. Because the publish is irreversible by then, the abort
# stranded a permanently published version (0.48.0).
#
# WHY THE COMPACT INDEX AND NOT THE VERSIONS API — the subtle half. They disagree
# during exactly the window that matters: in the same minute, the JSON API still
# listed 0.48.0 as newest while the .gem file for 0.49.0 already answered 200. The
# compact index is the surface BUNDLER resolves from, so it is the only one whose
# answer predicts whether CI can install. Waiting on the other would be a wait that
# proves nothing — a gate that cannot observe the thing it gates on.
#
# A NEW FILE ON PURPOSE: test/lib/release_cli_test.rb is 7356 lines and frozen at that
# size by config/test_health.yml, precisely so new work lands somewhere else.
require "minitest/autorun"
require "open3"
require "tmpdir"

class ReleaseCliGemAwaitTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # Drive the REAL script with the injection seams set, then evaluate `call`.
  def run_release(call, env = {}, argv: ["--help"])
    script = %(ARGV.replace(#{argv.inspect}); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             %(begin; #{call}; rescue SystemExit; puts "REFUSED"; end)
    out, = Open3.capture2e({ "RELEASE_GEM_POLL_INTERVAL" => "0" }.merge(env), RbConfig.ruby, "-e", script)
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
end
