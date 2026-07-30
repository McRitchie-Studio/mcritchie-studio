# frozen_string_literal: true

# Standalone coverage for bin/gh-app-mint-token's ENV contract. The mint itself
# needs GitHub; these tests prove the script REFUSES bad input loudly BEFORE any
# network call — no test here may reach GitHub or 1Password.

require "minitest/autorun"
require "open3"
require "openssl"
require_relative "../support/session_env"

class GhAppMintTokenTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin", "gh-app-mint-token")

  def test_missing_app_id_aborts_naming_the_var
    out, err, status = run_mint("GH_APP_PEM" => throwaway_pem)

    refute status.success?
    assert_empty out
    assert_includes err, "GH_APP_ID"
  end

  def test_non_numeric_app_id_aborts
    out, err, status = run_mint("GH_APP_ID" => "not-a-number", "GH_APP_PEM" => throwaway_pem)

    refute status.success?
    assert_empty out
    assert_includes err, "numeric"
  end

  def test_missing_pem_aborts_naming_the_var
    out, err, status = run_mint("GH_APP_ID" => "424242")

    refute status.success?
    assert_empty out
    assert_includes err, "GH_APP_PEM"
  end

  # The concealed 1Password `private key` FIELD is not the key (the real key is
  # the .pem FILE attachment) — feeding non-PEM garbage must be refused as an
  # invalid key, before any JWT is built or any request leaves the machine.
  def test_garbage_pem_aborts_as_invalid_key
    out, err, status = run_mint("GH_APP_ID" => "424242", "GH_APP_PEM" => "not a private key")

    refute status.success?
    assert_empty out
    assert_includes err, "not a valid RSA private key"
  end

  private

  # Direct invocation (no `ruby` prefix) so the exec bit + shebang are part of
  # the contract under test. GH_APP_ID/GH_APP_PEM are scrubbed from the child
  # unless a test opts them back in — the suite must never inherit real creds.
  def run_mint(env = {})
    base = { "GH_APP_ID" => nil, "GH_APP_PEM" => nil }
    Open3.capture3(SessionEnv.neutralized(base.merge(env)), SCRIPT)
  end

  # A syntactically valid key so ONLY the var under test is at fault. Tiny on
  # purpose (1024-bit): it signs nothing real and keeps the suite fast.
  def throwaway_pem
    @throwaway_pem ||= OpenSSL::PKey::RSA.new(1024).to_pem
  end
end
