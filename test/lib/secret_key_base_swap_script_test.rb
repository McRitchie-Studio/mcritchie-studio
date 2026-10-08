# frozen_string_literal: true

# [unit] bin/secret-key-base-swap, run as a process against stubbed `curl`,
# `heroku` and `openssl` on PATH. The script's own `hk` function runs for real
# over the stubbed curl. The curl stub logs each call and, for a PATCH, the first
# 16 hex of the body's SHA-256; it never logs the body.
#
#   ruby -Itest test/lib/secret_key_base_swap_script_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"
require "json"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class SecretKeyBaseSwapScriptTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/secret-key-base-swap")

  # Stand-ins, never real keys.
  LIVE = ("c0ffee" * 21 + "ab").freeze
  MINTED = ("5eed" * 32).freeze
  PREVIOUS = ("0ddba11" * 18 + "cd").freeze

  CURL_STUB = <<~'SH'
    #!/usr/bin/env bash
    set -eu
    method=GET
    for arg in "$@"; do [ "$arg" = PATCH ] && method=PATCH; done
    if [ "$method" = GET ]; then
      echo "curl GET" >> "$STUB_LOG"
      [ -z "${STUB_GET_FAILS:-}" ] || exit 22
      cat "$STUB_STATE"
      exit 0
    fi
    body=$(cat)
    echo "curl PATCH $(printf '%s' "$body" | shasum -a 256 | cut -c1-16)" >> "$STUB_LOG"
    if [ -n "${STUB_PATCH_FAILS:-}" ]; then echo 422; exit 22; fi
    if [ -z "${STUB_PATCH_DROPS:-}" ]; then
      printf '%s' "$body" | jq -s '.[0] * .[1]' "$STUB_STATE" /dev/stdin > "$STUB_STATE.next"
      mv "$STUB_STATE.next" "$STUB_STATE"
    fi
    echo 200
  SH

  HEROKU_STUB = <<~'SH'
    #!/usr/bin/env bash
    echo "heroku $1" >> "$STUB_LOG"
    [ -z "${STUB_HEROKU_FAILS:-}" ] || exit 1
  SH

  OPENSSL_STUB = <<~'SH'
    #!/usr/bin/env bash
    echo "openssl $1" >> "$STUB_LOG"
    printf '%s\n' "$STUB_MINTED"
  SH

  def setup
    @dir = Dir.mktmpdir("secret-key-base-swap")
    FileUtils.mkdir_p(File.join(@dir, "bin"))
    FileUtils.mkdir_p(File.join(@dir, "config"))
    FileUtils.mkdir_p(File.join(@dir, "stubs"))
    FileUtils.cp(SCRIPT, File.join(@dir, "bin/secret-key-base-swap"))
    { "curl" => CURL_STUB, "heroku" => HEROKU_STUB, "openssl" => OPENSSL_STUB }.each do |name, body|
      path = File.join(@dir, "stubs", name)
      File.write(path, body)
      File.chmod(0o755, path)
    end
    @log = File.join(@dir, "calls.log")
    @state = File.join(@dir, "state.json")
    expect_prefix(prefix(LIVE))
    app_config("SECRET_KEY_BASE" => LIVE)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  # --- controls: a valid pair reaches the PATCH once ---------------------------

  def test_a_valid_swap_patches_once_with_both_keys
    out, err, status = run_script("swap")

    assert_equal 0, status.exitstatus, err
    body = JSON.generate("SECRET_KEY_BASE" => MINTED, "OLD_SECRET_KEY_BASE" => LIVE)
    assert_equal ["curl PATCH #{prefix(body)}"], patches
    assert_equal({ "SECRET_KEY_BASE" => MINTED, "OLD_SECRET_KEY_BASE" => LIVE, "OTHER" => "kept" }, stored)
    assert_includes calls, "heroku run"
    assert_includes out, "old=#{prefix(LIVE)} new=#{prefix(MINTED)}"
    assert_includes out, "stored SECRET_KEY_BASE=#{prefix(MINTED)} OLD_SECRET_KEY_BASE=#{prefix(LIVE)}"
    assert_prints_no_key(out + err)
  end

  def test_a_valid_rollback_patches_once_with_the_keys_exchanged
    app_config("SECRET_KEY_BASE" => MINTED, "OLD_SECRET_KEY_BASE" => LIVE)

    out, err, status = run_script("rollback")

    assert_equal 0, status.exitstatus, err
    body = JSON.generate("SECRET_KEY_BASE" => LIVE, "OLD_SECRET_KEY_BASE" => MINTED)
    assert_equal ["curl PATCH #{prefix(body)}"], patches
    assert_equal LIVE, stored.fetch("SECRET_KEY_BASE")
    assert_equal MINTED, stored.fetch("OLD_SECRET_KEY_BASE")
    assert_prints_no_key(out + err)
  end

  # --- refusals: each exits 1 before any PATCH ---------------------------------

  def test_refuses_short_key
    app_config("SECRET_KEY_BASE" => LIVE[0, 64])
    expect_prefix(prefix(LIVE[0, 64]))
    assert_refused("swap", /SECRET_KEY_BASE is not 128 hex characters/)

    app_config("SECRET_KEY_BASE" => LIVE)
    expect_prefix(prefix(LIVE))
    assert_refused("swap", /generated key is not 128 hex characters/, "STUB_MINTED" => MINTED[0, 127])

    app_config("SECRET_KEY_BASE" => MINTED, "OLD_SECRET_KEY_BASE" => LIVE[0, 64])
    assert_refused("rollback", /OLD_SECRET_KEY_BASE is not 128 hex characters/)
  end

  def test_refuses_equal_keys
    assert_refused("swap", /generated key equals the live key/, "STUB_MINTED" => LIVE)

    app_config("SECRET_KEY_BASE" => LIVE, "OLD_SECRET_KEY_BASE" => LIVE)
    assert_refused("rollback", /OLD_SECRET_KEY_BASE equals SECRET_KEY_BASE/)
  end

  def test_refuses_unset_var
    app_config({})
    assert_refused("swap", /SECRET_KEY_BASE is unset/)

    app_config("SECRET_KEY_BASE" => LIVE)
    assert_refused("rollback", /OLD_SECRET_KEY_BASE is unset/)

    _out, err, status = run_script("swap", "HEROKU_API_KEY" => "")
    assert_equal 1, status.exitstatus
    assert_match(/HEROKU_API_KEY is unset/, err)
    assert_empty calls, "an unset HEROKU_API_KEY refuses before any Heroku read"
  end

  def test_refuses_prefix_mismatch
    expect_prefix(prefix(PREVIOUS))
    assert_refused("swap", /live key's prefix is #{prefix(LIVE)} and .* expects #{prefix(PREVIOUS)}/)

    app_config("SECRET_KEY_BASE" => MINTED, "OLD_SECRET_KEY_BASE" => LIVE)
    assert_refused("rollback", /OLD_SECRET_KEY_BASE's prefix is #{prefix(LIVE)} and .* expects #{prefix(PREVIOUS)}/)
  end

  def test_refuses_a_config_prefix_that_is_not_sixteen_hex
    ["", Digest::SHA256.hexdigest(LIVE), "not-a-prefix"].each do |value|
      expect_prefix(value)
      _out, err, status = run_script("swap")

      assert_equal 1, status.exitstatus
      assert_match(/expected_old_prefix .* is not 16 lowercase hex/, err)
      assert_empty calls, "a bad config refuses before any Heroku read"
    end
  end

  def test_refuses_a_swap_while_the_window_is_open
    app_config("SECRET_KEY_BASE" => LIVE, "OLD_SECRET_KEY_BASE" => PREVIOUS)
    assert_refused("swap", /OLD_SECRET_KEY_BASE is already set/)
  end

  def test_refuses_a_swap_when_the_rotation_code_is_not_running
    assert_refused("swap", /rotation code is not running/, "STUB_HEROKU_FAILS" => "1")
  end

  def test_refuses_when_the_config_read_fails_or_is_empty
    assert_refused("swap", /config read failed/, "STUB_GET_FAILS" => "1")

    File.write(@state, "")
    assert_refused("swap", /config read returned no vars/)
  end

  # --- failures after the PATCH ------------------------------------------------

  def test_fails_when_the_patch_is_rejected
    _out, err, status = run_script("swap", "STUB_PATCH_FAILS" => "1")

    assert_equal 1, status.exitstatus
    assert_match(/FAILED: the PATCH answered HTTP 422/, err)
    assert_equal 1, patches.size
  end

  def test_fails_when_the_stored_prefixes_do_not_match
    out, err, status = run_script("swap", "STUB_PATCH_DROPS" => "1")

    assert_equal 1, status.exitstatus
    assert_match(/FAILED: the stored prefixes are not/, err)
    assert_includes out, "stored SECRET_KEY_BASE=#{prefix(LIVE)} OLD_SECRET_KEY_BASE=EMPTY"
  end

  # --- arguments ---------------------------------------------------------------

  def test_help_and_unrecognized_arguments_reach_nothing
    { ["--help"] => 3, ["swap", "--help"] => 3, ["-h"] => 3,
      [] => 2, ["swap", "now"] => 2, ["close"] => 2, ["--yes"] => 2 }.each do |args, code|
      out, err, status = run_script(*args)

      assert_equal code, status.exitstatus, "#{args.inspect}: #{err}"
      assert_includes out + err, "TOUCHES NOTHING"
      assert_empty calls, "#{args.inspect} reached a stub"
    end
  end

  # --- wiring: the script in bin/ reads the config in config/ ------------------

  def test_the_real_script_reads_the_real_config
    configured = File.read(File.join(ROOT, "config/secret_rotation.yml"))[/^expected_old_prefix:\s*(\S+)/, 1]
    assert_match(/\A\h{16}\z/, configured)
    refute_equal prefix(LIVE), configured

    _out, err, status = Open3.capture3(env, SCRIPT, "swap")

    assert_equal 1, status.exitstatus
    assert_match(/live key's prefix is #{prefix(LIVE)} and .* expects #{configured}/, err)
    assert_empty patches
  end

  private

  def env(extra = {})
    OutboundSeams.env({
      "PATH" => [File.join(@dir, "stubs"), OutboundSeams.sealed_path].join(File::PATH_SEPARATOR),
      "HEROKU_API_KEY" => "stub-not-a-credential",
      "STUB_LOG" => @log,
      "STUB_STATE" => @state,
      "STUB_MINTED" => MINTED
    }.merge(extra))
  end

  def run_script(*args, **extra)
    File.delete(@log) if File.exist?(@log)
    Open3.capture3(env(extra.transform_keys(&:to_s)), File.join(@dir, "bin/secret-key-base-swap"), *args)
  end

  # A refusal exits 1 with its reason, after reading the config and before any PATCH.
  def assert_refused(command, reason, extra = {})
    out, err, status = run_script(command, **extra.transform_keys(&:to_sym))

    assert_equal 1, status.exitstatus, "#{command} should refuse: #{err}"
    assert_match reason, err
    assert_includes err, "Nothing was changed"
    assert_includes calls, "curl GET", "the refusal should follow a read through the stubbed curl"
    assert_empty patches, "a refusal must not PATCH"
    assert_prints_no_key(out + err)
  end

  def assert_prints_no_key(text)
    refute_match(/\h{17,}/, text, "output holds a hex run longer than 16 characters")
  end

  def expect_prefix(value)
    File.write(File.join(@dir, "config/secret_rotation.yml"), "# comment\nexpected_old_prefix: #{value}\n")
  end

  def app_config(vars)
    File.write(@state, JSON.generate(vars.empty? ? { "OTHER" => "kept" } : vars.merge("OTHER" => "kept")))
  end

  def stored
    JSON.parse(File.read(@state))
  end

  def calls
    File.exist?(@log) ? File.readlines(@log, chomp: true) : []
  end

  def patches
    calls.grep(/\Acurl PATCH/)
  end

  def prefix(value)
    Digest::SHA256.hexdigest(value)[0, 16]
  end
end
