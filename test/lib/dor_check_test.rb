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

  # Runs dor-check against an in-memory devops payload, returns [output, exitcode].
  def check(devops, *args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "slug" => "task-test", "title" => "T", "metadata" => { "devops" => devops }
      ))
      # Capture STDOUT only. dor-check prints its verdict (text and --json) to
      # stdout via puts; when this test runs inside `bin/rails test`, the
      # subprocess inherits bundler's env and emits rubygems "already
      # initialized constant" warnings to STDERR — merging them (2>&1) would
      # corrupt the JSON parse. Discarding stderr keeps the verdict clean.
      out = IO.popen("#{BIN} --file #{path} #{args.join(' ')} 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
  end

  # Inject a deterministic branch diff for the duration of a check. The subprocess
  # inherits this process's ENV, so setting DOR_CHECK_CHANGED_FILES here drives the
  # script's code-diff detection without shelling out to git. `files` is newline/
  # comma separated; "" means "no diff". Any chore/cleanup/docs case must wrap its
  # check, since the exemption now depends on whether the branch ships code.
  def with_changed_files(files)
    had = ENV.key?("DOR_CHECK_CHANGED_FILES")
    prev = ENV["DOR_CHECK_CHANGED_FILES"]
    ENV["DOR_CHECK_CHANGED_FILES"] = files
    yield
  ensure
    had ? (ENV["DOR_CHECK_CHANGED_FILES"] = prev) : ENV.delete("DOR_CHECK_CHANGED_FILES")
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
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/submitted → reviewed/, out)
  end

  def test_build_gate_passes_on_spec_without_test_tiers
    # DoR-to-Build only needs a complete spec — no test tiers yet (no code).
    out, code = check(
      { "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["x"],
        "acceptance" => ["a"], "test_plan" => ["unit"], "checks_run" => [] },
      "--gate", "build"
    )
    assert_equal 0, code, out
    assert_match(/DoR-to-Build met/, out)
    assert_match(/designed → building/, out)
  end

  def test_build_gate_still_requires_the_spec
    out, code = check({ "shape" => "backend" }, "--gate", "build")
    assert_equal 1, code, out
    assert_match(/acceptance/, out)
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
    out, code = with_changed_files("") { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
    assert_match(/non-code task \(kind: chore\)/, out)
  end

  def test_cleanup_kind_is_exempt_without_a_shape
    out, code = with_changed_files("") { check("kind" => "cleanup") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_chore_exemption_in_json_verdict
    out, code = with_changed_files("") { check({ "kind" => "chore" }, "--json") }
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"]
    assert verdict["exempt"]
    assert_equal "chore", verdict["kind"]
  end

  # --- no size exemption: a chore that ships code gets gated like a feature ---

  def test_doc_only_chore_stays_exempt
    out, code = with_changed_files("docs/agents/foo.md\nREADME.md") { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_chore_with_a_code_diff_and_no_shape_is_refused
    out, code = with_changed_files("bin/dor-check\napp/models/task.rb") { check("kind" => "chore") }
    assert_equal 1, code, out
    assert_match(/ships a code diff/, out)
    assert_match(/bin\/dor-check/, out)
    assert_match(/set devops\.shape/, out)
  end

  def test_chore_with_a_code_diff_passes_when_the_shape_contract_is_met
    out, code = with_changed_files("bin/dor-check") do
      check(
        "kind" => "chore", "shape" => "backend", "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["tooling"], "acceptance" => ["gate fires on code chores"],
        "test_plan" => ["unit", "integration"],
        "checks_run" => ["[unit] x", "[integration] y"]
      )
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  def test_chore_with_a_code_diff_still_needs_the_test_tiers
    out, code = with_changed_files("lib/foo.rb") do
      check(
        "kind" => "chore", "shape" => "backend", "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["tooling"], "acceptance" => ["gate fires"],
        "test_plan" => ["unit", "integration"], "checks_run" => ["[unit] x"]
      )
    end
    assert_equal 1, code, out
    assert_match(/integration/, out)
  end

  def test_code_diff_chore_refusal_in_json_verdict
    out, code = with_changed_files("config/routes.rb") { check({ "kind" => "chore" }, "--json") }
    assert_equal 1, code, out
    verdict = JSON.parse(out)
    refute verdict["ready"]
    assert(verdict["errors"].any? { |e| e =~ /ships a code diff/ })
  end

  def test_missing_shape_still_fails_when_kind_is_not_exempt
    out, code = check("kind" => "feature", "repositories" => ["m"])
    assert_equal 1, code, out
    assert_match(/shape is not set/, out)
  end
end
