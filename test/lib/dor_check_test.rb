# frozen_string_literal: true

# Standalone test for bin/dor-check (no Rails needed — it shells out to the
# script with --file fixtures). Run directly:
#   ruby -Itest test/lib/dor_check_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"

class DorCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  # Runs dor-check against an in-memory devops payload, returns [stdout, exitcode].
  def check(devops, *args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "slug" => "task-test", "title" => "T", "metadata" => { "devops" => devops }
      ))
      out = `#{BIN} --file #{path} #{args.join(" ")} 2>&1`
      [out, $?.exitstatus]
    end
  end

  def test_passes_when_shape_contract_is_satisfied
    out, code = check(
      "shape" => "backend",
      "repositories" => ["mcritchie-studio"],
      "risk_tags" => ["devops"],
      "acceptance" => ["gate works"],
      "test_plan" => ["unit", "integration"],
      "checks_run" => ["[unit] x", "[integration] y"]
    )
    assert_equal 0, code, out
    assert_match(/DoR met/, out)
  end

  def test_fails_and_lists_missing_tiers_and_metadata
    out, code = check(
      "shape" => "ui+db",
      "repositories" => ["turf-monster"],
      "risk_tags" => ["ui"],
      "acceptance" => ["x"],
      "test_plan" => ["unit"],
      "checks_run" => ["[unit] x"] # missing component/integration/e2e + local_url
    )
    assert_equal 1, code, out
    assert_match(/local_url/, out)
    assert_match(/component/, out)
  end

  def test_fails_on_missing_shape
    out, code = check("repositories" => ["m"])
    assert_equal 1, code
    assert_match(/shape is not set/, out)
  end

  def test_fails_on_unknown_shape
    out, code = check("shape" => "bogus")
    assert_equal 1, code
    assert_match(/unknown shape/, out)
  end

  def test_json_verdict_is_machine_readable
    out, code = check(
      { "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["x"],
        "acceptance" => ["a"], "test_plan" => ["unit"],
        "checks_run" => ["[unit] x", "[integration] y"] },
      "--json"
    )
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"]
    assert_equal "backend", verdict["shape"]
    assert_empty verdict["missing_tiers"]
  end

  def test_tier_tag_accepts_colon_and_spacing
    out, code = check(
      "shape" => "backend",
      "repositories" => ["m"], "risk_tags" => ["x"], "acceptance" => ["a"],
      "test_plan" => ["unit"],
      "checks_run" => ["[ unit : ] bin/rails test", "[integration] flow"]
    )
    assert_equal 0, code, out
  end

  def test_chore_kind_is_exempt_without_a_shape
    out, code = check("kind" => "chore")
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
    assert_match(/non-code task \(kind: chore\)/, out)
  end

  def test_cleanup_kind_is_exempt_without_a_shape
    out, code = check("kind" => "cleanup")
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_chore_exemption_in_json_verdict
    out, code = check({ "kind" => "chore" }, "--json")
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"]
    assert verdict["exempt"]
    assert_equal "chore", verdict["kind"]
  end

  def test_missing_shape_still_fails_when_kind_is_not_exempt
    out, code = check("kind" => "feature", "repositories" => ["m"])
    assert_equal 1, code, out
    assert_match(/shape is not set/, out)
  end
end
