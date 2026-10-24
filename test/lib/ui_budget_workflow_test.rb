# frozen_string_literal: true

# [unit] Guard test for .github/workflows/ui-budget.yml, the nightly UI budget.
# It pins what makes the nightly an alarm rather than a chart nobody reads: it
# runs every night off the hour, it runs bin/ui-budget's collector over the whole
# config (no --only), a failure opens or comments on one "UI budget over:" issue
# and a green night closes it, the table reaches the job summary and the JSON an
# artifact even when the run fails, and the token can write issues and nothing
# else. Modelled on test/lib/ci_service_images_test.rb and r2_backup_workflow_test.rb.
#
# Run directly:
#   ruby -Itest test/lib/ui_budget_workflow_test.rb
require "minitest/autorun"
require "yaml"

class UiBudgetWorkflowTest < Minitest::Test
  WORKFLOW = File.expand_path("../../.github/workflows/ui-budget.yml", __dir__)
  BIN = File.expand_path("../../bin/ui-budget", __dir__)
  CRON = "23 10 * * *"
  PREFIX = "UI budget over:"

  def doc = @doc ||= YAML.safe_load_file(WORKFLOW)
  def steps = doc.dig("jobs", "budget", "steps")
  def step(name) = steps.find { |s| s["name"] == name } || flunk("no step named #{name.inspect}")

  # Psych reads the bare `on:` key as true.
  def test_it_runs_nightly_off_the_hour_and_by_hand
    on = doc.fetch(true)
    assert_equal [CRON], on["schedule"].map { |e| e["cron"] }
    minute, _hour, *rest = CRON.split
    refute_equal "0", minute, "a top-of-hour schedule starts hours late"
    assert_equal %w[* * *], rest, "nightly means every day"
    assert on.key?("workflow_dispatch")
  end

  def test_one_run_at_a_time_and_none_cancelled
    assert_equal({ "group" => "ui-budget", "cancel-in-progress" => false }, doc["concurrency"])
  end

  def test_the_token_reads_code_and_writes_issues_only
    assert_equal({ "contents" => "read", "issues" => "write" }, doc["permissions"])
  end

  def test_it_runs_the_collector_over_the_whole_config
    run = step("Measure and judge")["run"]
    assert_equal "bin/ui-budget --collect --out ui-budget.json --summary ui-budget-summary.md", run
    refute_match(/--only/, run, "the nightly measures every page, not one")
    assert File.executable?(BIN), "bin/ui-budget is missing or not executable"
  end

  def test_the_browser_and_node_deps_are_installed_from_the_lockfile
    assert_equal "npm ci", step("Install JS dependencies")["run"]
    assert_match(/npx playwright install --with-deps chromium/, step("Install Playwright browser")["run"])
    assert_equal 22, step("Set up Node").dig("with", "node-version")
  end

  def test_summary_and_artifact_survive_a_failing_run
    assert_equal "always()", step("Write the job summary")["if"]
    assert_match(/GITHUB_STEP_SUMMARY/, step("Write the job summary")["run"])
    upload = step("Upload the results")
    assert_equal "always()", upload["if"]
    assert_match(%r{\Aactions/upload-artifact@}, upload["uses"])
    assert_equal "ui-budget.json", upload.dig("with", "path")
  end

  def test_a_failure_opens_or_comments_one_dated_issue
    alert = step("Alert on failure")
    assert_equal "failure()", alert["if"]
    assert_includes alert["run"], %(prefix="#{PREFIX}")
    assert_includes alert["run"], %(gh issue create --title "$prefix $(date -u +%F)")
    assert_includes alert["run"], "gh issue comment"
    assert_match(/startswith\(\\"\$prefix\\"\)/, alert["run"], "the search must match the prefix, not any issue mentioning it")
  end

  def test_the_alert_survives_a_table_with_no_over_rows
    # bash -e: a grep that matches nothing would end the step before the issue.
    alert = step("Alert on failure")["run"]
    greps = alert.lines.grep(/=\$\(grep /)
    assert_equal 2, greps.size
    greps.each { |line| assert_match(/\|\| true\)\z/, line.strip, line) }
  end

  def test_a_green_run_closes_the_open_alert
    close = step("Close a resolved alert")
    assert_equal "success()", close["if"]
    assert_includes close["run"], %(prefix="#{PREFIX}")
    assert_includes close["run"], "gh issue close"
  end
end
