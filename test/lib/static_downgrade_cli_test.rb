# frozen_string_literal: true

# [unit] bin/static-downgrade's argument guard: a probe answers usage, and an
# unknown flag or app refuses before any credential is read or call is made.
#
#   ruby -Itest test/lib/static_downgrade_cli_test.rb

require "minitest/autorun"
require "open3"

class StaticDowngradeCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/static-downgrade", __dir__)

  # PATH holds no `op`, so a read that slipped past the guard would fail loudly.
  def run_bin(*args)
    Open3.capture3({ "PATH" => "/usr/bin:/bin", "OP_SERVICE_ACCOUNT_TOKEN" => nil,
                     "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => nil }, RbConfig.ruby, BIN, *args)
  end

  def test_help_prints_usage_and_exits_zero
    out, _err, status = run_bin("--help")
    assert status.success?
    assert_includes out, "Usage: bin/static-downgrade <repo>"
  end

  def test_an_unknown_flag_refuses_and_reads_nothing
    _out, err, status = run_bin("rantly", "--force")
    assert_equal 2, status.exitstatus
    assert_includes err, "nothing was read or written"
  end

  def test_an_unregistered_app_refuses
    _out, err, status = run_bin("not-an-app")
    refute status.success?
    assert_includes err, "not-an-app is not an app in config/release_repos.yml"
  end
end
