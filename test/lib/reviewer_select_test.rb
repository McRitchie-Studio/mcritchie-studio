# frozen_string_literal: true

# Boots bin/reviewer-select end-to-end — it loads the Rails app — against a
# --file task payload, proving the CLI WIRING: it reads the task's devops shape +
# risk tags, calls ReviewerSelector, and emits a machine-readable decision with a
# heavy+light pair that excludes the QA owner. The selection LOGIC itself (domain
# fit, tiebreak, graceful degradation) is unit-tested in
# test/services/reviewer_selector_test.rb; this is the script regression guard.
#
# Run directly:  ruby -Itest test/lib/reviewer_select_test.rb
# Also picked up by the normal `bin/rails test` sweep.
require "minitest/autorun"
require "json"
require "tmpdir"

class ReviewerSelectCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/reviewer-select", __dir__)

  # Runs reviewer-select against an in-memory devops payload, returns [out, code].
  # stderr is discarded: under `bin/rails test` the subprocess inherits bundler's
  # env and emits rubygems warnings that would otherwise corrupt the stdout parse.
  def select(devops, *args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "slug" => "cli-sample", "metadata" => { "devops" => devops }
      ))
      out = IO.popen("RAILS_ENV=test #{BIN} --file #{path} #{args.join(" ")} 2>/dev/null", &:read)
      [out, $?.exitstatus]
    end
  end

  def test_json_decision_is_machine_readable
    out, code = select({ "shape" => "backend", "risk_tags" => ["solana"] }, "--json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    refute_nil line, "expected a JSON object on stdout, got:\n#{out}"
    decision = JSON.parse(line)

    assert_equal %w[heavy light], decision["reviewers"].map { |r| r["weight"] }, "one heavy + one light"
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "two distinct seniors"
    refute_includes decision["candidates"], "steffon", "the QA owner is excluded (no self-gating)"
    assert(decision["ranked"].all? { |c| c["roll"].is_a?(Numeric) }, "the tiebreak rolls are emitted (auditable)")
  end

  def test_human_output_names_the_pair_and_the_excluded_qa_owner
    out, code = select("shape" => "onchain")
    assert_equal 0, code, out
    assert_match(/HEAVY\s+jasper/, out, "an onchain shape puts the Web3 senior in the heavy seat")
    assert_match(/excluded:\s+steffon/, out)
    assert_match(/tiebreak \(auditable/, out)
  end

  def test_builder_recorded_on_the_task_is_excluded
    # devops.built_by is what the board JSON carries (the CLI builds an in-memory
    # task from it) — the builder must drop out of the candidate pool.
    out, code = select({ "shape" => "backend", "built_by" => "carl" }, "--json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    refute_includes decision["candidates"], "carl", "the recorded builder is excluded"
    assert_equal "carl", decision["builder"]
    assert_equal "carl", decision["excluded_builder"]
  end

  def test_human_output_names_the_excluded_builder
    out, code = select("shape" => "backend", "built_by" => "carl")
    assert_equal 0, code, out
    assert_match(/excluded:\s+steffon/, out, "the QA owner still leads the excluded line")
    assert_match(/carl \(builder/, out, "the builder is named on the excluded line")
  end

  def test_builder_flag_overrides_the_recorded_builder
    out, code = select({ "shape" => "backend", "built_by" => "carl" }, "--builder shannon --json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal "shannon", decision["builder"], "--builder wins over devops.built_by"
    refute_includes decision["candidates"], "shannon"
  end

  # --- busy exclusion (--busy): agents mid-build/review on OTHER tasks ----------

  def test_busy_souls_and_the_builder_are_omitted_end_to_end
    # The auto-read builder (built_by=carl) AND the --busy soul both drop out of
    # the pool, and a HEAVY+LIGHT pair still forms — no manual --builder flag.
    out, code = select({ "shape" => "backend", "built_by" => "carl" }, "--busy jasper --json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal "carl", decision["excluded_builder"], "built_by auto-excluded (no --builder)"
    assert_equal ["jasper"], decision["excluded_busy"], "the --busy soul is excluded"
    pair = decision["reviewers"].map { |r| r["slug"] }
    assert_equal 2, pair.uniq.size, "a pair still forms"
    %w[carl jasper steffon].each { |s| refute_includes pair, s, "#{s} is not assigned the review" }
  end

  def test_busy_filter_keeps_a_pair_rather_than_starve_the_pool
    # built_by carl excluded; marking the rest busy can't drop below a formable
    # pair — the least-bad busy souls are KEPT eligible (starve guard).
    out, code = select({ "shape" => "backend", "built_by" => "carl" }, "--busy shannon,jasper,alex --json")
    assert_equal 0, code, out

    line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
    decision = JSON.parse(line)
    assert_equal 2, decision["reviewers"].map { |r| r["slug"] }.uniq.size, "a pair survives over-exclusion"
    assert decision["kept_busy"].any?, "the starve guard kept the least-bad busy souls eligible"
  end

  def test_human_output_names_the_excluded_busy_souls
    out, code = select({ "shape" => "backend" }, "--busy jasper")
    assert_equal 0, code, out
    assert_match(/jasper \(busy/, out, "a busy soul is named on the excluded line")
  end
end
