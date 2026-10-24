# frozen_string_literal: true

# [unit] bin/heroku-secret-set, run as a process against a local stand-in for the
# Heroku Platform API (HEROKU_API_BASE). It proves the value travels in the
# request BODY (never argv), that an empty read is refused before any request,
# that --json lands every name in one PATCH, and that a non-200 fails loudly.
#
# Run directly:  ruby -Itest test/lib/heroku_secret_set_test.rb
require "minitest/autorun"
require "json"
require "open3"
require "socket"
require_relative "../support/session_env"

class HerokuSecretSetTest < Minitest::Test
  BIN = File.expand_path("../../bin/heroku-secret-set", __dir__)

  # A one-thread HTTP stand-in: records each request and answers `status`.
  def with_api(status: "200")
    server = TCPServer.new("127.0.0.1", 0)
    seen = []
    thread = Thread.new do
      loop do
        client = server.accept
        head = +""
        while (line = client.gets) && line != "\r\n"
          head << line
        end
        length = head[/^content-length:\s*(\d+)/i, 1].to_i
        seen << { head: head, body: client.read(length) }
        client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        client.close
      end
    rescue IOError
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}", seen
  ensure
    server&.close
    thread&.kill
  end

  def run_bin(*args, stdin:, base:)
    env = SessionEnv.neutralized("HEROKU_API_KEY" => "fake-heroku-token", "HEROKU_API_BASE" => base)
    Open3.capture3(env, "ruby", BIN, *args, stdin_data: stdin)
  end

  def test_the_value_rides_in_the_body_and_never_on_argv
    with_api do |base, seen|
      out, err, status = run_bin("fixture-app", "FIXTURE_SECRET", stdin: "s3cret-value\n", base: base)

      assert status.success?, err
      assert_equal 1, seen.length
      assert_match %r{\APATCH /apps/fixture-app/config-vars }, seen[0][:head]
      assert_match(/^authorization: Bearer fake-heroku-token\r$/i, seen[0][:head])
      assert_equal({ "FIXTURE_SECRET" => "s3cret-value" }, JSON.parse(seen[0][:body]), "one trailing newline is stripped")
      refute_includes out + err, "s3cret-value", "the value must never be printed"
    end
  end

  def test_an_empty_read_is_refused_before_any_request
    with_api do |base, seen|
      _out, err, status = run_bin("fixture-app", "FIXTURE_SECRET", stdin: "", base: base)

      assert_equal 1, status.exitstatus
      assert_includes err, "NOTHING WAS SET"
      assert_empty seen, "an empty value reached the API, which would blank the var"

      _out, _err, status = run_bin("fixture-app", "--json", stdin: '{"A_KEY":"x","B_KEY":null}', base: base)

      assert_equal 1, status.exitstatus
      assert_empty seen, "a JSON null reached the API, which unsets the var"
    end
  end

  def test_json_writes_every_name_in_one_patch
    with_api do |base, seen|
      payload = { "MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS" => "old-v", "MANAGED_WALLET_ENCRYPTION_KEY" => "new-v" }
      _out, err, status = run_bin("fixture-app", "--json", stdin: JSON.generate(payload), base: base)

      assert status.success?, err
      assert_equal 1, seen.length, "two names must land in ONE release"
      assert_equal payload, JSON.parse(seen[0][:body])
    end
  end

  def test_a_non_200_fails_and_withholds_the_body
    with_api(status: "403") do |base, _seen|
      out, err, status = run_bin("fixture-app", "FIXTURE_SECRET", stdin: "v", base: base)

      assert_equal 1, status.exitstatus
      assert_includes err, "HTTP 403"
      assert_empty out
    end
  end

  def test_help_and_bad_usage_set_nothing
    with_api do |base, seen|
      out, _err, status = run_bin("--help", stdin: "v", base: base)

      assert status.success?
      assert_includes out, "SETS NOTHING"
      _out, _err, status = run_bin("fixture-app", stdin: "v", base: base)

      assert_equal 2, status.exitstatus
      _out, _err, status = run_bin("fixture-app", "lower_case", stdin: "v", base: base)

      assert_equal 1, status.exitstatus
      assert_empty seen
    end
  end

  # N6 (secrets-scrub-follow-ups): HEROKU_API_BASE may point only at the real API
  # or a loopback stand-in, so a planted base cannot collect the bearer token.
  def test_a_non_heroku_api_base_is_refused_before_the_token_is_used
    [
      "https://evil.example",
      "https://api.heroku.com.evil.example",
      "https://api.heroku.com@evil.example",
      "http://api.heroku.com",
      "https://api.heroku.com:8443",
      "http://10.0.0.5:9000",
      "https://api.heroku.com/elsewhere",
      "not a url"
    ].each do |base|
      out, err, status = run_bin("fixture-app", "FIXTURE_SECRET", stdin: "v\n", base: base)

      assert_equal 1, status.exitstatus, "#{base} was accepted"
      assert_match(/HEROKU_API_BASE (may name only|is not a URL)/, err, base)
      assert_includes err, "NOTHING WAS SET", base
      refute_includes out + err, "fake-heroku-token", "the token was printed for #{base}"
    end
  end

  # The control: the guard is not simply refusing everything. A loopback base is
  # the one every test above uses, and it still reaches the stand-in.
  def test_control_a_loopback_base_still_reaches_the_stand_in
    with_api do |base, seen|
      _out, err, status = run_bin("fixture-app", "FIXTURE_SECRET", stdin: "v\n", base: base.sub("127.0.0.1", "localhost"))

      assert status.success?, err
      assert_equal 1, seen.length
    end
  end
end
