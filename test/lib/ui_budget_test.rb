# frozen_string_literal: true

# [unit] The UI budget evaluator (bin/lib/ui_budget.rb): it reads the collector's JSON and
# config/ui_budget.yml and decides, row by row, whether a page is over. Fixtures live under
# test/fixtures/files/ui_budget/. An unmeasured page must fail the run, or a dead host reads
# clean.
# History: task ui-budget-nightly-pass.
require "minitest/autorun"
require "json"
require "open3"
require "tempfile"
require "tmpdir"
require_relative "../../bin/lib/ui_budget"

class UiBudgetTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  FIXTURES = File.join(ROOT, "test/fixtures/files/ui_budget")
  BIN = File.join(ROOT, "bin/ui-budget")

  def config = UiBudget.load_config(File.join(FIXTURES, "config.yml"))
  def results(name) = JSON.parse(File.read(File.join(FIXTURES, "results_#{name}.json")))
  def rows(name, **opts) = UiBudget.evaluate(config, results(name), **opts)
  def verdicts(rows) = rows.map(&:verdict).tally

  def find(rows, page, width, metric)
    rows.find { |r| r.page == page && r.width == width && r.metric == metric }
  end

  # ---- under ----

  def test_all_under_passes_and_judges_every_applicable_ceiling
    under = rows("under")
    refute UiBudget.over?(under)
    assert_equal({ "ok" => 25, "n/a" => 2 }, verdicts(under))
  end

  def test_third_party_js_is_not_judged_on_a_sign_in_page
    under = rows("under")
    assert_nil find(under, "https://example.test/login", 390, "third_party_js_bytes")
    assert_equal "ok", find(under, "https://example.test/", 390, "third_party_js_bytes").verdict
  end

  def test_total_weight_is_judged_only_on_a_landing_page_at_phone_width
    under = rows("under")
    assert_equal "ok", find(under, "https://example.test/", 390, "total_bytes").verdict
    assert_nil find(under, "https://example.test/", 1280, "total_bytes"), "the 2 MB desktop landing is not judged"
    assert_nil find(under, "https://example.test/login", 390, "total_bytes")
  end

  def test_no_images_or_no_assets_is_not_applicable_not_missing
    under = rows("under")
    assert_equal "n/a", find(under, "https://example.test/login", 1280, "largest_image_ratio").verdict
    assert_equal "n/a", find(under, "https://example.test/login", 1280, "assets_cached_one_year_pct").verdict
  end

  # ---- over ----

  def test_every_metric_over_on_one_page_is_flagged
    over = rows("over")
    assert UiBudget.over?(over)
    refute UiBudget.missing?(over)
    assert_equal 0, UiBudget.exit_code(over), "OVER reports; it does not fail the run"
    flagged = over.select { |r| r.verdict == "OVER" }
    assert_equal UiBudget::METRICS.sort, flagged.map(&:metric).sort
    assert(flagged.all? { |r| r.page == "https://example.test/" && r.width == 390 })
  end

  def test_a_min_ceiling_is_over_when_below
    row = find(rows("over"), "https://example.test/", 390, "assets_cached_one_year_pct")
    assert_equal "OVER", row.verdict
    assert_equal "0.0%", row.value
    assert_equal ">= 100%", row.ceiling
  end

  def test_values_print_in_readable_units
    over = rows("over")
    assert_equal "324 KB", find(over, "https://example.test/", 390, "js_bytes").value
    assert_equal "<= 250 KB", find(over, "https://example.test/", 390, "js_bytes").ceiling
    assert_equal "3.67x", find(over, "https://example.test/", 390, "largest_image_ratio").value
    assert_equal "2352 KB", find(over, "https://example.test/", 390, "total_bytes").value
    assert_equal "3", find(over, "https://example.test/", 390, "axe_serious_critical").value
  end

  def test_at_the_ceiling_is_not_over
    doc = results("under")
    doc["results"][0]["metrics"]["js_bytes"] = 256_000
    row = find(UiBudget.evaluate(config, doc), "https://example.test/", 390, "js_bytes")
    assert_equal "ok", row.verdict
  end

  # ---- missing ----

  def test_a_page_never_measured_is_missing_and_fails
    missing = rows("missing")
    assert UiBudget.missing?(missing)
    refute UiBudget.over?(missing), "an unmeasured page is MISSING, not OVER"
    assert_equal 1, UiBudget.exit_code(missing)
    row = find(missing, "https://example.test/login", 1280, "page")
    assert_equal "MISSING", row.verdict
    assert_equal "no result", row.value
  end

  def test_a_page_that_errored_is_missing_with_its_error
    row = find(rows("missing"), "https://example.test/login", 390, "page")
    assert_equal "MISSING", row.verdict
    assert_match(/ERR_NAME_NOT_RESOLVED/, row.value)
  end

  def test_a_null_axe_count_or_an_absent_metric_is_missing_not_a_pass
    missing = rows("missing")
    assert_equal "MISSING", find(missing, "https://example.test/", 390, "axe_serious_critical").verdict
    assert_equal "MISSING", find(missing, "https://example.test/", 1280, "css_bytes").verdict
  end

  def test_an_empty_results_file_fails_every_page
    empty = UiBudget.evaluate(config, { "results" => [] })
    assert_equal 4, empty.size
    assert(empty.all? { |r| r.verdict == "MISSING" })
  end

  # ---- --only ----

  def test_only_narrows_the_pages_judged
    one = rows("missing", only: "https://example.test/")
    assert_equal ["https://example.test/"], one.map(&:page).uniq
    refute(one.any? { |r| r.metric == "page" })
  end

  def test_only_refuses_a_url_the_config_does_not_name
    error = assert_raises(UiBudget::Error) { rows("under", only: "https://elsewhere.test/") }
    assert_match(/not in the config/, error.message)
  end

  # ---- table ----

  def test_table_has_the_six_columns_and_a_verdict_line
    text = UiBudget.table(rows("over"))
    header = text.lines.first.split
    assert_equal %w[page width metric value ceiling verdict], header
    assert_match(/^ui-budget: 8 over, 0 missing/, text.lines.last)
  end

  def test_markdown_is_a_pipe_table
    md = UiBudget.markdown(rows("under"))
    assert_match(/^\| page \| width \| metric \| value \| ceiling \| verdict \|$/, md)
    assert_match(/^\|---/, md)
  end

  # ---- the real config ----

  def test_the_real_config_names_three_apps_and_the_eight_ceilings
    real = UiBudget.load_config(UiBudget::CONFIG)
    assert_equal UiBudget::METRICS.sort, real.ceilings.keys.sort
    assert_equal [390, 1280], real.widths
    hosts = real.pages.map { |p| URI(p.url).host }.uniq
    assert_equal %w[mcritchie.studio turfmonster.media cyvasse.xyz], hosts
    assert_equal 3, real.pages.count(&:landing)
    assert_equal 2, real.pages.count(&:sign_in)
    assert_equal 0, real.ceilings.dig("axe_serious_critical", "max")
    assert_equal 256_000, real.ceilings.dig("js_bytes", "max")
    assert_equal 1_048_576, real.ceilings.dig("total_bytes", "max")
  end

  def test_a_ceiling_with_an_unknown_scope_is_refused
    bad = File.read(File.join(FIXTURES, "config.yml")).sub("applies_to: not_sign_in", "applies_to: nowhere")
    Tempfile.create(%w[ui_budget .yml]) do |f|
      f.write(bad)
      f.flush
      assert_raises(UiBudget::Error) { UiBudget.load_config(f.path) }
    end
  end

  # ---- the CLI ----

  def run_bin(*args) = Open3.capture3("ruby", BIN, *args)

  def test_cli_evaluate_exits_zero_when_under
    out, _err, status = run_bin("--evaluate", File.join(FIXTURES, "results_under.json"), "--config", File.join(FIXTURES, "config.yml"))
    assert_equal 0, status.exitstatus, out
    assert_match(/ui-budget: 0 over, 0 missing/, out)
  end

  # REPORT-ONLY (task ui-budget-report-never-gates): the ceilings are not ratified,
  # so a page over budget is printed, not failed. The nightly's red run on main's
  # head blocked a cleared production ship; this pins that it cannot recur.
  def test_cli_evaluate_exits_zero_when_over_and_still_prints_the_over_rows
    out, _err, status = run_bin("--evaluate", File.join(FIXTURES, "results_over.json"), "--config", File.join(FIXTURES, "config.yml"))
    assert_equal 0, status.exitstatus, out
    assert_match(/ui-budget: 8 over, 0 missing/, out)
    assert_match(/\bOVER\z/, out.lines.grep(/OVER/).first.to_s.strip, "the OVER rows stay in the log")
  end

  def test_cli_evaluate_exits_one_when_a_page_went_unmeasured
    out, _err, status = run_bin("--evaluate", File.join(FIXTURES, "results_missing.json"), "--config", File.join(FIXTURES, "config.yml"))
    assert_equal 1, status.exitstatus, out
    assert_match(/ui-budget: 0 over, 4 missing/, out)
  end

  def test_cli_evaluate_exits_one_when_over_and_missing_together
    over = JSON.parse(File.read(File.join(FIXTURES, "results_over.json")))
    Dir.mktmpdir do |dir|
      path = File.join(dir, "both.json")
      # Keep only the over page at 390: it stays OVER, every other page goes MISSING.
      File.write(path, JSON.generate(over.merge("results" => over["results"].first(1))))
      out, _err, status = run_bin("--evaluate", path, "--config", File.join(FIXTURES, "config.yml"))
      assert_match(/ui-budget: 8 over, [1-9]\d* missing/, out)
      assert_equal 1, status.exitstatus, out
    end
  end

  def test_cli_exits_two_when_the_results_file_is_unreadable
    _out, _err, status = run_bin("--evaluate", "/nonexistent/results.json", "--config", File.join(FIXTURES, "config.yml"))
    assert_equal 2, status.exitstatus
  end

  def test_cli_writes_the_markdown_summary
    Dir.mktmpdir do |dir|
      summary = File.join(dir, "summary.md")
      run_bin("--evaluate", File.join(FIXTURES, "results_over.json"), "--config", File.join(FIXTURES, "config.yml"), "--summary", summary)
      assert_match(/\| OVER \|/, File.read(summary))
    end
  end

  def test_cli_refuses_both_modes_or_neither
    [[], ["--collect", "--evaluate", "x.json"]].each do |args|
      _out, _err, status = run_bin(*args)
      assert_equal 2, status.exitstatus, args.inspect
    end
  end

  def test_cli_help_runs_nothing
    out, _err, status = run_bin("--collect", "--help")
    assert_equal 0, status.exitstatus
    assert_match(/usage: bin\/ui-budget/, out)
  end
end
