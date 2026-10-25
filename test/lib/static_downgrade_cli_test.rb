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
    assert_includes err, "not-an-app is not an app in"
  end
  # A paid app is refused before any credential read or Cloudflare call: the
  # PATH holds no `op`, so a read past the guard would fail with a different error.
  def test_a_paid_app_refuses_before_anything_is_read
    %w[turf-monster cyvasse moms-app mcritchie-industries commercial-welding].each do |repo|
      _out, err, status = run_bin(repo)
      refute status.success?, "#{repo} must refuse"
      assert_includes err, "#{repo} is not an unpaid showcase app", repo
      assert_includes err, "Nothing was read or written", repo
    end
  end
end
