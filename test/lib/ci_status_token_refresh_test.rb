# frozen_string_literal: true

# CiStatus re-mints its GitHub App read token when the token ages or a read is refused
# (task ci-poll-refreshes-its-token).
#
# THE DEFECT. gh_read_status minted ONE token per process. An installation token lives
# 3600 s, and the release gates now hold a pending verdict for up to ~105 minutes
# (bin/lib/ci_poll_budget.rb). So a wait past the hour read :unreadable and aborted with
# a message blaming credentials that one re-mint would have fixed.
#
# Both seams are stubs: CI_STATUS_GH_BIN for gh and GH_AUTH_TOKEN_BIN for the broker.
# The clock is CiStatus.clock, so an hour passes in no time. The stub gh accepts a
# token only while it is in its `valid` file, the way GitHub accepts one only until
# it expires.
#
#   ruby -Itest test/lib/ci_status_token_refresh_test.rb

require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/ci_status"

class CiStatusTokenRefreshTest < Minitest::Test
  PATH = "repos/McRitchie-Studio/studio-engine/commits/abc/check-runs?per_page=100"

  def setup
    @now = 0.0
    CiStatus.reset_gh_auth!
    CiStatus.clock = -> { @now }
  end

  def teardown
    CiStatus.reset_gh_auth!
    CiStatus.clock = nil
  end

  # [unit] THE ACCEPTANCE: a held token that reaches its re-mint age is replaced
  # BEFORE the next read, so a pending wait past one hour keeps reading CI.
  def test_a_token_past_its_refresh_age_is_reminted_before_the_next_read
    with_stubs do |s|
      _, ok = CiStatus.gh_read_status("api", PATH)
      assert ok
      assert_equal ["minted-1"], s.tokens_seen.uniq.last(1)

      @now += CiStatus::TOKEN_REFRESH_AGE_S
      s.expire("minted-1")
      body, ok = CiStatus.gh_read_status("api", PATH)

      assert ok, "the read past the hour must succeed on a fresh token: #{body}"
      assert_equal "minted-2", s.tokens_seen.last
      assert_equal 2, s.mints
      assert_equal 1, CiStatus.gh_auth_summary[:refreshes]
    end
  end

  # [unit] Before that age, the held token is reused: one mint per lifetime, not per read.
  def test_a_young_token_is_reused
    with_stubs do |s|
      CiStatus.gh_read_status("api", PATH)
      @now += CiStatus::TOKEN_REFRESH_AGE_S - 1
      CiStatus.gh_read_status("api", PATH)

      assert_equal 1, s.mints
      assert_equal %w[minted-1 minted-1], s.tokens_seen.compact
    end
  end

  # [unit] A 401 on a HELD token re-mints and retries, once the token is older than the
  # retry floor. This is the path a token revoked or expired early takes.
  def test_a_401_on_a_held_token_remints_and_retries
    with_stubs do |s|
      CiStatus.gh_read_status("api", PATH)
      @now += CiStatus::MINT_RETRY_FLOOR_S
      s.expire("minted-1")
      _, ok = CiStatus.gh_read_status("api", PATH)

      assert ok
      assert_equal 2, s.mints
      assert_equal "minted-2", s.tokens_seen.last
    end
  end

  # [unit] THE BOUND: a token refused inside the retry floor is NOT re-minted, so a
  # token GitHub refuses outright costs one mint a minute, not one per 15 s poll.
  def test_a_401_inside_the_retry_floor_does_not_mint_again
    with_stubs do |s|
      CiStatus.gh_read_status("api", PATH)
      s.expire("minted-1")
      body, ok = CiStatus.gh_read_status("api", PATH)

      refute ok
      assert_includes body, "HTTP 401"
      assert_equal 1, s.mints
    end
  end

  # [unit] A proactive re-mint that FAILS keeps the aging token, which may still have
  # minutes left, and the read goes on with it.
  def test_a_failed_proactive_mint_keeps_the_held_token
    with_stubs do |s|
      CiStatus.gh_read_status("api", PATH)
      @now += CiStatus::TOKEN_REFRESH_AGE_S
      s.break_broker
      _, ok = CiStatus.gh_read_status("api", PATH)

      assert ok
      assert_equal "minted-1", s.tokens_seen.last
      assert_equal 0, CiStatus.gh_auth_summary[:refreshes]
    end
  end

  # [unit] What a caller may print: the token's LENGTH, never the token.
  def test_the_auth_summary_reports_length_and_never_the_token
    with_stubs do |_s|
      CiStatus.gh_read_status("api", PATH)
      summary = CiStatus.gh_auth_summary

      assert_equal "minted-1".length, summary[:token_length]
      assert summary[:held]
      refute_includes summary.inspect, "minted-1"
    end
  end

  private

  Stubs = Struct.new(:dir) do
    def tokens_seen = File.readlines(File.join(dir, "seen")).map(&:strip).map { |t| t.empty? ? nil : t }
    def mints = File.read(File.join(dir, "count")).to_i
    def break_broker = File.write(File.join(dir, "broken"), "")

    def expire(token)
      valid = File.join(dir, "valid")
      File.write(valid, File.readlines(valid).map(&:strip).reject { |t| t == token }.map { |t| "#{t}\n" }.join)
    end
  end

  def with_stubs
    Dir.mktmpdir do |dir|
      %w[seen valid].each { |f| File.write(File.join(dir, f), "") }
      File.write(File.join(dir, "count"), "0")
      gh = script(dir, "gh", <<~SH)
        #!/bin/sh
        echo "$GH_TOKEN" >> "#{dir}/seen"
        if [ -z "$GH_TOKEN" ] || ! grep -qx "$GH_TOKEN" "#{dir}/valid"; then
          echo '{"message":"Bad credentials","status":"401"}'
          echo 'gh: Bad credentials (HTTP 401)' >&2
          exit 1
        fi
        echo '{"total_count":1,"check_runs":[{"name":"CI","status":"in_progress","conclusion":null}]}'
      SH
      broker = script(dir, "broker", <<~SH)
        #!/bin/sh
        [ -e "#{dir}/broken" ] && { echo 'no 1Password session' >&2; exit 1; }
        n=$(( $(cat "#{dir}/count") + 1 ))
        echo "$n" > "#{dir}/count"
        echo "minted-$n" >> "#{dir}/valid"
        printf 'minted-%s' "$n"
      SH
      with_env("CI_STATUS_GH_BIN" => gh, "GH_AUTH_TOKEN_BIN" => broker, "GH_TOKEN" => nil,
               "GH_APP_ITEM" => nil) do
        yield Stubs.new(dir)
      end
    end
  end

  def script(dir, name, body)
    path = File.join(dir, name)
    File.write(path, body)
    File.chmod(0o755, path)
    path
  end

  def with_env(vars)
    previous = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    previous.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
